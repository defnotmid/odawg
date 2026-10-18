package odawg_song

import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import base "../base"
import device "../device"
import spec "../spec"
import tempo "../tempo"
import theory "../theory"

// The arrangement: every part any style or the spec names, each playing the
// spec's own entries over their ranges and its style's entries (by energy)
// in the sections the spec leaves to the style; notes land on a track per
// style; then the transitions between sections, then the note table.

// What a part sounds like when nothing says, by its name.
Role_Row :: struct {
	name:    string,
	device:  device.Device_Kind,
	octave:  int, // where its chords and degrees sit
	gain_db: f64, // its level in the mix (the presets play at synth.lua's raw levels)
	room:    f64, // dB it dips by under a voice
}

ROLE_TABLE := []Role_Row {
	{"drums", .Drum_Kit, 3, 0, 0},
	{"bass", .Bass, 2, -4, 0},
	{"sub", .Sub_Bass, 1, -4, 0},
	{"pad", .Pad, 3, -8, -2},
	{"strings", .Pad, 3, -8, -2},
	{"keys", .Stab, 4, -8, -3},
	{"chords", .Stab, 4, -8, -3},
	{"lead", .Lead, 5, -12, -6},
	{"melody", .Lead, 5, -12, -6},
	{"arp", .Pluck, 4, -10, -6},
	{"pluck", .Pluck, 4, -10, -6},
	{"bells", .Bell, 5, -10, -6},
	{"fx", .Riser, 4, -4, 0},
}

ROLE_DEFAULT :: Role_Row{"", .Synth, 4, -6, -3}

role_from_name :: proc(name: string) -> Role_Row {
	for r in ROLE_TABLE {
		if r.name == name {
			return r
		}
	}
	return ROLE_DEFAULT
}

// The styles odawg ships: partial specs (their parts, returns and swing).
STYLE_TABLE := [?]struct {
	name, text: string,
} {
	{"acid_house", #load("../styles/acid_house.json", string)},
	{"ambient", #load("../styles/ambient.json", string)},
	{"booty_house", #load("../styles/booty_house.json", string)},
	{"chicago_house", #load("../styles/chicago_house.json", string)},
	{"house", #load("../styles/house.json", string)},
	{"lofi", #load("../styles/lofi.json", string)},
	{"synthwave", #load("../styles/synthwave.json", string)},
}

style_source :: proc(name: string) -> (string, bool) {
	for s in STYLE_TABLE {
		if s.name == name {
			return s.text, true
		}
	}
	return "", false
}

// The specs a song reads parts from: its own, then each style it uses.
@(private = "file")
Sources :: struct {
	own:    ^spec.Spec,
	styles: [dynamic]^spec.Spec, // parallel to names
	names:  [dynamic]string,
}

@(private = "file")
style_spec :: proc(src: ^Sources, name: string, findings: ^base.Findings) -> ^spec.Spec {
	for n, i in src.names {
		if n == name {
			return src.styles[i]
		}
	}
	append(&src.names, name)
	// the song's own styles first: a name of its own wins over a shipped one
	for own in src.own.styles {
		if own.name == name {
			st := new(spec.Spec)
			spec.spec_from_value(own.value, st, findings)
			append(&src.styles, st)
			return st
		}
	}
	text, known := style_source(name)
	if !known {
		names := make([dynamic]string, context.temp_allocator)
		for st in STYLE_TABLE {
			append(&names, st.name)
		}
		for own in src.own.styles {
			append(&names, own.name)
		}
		base.report(findings, "unknown_style", .Error, "", "style %q is not one of %s (or the song's own `styles`)", name, strings.join(names[:], ", ", context.temp_allocator))
		append(&src.styles, nil)
		return nil
	}
	st := new(spec.Spec)
	spec.spec_from_json(text, st, findings)
	append(&src.styles, st)
	return st
}

@(private = "file")
part_in :: proc(s: ^spec.Spec, name: string) -> ^spec.Part_Spec {
	if s == nil {
		return nil
	}
	for &p in s.parts {
		if p.name == name {
			return &p
		}
	}
	return nil
}

arrange :: proc(s: ^spec.Spec, song: ^Song, work: ^Work) {
	src := Sources{own = s}
	for sec in song.sections {
		if sec.style != "" {
			style_spec(&src, sec.style, &song.findings)
		}
	}
	for p in s.parts {
		append(&song.parts, p.name)
	}
	for st in src.styles {
		if st == nil {
			continue
		}
		for p in st.parts {
			if !slice.contains(song.parts[:], p.name) {
				append(&song.parts, p.name)
			}
		}
	}
	slice.sort(song.parts[:])
	// the returns: the styles', then the spec's (the spec's win by name)
	for st in src.styles {
		if st != nil {
			for ret in st.returns {
				add_return(song, st, ret)
			}
		}
	}
	for ret in s.returns {
		add_return(song, s, ret)
	}
	// the spec's buses and where they go, its parts' routes
	for b in s.buses {
		append(&song.buses, Bus{b.name, chain_into_song(song, s, b.chain, 60 / song.sections[0].bpm0)})
		if b.to != "" {
			append(&song.routes, Route{from = b.name, to = b.to, gain = 1, moves = true})
		}
	}
	for p in s.parts {
		if p.to != "" {
			append(&song.routes, Route{from = p.name, to = p.to, gain = 1, moves = true})
		}
		if p.key != "" {
			append(&song.routes, Route{from = p.key, to = p.name, kind = .Key, gain = 1})
		}
	}

	covered := make([]bool, len(song.sections), context.temp_allocator)
	pending := make([dynamic]Note_Row, context.temp_allocator)
	// each entry over each range it was expanded in (beats), what made it
	Trigger :: struct {
		from, to: f64,
		source:   string,
	}
	triggers := make([dynamic]Trigger, context.temp_allocator)
	for name, pi in song.parts {
		own := part_in(s, name)
		clear(&pending)
		clear(&triggers)
		slice.zero(covered)
		// the spec's own entries over their ranges
		if own != nil {
			for &pl in s.plays[own.plays.first:base.span_end(own.plays)] {
				if pl.ranges.count == 0 {
					base.report(&song.findings, "bad_range", .Error, pl.path, "%s: play needs a range (\"drop\", \"drop@4m..\")", pl.path)
				}
				for rng in s.ranges[pl.ranges.first:base.span_end(pl.ranges)] {
					b0, b1, ok := beats_from_range(song, rng)
					if !ok {
						base.report(&song.findings, "bad_range", .Error, pl.path, "%s: %q is not a range of the song", pl.path, rng)
						continue
					}
					for sec, i in song.sections {
						if b0 < sec.beat + sec.beats - 1e-9 && b1 > sec.beat + 1e-9 {
							covered[i] = true
						}
					}
					expand(song, s, name, own, nil, &pl, b0, b1, &pending)
					append(&triggers, Trigger{b0, b1, strings.trim_prefix(pl.path, "song/")})
				}
			}
		}
		// the styles' entries where the spec leaves the part to them
		for sec, i in song.sections {
			if covered[i] || sec.style == "" {
				continue
			}
			st := style_spec(&src, sec.style, &song.findings)
			sp := part_in(st, name)
			if sp == nil {
				continue
			}
			for &pl in st.plays[sp.plays.first:base.span_end(sp.plays)] {
				if in_band(sec.energy, pl.energy) {
					expand(song, st, name, own, st, &pl, sec.beat, sec.beat + sec.beats, &pending)
					append(&triggers, Trigger{sec.beat, sec.beat + sec.beats, strings.concatenate({"style/", sec.style, "/", strings.trim_prefix(pl.path, "song/")})})
				}
			}
		}
		if own != nil {
			for m in s.ranges[own.mute.first:base.span_end(own.mute)] {
				b0, b1, ok := beats_from_range(song, m)
				if !ok {
					base.report(&song.findings, "bad_range", .Error, base.path_join(base.path_join("parts", name), "mute"), "parts/%s/mute: %q is not a range of the song", name, m)
					continue
				}
				#reverse for p, k in pending {
					if p.beat >= b0 - 1e-9 && p.beat < b1 - 1e-9 {
						ordered_remove(&pending, k)
					}
				}
			}
		}
		// its regions: the triggers that still play a note (mutes take some),
		// one where an entry carries on into the next range
		for tr in triggers {
			plays := false
			for p in pending {
				plays ||= p.beat >= tr.from - 1e-9 && p.beat < tr.to - 1e-9
			}
			if !plays {
				continue
			}
			start, stop := tempo.seconds_from_beat(&song.tempo, tr.from), tempo.seconds_from_beat(&song.tempo, tr.to)
			if n := len(song.regions); n > 0 {
				last := &song.regions[n - 1]
				if last.part == i32(pi) && last.source == tr.source && abs(last.stop - start) < 1e-9 {
					last.stop = stop
					continue
				}
			}
			append(&song.regions, Region{i32(pi), start, stop, tr.source})
		}
		// a track per style the notes fall in
		for p in pending {
			style := song.sections[section_from_beat(song, p.beat)].style
			ti := track_for(song, &src, work, i32(pi), name, style)
			row := p
			row.track = u16(ti)
			append(&work.notes[ti], row)
		}
		if len(pending) == 0 && own != nil {
			track_for(song, &src, work, i32(pi), name, len(song.sections) > 0 ? song.sections[0].style : "")
		}
	}
}

// An energy band is [lo, hi), the top one closed at 1: a section on the line
// between two bands plays the upper one, once.
@(private = "file")
in_band :: proc(energy: f64, band: [2]f64) -> bool {
	return energy >= band[0] - 1e-9 && (energy < band[1] - 1e-9 || band[1] >= 1)
}

@(private = "file")
add_return :: proc(song: ^Song, from: ^spec.Spec, ret: spec.Return_Spec) {
	r := Return{name = ret.name, chain = chain_into_song(song, from, ret.chain, 60 / song.sections[0].bpm0)}
	for &x in song.returns {
		if x.name == ret.name {
			x = r
			return
		}
	}
	append(&song.returns, r)
}

// Copies a spec's device into the song with its values resolved (lengths in
// beats at `beat_seconds`).
@(private = "file")
device_into_song :: proc(song: ^Song, from: ^spec.Spec, d: i32, beat_seconds: f64) -> i32 {
	p, ok := spec.params_from_device(from, d, beat_seconds, song.bank)
	if !ok {
		base.report(&song.findings, "asset_unavailable", .Error, from.devices[d].path, "%s: a sample set it plays is not loaded (offline, or not in the register)", from.devices[d].path)
	}
	append(&song.devices, from.devices[d].kind)
	append(&song.params, p)
	return i32(len(song.devices) - 1)
}

@(private = "file")
chain_into_song :: proc(song: ^Song, from: ^spec.Spec, c: Span, beat_seconds: f64) -> Span {
	devices := make([dynamic]i32, context.temp_allocator)
	for d in from.chain[c.first:base.span_end(c)] {
		append(&devices, device_into_song(song, from, d, beat_seconds))
	}
	sp := Span{i32(len(song.chain)), i32(len(devices))}
	append(&song.chain, ..devices[:])
	return sp
}

// The track part `pi` plays style `variant` on, made the first time: the
// spec's settings over the style's over the role's.
@(private = "file")
track_for :: proc(song: ^Song, src: ^Sources, work: ^Work, pi: i32, name, variant: string) -> int {
	for t, i in song.tracks {
		if t.part == pi && t.variant == variant {
			return i
		}
	}
	role := role_from_name(name)
	beat_seconds := 60 / song.sections[0].bpm0
	for sec in song.sections {
		if sec.style == variant {
			beat_seconds = 60 / sec.bpm0
			break
		}
	}
	t := Track{part = pi, variant = variant, gain_db = role.gain_db + src.own.gain_db, room = role.room, instrument = -1}
	style := variant != "" ? style_spec(src, variant, &song.findings) : nil
	layers := [2]^spec.Spec{style, src.own}
	for from in layers {
		p := part_in(from, name)
		if p == nil {
			continue
		}
		if p.instrument >= 0 {
			t.instrument = device_into_song(song, from, p.instrument, beat_seconds)
		}
		if !math.is_nan(p.gain_db) {
			t.gain_db = p.gain_db + src.own.gain_db
		}
		if !math.is_nan(p.pan) {
			t.pan = p.pan
		}
		if p.effects.count >= 0 {
			t.chain = chain_into_song(song, from, p.effects, beat_seconds)
		}
		if p.sends.count > 0 {
			t.sends = sends_into_song(song, from, p.sends, t.sends, base.path_join("parts", name))
		}
		if p.sidechain.source != "" {
			sc := sidechain_from_spec(song, p.sidechain, base.path_join("parts", name))
			if sc.mode != .None {
				t.sidechains = {i32(len(song.sidechains)), 1}
				append(&song.sidechains, sc)
			}
		}
	}
	if t.instrument < 0 {
		append(&song.devices, role.device)
		append(&song.params, device.params_from_kind(role.device))
		t.instrument = i32(len(song.devices) - 1)
	}
	append(&song.tracks, t)
	append(&work.notes, make([dynamic]Note_Row, context.temp_allocator))
	return len(song.tracks) - 1
}

// A track's sends: earlier ones (the style's) replaced by name.
@(private = "file")
sends_into_song :: proc(song: ^Song, from: ^spec.Spec, sends: Span, before: Span, path: string) -> Span {
	rows := make([dynamic]Send, context.temp_allocator)
	append(&rows, ..song.sends[before.first:base.span_end(before)])
	for s in from.sends[sends.first:base.span_end(sends)] {
		ri := -1
		for ret, i in song.returns {
			if ret.name == s.to {
				ri = i
			}
		}
		if ri < 0 {
			// a send to a bus: a route from the part (its tracks summed)
			for b in song.buses {
				if b.name == s.to {
					ri = -2
				}
			}
			if ri == -2 {
				append(&song.routes, Route{from = strings.trim_prefix(path, "parts/"), to = s.to, gain = f32(base.db_to_gain(s.gain_db))})
				continue
			}
			base.report(&song.findings, "bad_value", .Error, base.path_join(path, "sends"), "%s/sends: there is no return or bus %q", path, s.to)
			continue
		}
		g := f32(base.db_to_gain(s.gain_db))
		replaced := false
		for &x in rows {
			if x.ret == i32(ri) {
				x.gain, replaced = g, true
			}
		}
		if !replaced {
			append(&rows, Send{i32(ri), g})
		}
	}
	sp := Span{i32(len(song.sends)), i32(len(rows))}
	append(&song.sends, ..rows[:])
	return sp
}

// "drums/kick": the part and the pad or note.
@(private = "file")
sidechain_from_spec :: proc(song: ^Song, sc: spec.Sidechain_Spec, path: string) -> Sidechain {
	out := Sidechain{mode = .Hits, part = -1, pitch = -1, depth = sc.depth, release = sc.release}
	part, note := sc.source, ""
	if slash := strings.index_byte(sc.source, '/'); slash >= 0 {
		part, note = sc.source[:slash], sc.source[slash + 1:]
	}
	for n, i in song.parts {
		if n == part {
			out.part = i32(i)
		}
	}
	if out.part < 0 {
		base.report(&song.findings, "bad_value", .Error, base.path_join(path, "sidechain"), "%s/sidechain: there is no part %q", path, part)
		return {}
	}
	if note != "" {
		if pad, is_pad := device.pad_from_name(note); is_pad {
			out.pad = pad
		} else if p, is_note := theory.pitch_from_string(note); is_note {
			out.pitch = p
		} else {
			base.report(&song.findings, "bad_value", .Error, base.path_join(path, "sidechain"), "%s/sidechain: %q is not a pad or note", path, note)
		}
	}
	return out
}

// ---- patterns into notes -------------------------------------------------------------

// One play entry being expanded over beats [from, to): the spec whose
// tables it reads, the part's octave, the swing.
@(private = "file")
Expand :: struct {
	song:     ^Song,
	from_spec: ^spec.Spec,
	play:     ^spec.Play_Spec,
	from, to: f64,
	octave:   int,
	swing:    f64,
	swing_at: f64, // beats of the swung subdivision
	seed:     u64,
	out:      ^[dynamic]Note_Row,
}

Expand_Proc :: #type proc(x: ^Expand)

@(private = "file")
EXPANDERS := [spec.Play_Kind]Expand_Proc {
	.None     = proc(x: ^Expand) {},
	.Steps    = expand_steps,
	.Notes    = expand_sequence,
	.Degrees  = expand_sequence,
	.Events   = expand_events,
	.Arpeggio = expand_arpeggio,
	.Chords   = expand_chords,
}

@(private = "file")
expand :: proc(song: ^Song, from_spec: ^spec.Spec, name: string, own: ^spec.Part_Spec, style: ^spec.Spec, pl: ^spec.Play_Spec, from, to: f64, out: ^[dynamic]Note_Row) {
	octave := role_from_name(name).octave
	if sp := part_in(style, name); sp != nil && !math.is_nan(sp.octave) {
		octave = int(sp.octave)
	}
	if own != nil && !math.is_nan(own.octave) {
		octave = int(own.octave)
	}
	if !math.is_nan(pl.octave) {
		octave = int(pl.octave)
	}
	x := Expand{song = song, from_spec = from_spec, play = pl, from = from, to = to, octave = octave, out = out}
	swing, sub := from_spec.swing, from_spec.swing_subdivision
	if style != nil && from_spec != style && swing == 0 {
		swing, sub = style.swing, style.swing_subdivision
	}
	x.swing = swing
	if l, ok := tempo.length_from_string(sub, 4); ok && !l.in_seconds {
		x.swing_at = l.value
	}
	x.seed = base.hash_combine(song.seed, base.hash_combine(base.hash_string(name), base.hash_string(pl.path)))
	EXPANDERS[pl.kind](&x)
}

@(private = "file")
bpb_at :: proc(song: ^Song, beat: f64) -> int {
	return song.sections[section_from_beat(song, beat)].beats_per_bar
}

// Adds a note at `beat` lasting `beats`, swung and humanized.
@(private = "file")
emit :: proc(x: ^Expand, beat, beats: f64, pitch: f32, velocity: f64, pad: device.Pad) {
	if beat < x.from - 1e-9 || beat >= x.to - 1e-9 {
		return
	}
	b := beat
	if x.swing > 0 && x.swing_at > 0 {
		q := (b - x.from) / x.swing_at
		if n := math.round(q); math.abs(q - n) < 1e-6 && int(n) % 2 == 1 {
			b += x.swing * x.swing_at / 3
		}
	}
	t0 := tempo.seconds_from_beat(&x.song.tempo, b)
	t1 := tempo.seconds_from_beat(&x.song.tempo, min(b + beats, x.to + 4))
	vel := velocity
	if h := x.play.humanize; h > 0 {
		k := base.hash_combine(x.seed, u64(beat * 9600 + 0.5))
		t0 += (base.hash_unit(k) - 0.5) * 2 * h
		jittered := vel * (0.92 + 0.16 * base.hash_unit(base.hash_combine(k, 7)))
		// a note at or under an accent's line (0.8) stays under it
		vel = vel <= 0.8 ? min(jittered, 0.8) : jittered
	}
	append(x.out, Note_Row{time = max(t0, 0), duration = max(t1 - t0, 0.001), beat = beat, pitch = pitch, velocity = f32(clamp(vel, 0, 1)), pad = pad})
}

// A note token ("A2") or a chord degree ("5") at a beat.
@(private = "file")
token_pitch :: proc(x: ^Expand, token: string, beat: f64, degrees: bool) -> (f32, bool) {
	if degrees {
		d, ok := strconv.parse_int(token)
		if !ok || d == 0 {
			return 0, false
		}
		return theory.pitch_from_degree(x.song.key, chord_from_beat(x.song, beat), d, x.octave), true
	}
	return theory.pitch_from_string(token)
}

// A step's length, or the play's `duration`.
@(private = "file")
hit_length :: proc(x: ^Expand, step: f64, beat: f64) -> f64 {
	if x.play.duration == "" {
		return step
	}
	l, ok := tempo.length_from_string(x.play.duration, bpb_at(x.song, beat))
	if !ok {
		return step
	}
	return l.in_seconds ? l.value * tempo.bpm_from_beat(&x.song.tempo, beat) / 60 : l.value
}

@(private = "file")
bad_play :: proc(x: ^Expand, format: string, args: ..any) {
	base.report(&x.song.findings, "bad_value", .Error, x.play.path, format, ..args)
}

// "-" holds the note before for another slot.
@(private = "file")
extend_last :: proc(x: ^Expand, beats: f64) {
	if len(x.out) == 0 {
		return
	}
	p := &x.out[len(x.out) - 1]
	end := tempo.beat_from_seconds(&x.song.tempo, p.time + p.duration) + beats
	p.duration = tempo.seconds_from_beat(&x.song.tempo, end) - p.time
}

@(private = "file")
expand_steps :: proc(x: ^Expand) {
	s := x.from_spec
	for lane in s.lanes[x.play.rows.first:base.span_end(x.play.rows)] {
		pad := device.Pad.None
		if lane.pad != "" {
			p, ok := device.pad_from_name(lane.pad)
			if !ok {
				bad_play(x, "%s/steps: %q is not a pad (kick, snare, clap, rim, hat, open_hat, crash, ride, tom_low, tom_mid, tom_high, shaker)", x.play.path, lane.pad)
				continue
			}
			pad = p
		}
		bars := s.bars[lane.bars.first:base.span_end(lane.bars)]
		if len(bars) == 0 {
			continue
		}
		bar := 0
		for start := x.from; start < x.to - 1e-9; bar += 1 {
			bpb := bpb_at(x.song, start)
			cells := make([dynamic]u8, context.temp_allocator)
			for c in transmute([]u8)bars[bar % len(bars)] {
				if c != ' ' && c != '|' {
					append(&cells, c)
				}
			}
			step := f64(bpb) / f64(max(len(cells), 1))
			held := false
			for c, i in cells {
				b := start + f64(i) * step
				vel: f64
				switch c {
				case 'x':
					vel = x.play.velocity
				case 'X':
					vel = min(1, x.play.velocity * 1.25)
				case 'o':
					vel = x.play.velocity * 0.45
				case '-':
					if held {
						extend_last(x, step)
					}
					continue
				case '.':
					held = false
					continue
				case:
					bad_play(x, "%s/steps: %q: x hit, X accent, o ghost, - hold, . rest", x.play.path, bars[bar % len(bars)])
					return
				}
				pitch: f32
				if pad == .None {
					tok := x.play.note == "" ? "1" : x.play.note
					p, ok := token_pitch(x, tok, b, !strings.contains_any(tok, "ABCDEFGabcdefg"))
					if !ok {
						bad_play(x, "%s/note: %q is not a note or degree", x.play.path, tok)
						return
					}
					pitch = p
				}
				before := len(x.out)
				emit(x, b, hit_length(x, step, b), pitch, vel, pad)
				held = len(x.out) > before
			}
			start += f64(bpb)
		}
	}
}

// Beats a sliding note's gate stays open past the next note's start.
SLIDE_OVERLAP :: 1.0 / 32

@(private = "file")
expand_sequence :: proc(x: ^Expand) {
	degrees := x.play.kind == .Degrees
	sub := x.play.subdivision != "" ? x.play.subdivision : "8n"
	l, ok := tempo.length_from_string(sub, bpb_at(x.song, x.from))
	if !ok || l.in_seconds || l.value <= 0 {
		bad_play(x, "%s/subdivision: %q is not a Tone length (\"8n\", \"16n\")", x.play.path, sub)
		return
	}
	tokens := x.from_spec.tokens[x.play.rows.first:base.span_end(x.play.rows)]
	if len(tokens) == 0 || x.play.slots <= 0 {
		return
	}
	cycle := x.play.slots * l.value
	slides := make([dynamic]int, context.temp_allocator) // notes whose gate runs into the next
	for c := x.from; c < x.to - 1e-9; c += cycle {
		held := false
		for t in tokens {
			b := c + t.at * l.value
			if b >= x.to - 1e-9 {
				break
			}
			switch t.text {
			case ".", "~", "r":
				held = false
			case "-", "_":
				if held {
					extend_last(x, t.length * l.value)
				}
			case:
				// "E5!" an accent, "E5~" its gate held into the next note (a mono
				// voice slides), "E5!~" both
				text, vel, beats := t.text, x.play.velocity, hit_length(x, t.length * l.value, b)
				slide := false
				for len(text) > 1 && (text[len(text) - 1] == '!' || text[len(text) - 1] == '~') {
					if text[len(text) - 1] == '!' {
						vel = 1
					} else {
						slide = true
					}
					text = text[:len(text) - 1]
				}
				p, is_pitch := token_pitch(x, text, b, degrees)
				if !is_pitch {
					bad_play(x, "%s: %q is not a %s", x.play.path, t.text, degrees ? "degree (1, 5, 8; ! accent, ~ slide)" : "note (\"E5\", \"E5!\" accented, \"E5~\" sliding) or rest (\".\")")
					return
				}
				before := len(x.out)
				emit(x, b, beats, p, vel, .None)
				held = len(x.out) > before
				if held && slide {
					append(&slides, len(x.out) - 1)
				}
			}
		}
	}
	// a sliding note's gate runs to where the next note really starts
	// (swung, humanized), and a little past
	for i in slides {
		if i + 1 < len(x.out) {
			n, next := &x.out[i], x.out[i + 1]
			overlap := tempo.seconds_from_beat(&x.song.tempo, next.beat + SLIDE_OVERLAP) - tempo.seconds_from_beat(&x.song.tempo, next.beat)
			n.duration = max(n.duration, next.time - n.time + overlap)
		}
	}
}

@(private = "file")
expand_events :: proc(x: ^Expand) {
	loop := 0.0
	if x.play.loop != "" {
		if l, ok := tempo.length_from_string(x.play.loop, bpb_at(x.song, x.from)); ok && !l.in_seconds && l.value > 0 {
			loop = l.value
		}
	}
	events := x.from_spec.events[x.play.rows.first:base.span_end(x.play.rows)]
	for c := x.from; c < x.to - 1e-9; c += loop {
		for e in events {
			bpb := bpb_at(x.song, c)
			at := beats_from_time(x, e.time, c, bpb) or_else math.INF_F64
			dur := beats_from_time(x, e.duration, c, bpb) or_else -1
			if math.is_inf(at) || dur < 0 {
				bad_play(x, "%s/events: time and duration are Tone lengths or seconds", x.play.path)
				return
			}
			vel := math.is_nan(e.velocity) ? x.play.velocity : e.velocity
			if e.note == "" {
				emit(x, c + at, dur, 0, vel, .None) // the instrument's own pitch
			} else if pad, is_pad := device.pad_from_name(e.note); is_pad {
				emit(x, c + at, dur, 0, vel, pad)
			} else if p, is_note := theory.pitch_from_string(e.note); is_note {
				emit(x, c + at, dur, p, vel, .None)
			} else {
				bad_play(x, "%s/events: %q is not a note or pad", x.play.path, e.note)
				return
			}
		}
		if loop == 0 {
			break
		}
	}
}

// A time in an event as beats from `origin`.
@(private = "file")
beats_from_time :: proc(x: ^Expand, t: spec.Time_Spec, origin: f64, bpb: int) -> (beats: f64, ok: bool) {
	seconds := t.seconds
	if math.is_nan(seconds) {
		l := tempo.length_from_string(t.text, bpb) or_return
		if !l.in_seconds {
			return l.value, true
		}
		seconds = l.value
	}
	m := &x.song.tempo
	return tempo.beat_from_seconds(m, tempo.seconds_from_beat(m, origin) + seconds) - origin, true
}

@(private = "file")
expand_arpeggio :: proc(x: ^Expand) {
	a := x.play.arpeggio
	l, ok := tempo.length_from_string(a.interval, bpb_at(x.song, x.from))
	if !ok || l.in_seconds || l.value <= 0 {
		bad_play(x, "%s/arpeggio/interval: %q is not a Tone length", x.play.path, a.interval)
		return
	}
	tones := make([dynamic]f32, context.temp_allocator)
	chord := make([dynamic]f32, context.temp_allocator)
	i := 0
	for b := x.from; b < x.to - 1e-9; b += l.value {
		clear(&tones)
		clear(&chord)
		c := chord_from_beat(x.song, b)
		c.bass = -1
		theory.pitches_from_chord(c, x.octave, &chord)
		for o in 0 ..< max(1, int(a.octaves)) {
			for n in chord {
				append(&tones, n + f32(12 * o))
			}
		}
		n := len(tones)
		k: int
		switch a.pattern {
		case "up":
			k = i % n
		case "down":
			k = n - 1 - i % n
		case "upDown", "up_down":
			p := max(1, 2 * n - 2)
			k = i % p
			if k >= n {
				k = p - k
			}
		case "downUp", "down_up":
			p := max(1, 2 * n - 2)
			k = i % p
			k = k >= n ? k - n + 1 : n - 1 - k
		case "random":
			k = int(base.hash_unit(base.hash_combine(x.seed, u64(i))) * f64(n)) % n
		case:
			bad_play(x, "%s/arpeggio/pattern: %q is not up, down, upDown, downUp or random", x.play.path, a.pattern)
			return
		}
		emit(x, b, hit_length(x, l.value, b), tones[k], x.play.velocity, .None)
		i += 1
	}
}

@(private = "file")
expand_chords :: proc(x: ^Expand) {
	previous := make([dynamic]f32, context.temp_allocator)
	notes := make([dynamic]f32, context.temp_allocator)
	voiced :: proc(x: ^Expand, b: f64, previous, notes: ^[dynamic]f32) {
		clear(notes)
		theory.pitches_from_chord(chord_from_beat(x.song, b), x.octave, notes)
		theory.voice_lead(notes[:], previous[:])
		switch x.play.chords.voicing {
		case "open":
			if len(notes) >= 3 {
				notes[1] += 12
			}
		case "spread":
			if len(notes) >= 3 {
				notes[0] -= 12
				notes[len(notes) - 1] += 12
			}
		}
		clear(previous)
		append(previous, ..notes[:])
	}
	if x.play.chords.rhythm == "" {
		// a chord per change, held until the next
		for b := x.from; b < x.to - 1e-9; {
			c := chord_from_beat(x.song, b)
			end := b
			for end < x.to - 1e-9 && chord_from_beat(x.song, end) == c {
				end += f64(bpb_at(x.song, end))
			}
			end = min(end, x.to)
			voiced(x, b, &previous, &notes)
			for n in notes {
				emit(x, b, end - b, n, x.play.velocity, .None)
			}
			b = end
		}
		return
	}
	cells := make([dynamic]u8, context.temp_allocator)
	for c in transmute([]u8)x.play.chords.rhythm {
		if c != ' ' && c != '|' {
			append(&cells, c)
		}
	}
	if len(cells) == 0 {
		return
	}
	for start := x.from; start < x.to - 1e-9; start += f64(bpb_at(x.song, start)) {
		step := f64(bpb_at(x.song, start)) / f64(len(cells))
		for c, i in cells {
			if c != 'x' && c != 'X' {
				continue
			}
			b := start + f64(i) * step
			voiced(x, b, &previous, &notes)
			vel := c == 'X' ? min(1, x.play.velocity * 1.25) : x.play.velocity
			for n in notes {
				emit(x, b, hit_length(x, step, b), n, vel, .None)
			}
		}
	}
}

// ---- transitions ---------------------------------------------------------------------

// The instruments a fill plays on: those with a snare pad. (An 808 playing
// a sub line is one too, so the fill takes the track that plays pads.)
FILL_INSTRUMENTS :: bit_set[device.Device_Kind]{.Drum_Kit, .Drum_Machine}

@(private = "file")
plays_pads :: proc(notes: []Note_Row) -> bool {
	for n in notes {
		if n.pad != .None {
			return true
		}
	}
	return false
}

// Between sections: a riser into a rise in energy (and an impact with a
// crash when it lands high), a fill when the groove carries on, a beat of
// silence for "pause". Risers and impacts go on the "fx" part: the song's
// own when it has one (each sound on a track of its own with that part's
// level, effects and sends), else one added last at its role's level.
add_transitions :: proc(song: ^Song, work: ^Work) {
	fx_track :: proc(song: ^Song, work: ^Work, kind: device.Device_Kind) -> int {
		fx := -1
		for n, i in song.parts {
			if n == "fx" {
				fx = i
			}
		}
		if fx < 0 {
			append(&song.parts, "fx")
			fx = len(song.parts) - 1
		}
		role := role_from_name("fx")
		t := Track{part = i32(fx), gain_db = role.gain_db + song.gain_db, room = role.room}
		name := device.DEVICE_TABLE[kind].name
		#reverse for x, i in song.tracks {
			if x.part != i32(fx) {
				continue
			}
			if x.variant == name {
				return i
			}
			t = x // the part's mix, from its first track
		}
		append(&song.devices, kind)
		append(&song.params, device.params_from_kind(kind))
		t.variant, t.instrument, t.notes = name, i32(len(song.devices) - 1), {}
		append(&song.tracks, t)
		append(&work.notes, make([dynamic]Note_Row, context.temp_allocator))
		return len(song.tracks) - 1
	}
	note :: proc(song: ^Song, t0, duration: f64, pitch, velocity: f32, pad: device.Pad = .None) -> Note_Row {
		return {time = t0, duration = duration, beat = tempo.beat_from_seconds(&song.tempo, t0), pitch = pitch, velocity = velocity, pad = pad}
	}
	for i in 1 ..< len(song.sections) {
		prev, next := song.sections[i - 1], song.sections[i]
		kind := next.transition
		if kind == .Auto {
			rise := next.energy - prev.energy
			switch {
			case rise >= 0.3:
				kind = next.energy >= 0.8 ? .Impact : .Riser
			case math.abs(rise) < 0.3 && prev.energy >= 0.5 && next.energy >= 0.5 && next.style == prev.style:
				kind = .Fill
			case:
				kind = .None
			}
		}
		at := next.start
		switch kind {
		case .Riser, .Impact:
			from_beat := max(prev.beat, next.beat - 2 * f64(prev.beats_per_bar))
			t0 := tempo.seconds_from_beat(&song.tempo, from_beat)
			ti := fx_track(song, work, .Riser)
			append(&work.notes[ti], note(song, t0, at - t0, 60, 0.35))
			source := strings.concatenate({"sections/", next.name, "/transition"})
			append(&song.regions, Region{song.tracks[ti].part, t0, at, source})
			if kind == .Impact {
				ti = fx_track(song, work, .Impact)
				append(&work.notes[ti], note(song, at, 2.5, 36, 0.8))
				ti = fx_track(song, work, .Crash)
				append(&work.notes[ti], note(song, at, 1.6, 60, 0.7))
				append(&song.regions, Region{song.tracks[ti].part, at, at + 2.5, source})
			}
		case .Fill:
			// a snare roll over the last beat, on the outgoing groove's kit: its
			// first track of a fill instrument that plays pads there
			for t, ti in song.tracks {
				if song.devices[t.instrument] not_in FILL_INSTRUMENTS || t.variant != prev.style || !plays_pads(work.notes[ti][:]) {
					continue
				}
				last := next.beat - 1
				notes := &work.notes[ti]
				#reverse for n, k in notes {
					if n.beat >= last - 1e-9 && n.beat < next.beat - 1e-9 && (n.pad == .Hat || n.pad == .Snare || n.pad == .Clap) {
						ordered_remove(notes, k)
					}
				}
				for s in 0 ..< 4 {
					b := last + f64(s) * 0.25
					t0 := tempo.seconds_from_beat(&song.tempo, b)
					append(notes, note(song, t0, tempo.seconds_from_beat(&song.tempo, b + 0.25) - t0, 0, f32(0.35 + 0.15 * f64(s)), .Snare))
				}
				break
			}
		case .Pause:
			last := tempo.seconds_from_beat(&song.tempo, next.beat - 1)
			for &notes in work.notes {
				#reverse for n, k in notes {
					if n.time >= last - 1e-9 && n.time < at - 1e-9 {
						ordered_remove(&notes, k)
					}
				}
			}
		case .Filter:
			base.report(&song.findings, "not_supported", .Info, base.path_join("sections", next.name), "section %s: the filter transition is not built yet; it plays as none", next.name)
		case .None, .Cut, .Auto:
		}
	}
}

// The note table: each track's notes in time order, the tracks one after
// another, and the index of every note in time order.
index_notes :: proc(song: ^Song, work: ^Work) {
	for &notes, ti in work.notes {
		slice.sort_by(notes[:], proc(a, b: Note_Row) -> bool {
			if a.time != b.time {
				return a.time < b.time
			}
			return a.pitch < b.pitch
		})
		song.tracks[ti].notes = {i32(len(song.notes)), i32(len(notes))}
		for n in notes {
			row := n
			row.track = u16(ti)
			append_soa(&song.notes, row)
		}
	}
	for i in 0 ..< len(song.notes) {
		append(&song.by_time, i32(i))
	}
	context.user_ptr = song
	slice.stable_sort_by(song.by_time[:], proc(a, b: i32) -> bool {
		s := (^Song)(context.user_ptr)
		ta, tb := s.notes.time[a], s.notes.time[b]
		if ta != tb {
			return ta < tb
		}
		return s.tracks[s.notes.track[a]].part < s.tracks[s.notes.track[b]].part
	})
}

// The regions by part, then start (the transitions' were added after the
// parts' own).
sort_regions :: proc(song: ^Song) {
	slice.stable_sort_by(song.regions[:], proc(a, b: Region) -> bool {
		return a.part < b.part || (a.part == b.part && a.start < b.start)
	})
}
