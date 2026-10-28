package odawg_song

import "core:encoding/json"
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

// What a part is when nothing says: the same for every part, whatever its
// name. A part with no instrument doesn't play (a finding says so).
PART_OCTAVE :: 4 // where its chords and degrees sit
PART_GAIN :: base.Gain(1) // its level in the mix
PART_ROOM :: base.Gain(1) // what it dips to where the song makes room

// The spec each style the song's sections name reads parts from (Work.styles,
// by style): the song's own of that name, or a style file the host read;
// nil, a finding: none. What reading one found is the song's now, once.
@(private = "file")
styles_from_spec :: proc(s: ^spec.Spec, song: ^Song, work: ^Work) {
	work.styles = make([dynamic]^spec.Spec, len(song.styles), context.temp_allocator)
	for name, i in song.styles {
		for &own in s.styles {
			if own.name == name {
				append(&song.findings, ..own.findings[:])
				work.styles[i] = own.spec
				break
			}
		}
		if work.styles[i] != nil {
			continue
		}
		names := make([dynamic]string, context.temp_allocator)
		for own in s.styles {
			append(&names, own.name)
		}
		known := len(names) > 0 ? strings.concatenate({" (it has ", strings.join(names[:], ", ", context.temp_allocator), ")"}, context.temp_allocator) : ""
		base.report(&song.findings, "unknown_style", .Error, "", "style %q is not one of the song's `styles`%s, or a style file (\"styles/house.json\")", name, known)
	}
}

// The spec style `style` reads parts from (nil: none).
@(private = "file")
style_spec :: proc(work: ^Work, style: i32) -> ^spec.Spec {
	return style >= 0 ? work.styles[style] : nil
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
	styles_from_spec(s, song, work)
	for p in s.parts {
		append(&song.parts, p.name)
	}
	for st in work.styles {
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
	// each part's role: the spec's part's, else a style's
	resize(&song.roles, len(song.parts))
	for name, i in song.parts {
		written, path := "", ""
		for st in work.styles {
			if st != nil {
				for p in st.parts {
					if p.name == name && p.role != "" {
						written, path = p.role, base.path_join(base.path_join("parts", name), "role")
					}
				}
			}
		}
		for p in s.parts {
			if p.name == name && p.role != "" {
				written, path = p.role, base.path_join(base.path_join("parts", name), "role")
			}
		}
		if written == "" {
			continue
		}
		found := false
		for r in Part_Role {
			if r != .None && PART_ROLE_NAMES[r] == written {
				song.roles[i], found = r, true
			}
		}
		if !found {
			base.report(&song.findings, "bad_value", .Error, path, "%s: %q is not a role (melody, counter, bass, drums, comp, pad, fx, texture)", path, written)
		}
	}
	// the returns: the styles', then the spec's (the spec's win by name)
	for st in work.styles {
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
	}
	for b in s.buses {
		if b.to != "" {
			route_add(song, b.name, b.to, .Audio, 1, true)
		}
		if b.key != "" {
			route_add(song, b.key, b.name, .Key, 1, false)
		}
	}
	for p in s.parts {
		if p.to != "" {
			route_add(song, p.name, p.to, .Audio, 1, true)
		}
		if p.key != "" {
			route_add(song, p.key, p.name, .Key, 1, false)
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
					// over the style of the section it starts in (what it inherits)
					under: ^spec.Spec
					if len(song.sections) > 0 {
						if st := song.sections[section_from_beat(song, b0)].style; st >= 0 {
							under = style_spec(work, st)
						}
					}
					expand(song, s, name, own, nil, under, &pl, b0, b1, &pending)
					append(&triggers, Trigger{b0, b1, strings.trim_prefix(pl.path, "song/")})
				}
			}
		}
		// the styles' entries where the spec leaves the part to them
		for sec, i in song.sections {
			if covered[i] || sec.style < 0 {
				continue
			}
			st := style_spec(work, sec.style)
			sp := part_in(st, name)
			if sp == nil {
				continue
			}
			for &pl in st.plays[sp.plays.first:base.span_end(sp.plays)] {
				if in_band(sec.energy, pl.energy) {
					expand(song, st, name, own, st, st, &pl, sec.beat, sec.beat + sec.beats, &pending)
					append(&triggers, Trigger{sec.beat, sec.beat + sec.beats, strings.concatenate({"style/", style_name(song, sec.style), "/", strings.trim_prefix(pl.path, "song/")})})
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
		// a track per style the notes fall in (none: no instrument, no notes)
		styles := make([dynamic]i32, context.temp_allocator)
		tracks := make([dynamic]int, context.temp_allocator)
		for p in pending {
			style := song.sections[section_from_beat(song, p.beat)].style
			k, found := slice.linear_search(styles[:], style)
			if !found {
				// its first note in that style: where its Tone lengths are read
				first := p.beat
				for q in pending {
					if q.beat < first && song.sections[section_from_beat(song, q.beat)].style == style {
						first = q.beat
					}
				}
				append(&styles, style)
				append(&tracks, track_for(song, s, work, i32(pi), name, style, first))
				k = len(tracks) - 1
			}
			if tracks[k] < 0 {
				continue
			}
			row := p
			row.track = u16(tracks[k])
			append(&work.notes[tracks[k]], row)
		}
		if len(pending) == 0 && own != nil {
			track_for(song, s, work, i32(pi), name, len(song.sections) > 0 ? song.sections[0].style : -1)
		}
		for ti in tracks {
			if ti >= 0 {
				check_pads(song, s, ti, work)
			}
		}
	}
}

// A track's notes on pads its instrument has: one it hasn't is a finding
// at the entry naming it (with the pads it has), and doesn't play.
@(private = "file")
check_pads :: proc(song: ^Song, s: ^spec.Spec, ti: int, work: ^Work) {
	t := &song.tracks[ti]
	program := i32(song.params[t.instrument][.Program])
	has := make([dynamic]u32, context.temp_allocator)
	spec.program_pads(&song.programs, program, &has)
	reported := make([dynamic]u32, context.temp_allocator)
	notes := &work.notes[ti]
	#reverse for n, k in notes {
		if n.pad == 0 || slice.contains(has[:], n.pad) {
			continue
		}
		ordered_remove(notes, k)
		if slice.contains(reported[:], n.pad) {
			continue
		}
		append(&reported, n.pad)
		name := pad_name(song, n.pad)
		names := make([dynamic]string, context.temp_allocator)
		for id in has {
			append(&names, pad_name_or_id(song, id))
		}
		slice.sort(names[:])
		path := pad_play_path(s, style_spec(work, t.style), song.parts[t.part], style_name(song, t.style), name)
		what := len(names) > 0 ? strings.concatenate({"it has ", strings.join(names[:], ", ", context.temp_allocator)}, context.temp_allocator) : "it plays pitches, not pads"
		base.report(&song.findings, "unknown_pad", .Error, path, "%s: %q is not a pad of the part's instrument (%s)", path, name, what)
	}
}

// A pad's name, or the id when no note or question named it.
@(private = "file")
pad_name_or_id :: proc(song: ^Song, id: u32) -> string {
	if n := pad_name(song, id); n != "?" {
		return n
	}
	for g in device.GM_PADS {
		if base.name_id(g.name) == id {
			return g.name
		}
	}
	buf := make([]u8, 9, context.temp_allocator)
	buf[0] = '#'
	for k in 0 ..< 8 {
		digits := "0123456789abcdef"
		buf[1 + k] = digits[(id >> (28 - 4 * u32(k))) & 15]
	}
	return string(buf)
}

// The play entry whose steps name a pad: the spec's, else the style's.
@(private = "file")
pad_play_path :: proc(s, under: ^spec.Spec, part, style, pad: string) -> string {
	specs := [2]^spec.Spec{s, under}
	for from, k in specs {
		p := part_in(from, part)
		if p == nil {
			continue
		}
		for pl in from.plays[p.plays.first:base.span_end(p.plays)] {
			if pl.kind != .Steps {
				continue // its rows are another table's (events, notes)
			}
			for lane in from.lanes[pl.rows.first:base.span_end(pl.rows)] {
				if lane.pad == pad {
					path := strings.concatenate({strings.trim_prefix(pl.path, "song/"), "/steps/", pad})
					return k == 0 ? path : strings.concatenate({"style/", style, "/", path})
				}
			}
		}
	}
	return base.path_join("parts", part)
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
device_into_song :: proc(song: ^Song, from: ^spec.Spec, d: i32, beat_seconds: f64, drafts: ^spec.Drafts = nil) -> i32 {
	p, ok := spec.params_from_device(from, d, beat_seconds, song.bank)
	plays_program := device.DEVICE_TABLE[from.devices[d].kind].program
	if !ok && !plays_program {
		base.report(&song.findings, "asset_unavailable", .Error, from.devices[d].path, "%s: a sample set it plays is not loaded (offline, or not in the register)", from.devices[d].path)
	}
	fixed := make([dynamic]spec.Fixed_Tone, context.temp_allocator)
	if plays_program {
		// its row (an instrument's, an effect row's), read into a program at
		// this tempo: a program each placement
		program := spec.instrument_program(from, d, beat_seconds, song.bank, &song.programs, &song.findings, drafts, &fixed)
		if program < 0 {
			return -1
		}
		p[.Program] = f32(program)
	}
	for q in from.devices[d].beats {
		append(&fixed, spec.Fixed_Tone{base.path_join(from.devices[d].path, device.PARAM_TABLE[q].path), device.PARAM_TABLE[q].unit == .Hz})
	}
	for x in fixed {
		append(&song.fixed_lengths, Fixed_Length{i32(len(song.devices)), strings.clone(strings.trim_prefix(x.path, "song/")), 60 / beat_seconds, x.rate})
	}
	append(&song.devices, from.devices[d].kind)
	append(&song.params, p)
	append(&song.labels, device_label(from.devices[d]))
	return i32(len(song.devices) - 1)
}

// A device's label: an instrument's or an effect row's row as named (its
// name, or a table's name or class; "" written out in full), a built-in
// effect's kind.
@(private = "file")
device_label :: proc(d: spec.Device_Spec) -> string {
	if !device.DEVICE_TABLE[d.kind].program {
		return device.DEVICE_TABLE[d.kind].name
	}
	#partial switch x in d.row {
	case json.String:
		return strings.clone(x)
	case json.Object:
		if s, ok := x["name"].(json.String); ok {
			return strings.clone(s)
		}
		if s, ok := x["class"].(json.String); ok {
			return strings.clone(s)
		}
	}
	return ""
}

@(private)
chain_into_song :: proc(song: ^Song, from: ^spec.Spec, c: Span, beat_seconds: f64) -> Span {
	devices := make([dynamic]i32, context.temp_allocator)
	for d in from.chain[c.first:base.span_end(c)] {
		// an effect row that can't play (its findings say why) isn't placed
		if x := device_into_song(song, from, d, beat_seconds); x >= 0 {
			append(&devices, x)
		}
	}
	sp := Span{i32(len(song.chain)), i32(len(devices))}
	append(&song.chain, ..devices[:])
	return sp
}

// The track part `pi` plays `style` on (-1: the song's own), made the first
// time: the spec's settings over the style's over the part defaults; -1 when
// neither gives it an instrument. Its Tone lengths (an envelope's "8n", a
// delay's "8n.") are read at the tempo of the section it first plays in
// (`first`, its first note's beat; none: the first section of its style),
// where a part entering after an intro at another tempo hears them on the
// beat (tempo_fixed tells where it plays at another).
@(private = "file")
track_for :: proc(song: ^Song, s: ^spec.Spec, work: ^Work, pi: i32, name: string, style: i32, first: f64 = -1) -> int {
	for t, i in song.tracks {
		if t.part == pi && t.style == style {
			return i
		}
	}
	variant := style_name(song, style)
	beat_seconds := 60 / song.sections[0].bpm0
	if first >= 0 {
		beat_seconds = 60 / song.sections[section_from_beat(song, first)].bpm0
	} else {
		for sec in song.sections {
			if sec.style == style {
				beat_seconds = 60 / sec.bpm0
				break
			}
		}
	}
	t := Track{part = pi, style = style, gain = PART_GAIN, room = PART_ROOM, instrument = -1}
	under := style_spec(work, style)
	layers := [2]^spec.Spec{under, s}
	instrument: struct {
		from: ^spec.Spec,
		d:    i32,
	}
	for from in layers {
		p := part_in(from, name)
		if p == nil {
			continue
		}
		if p.instrument >= 0 {
			instrument = {from, p.instrument}
		}
		if !math.is_nan(f64(p.gain_db)) {
			t.gain = base.db_to_gain(p.gain_db)
		}
		if !math.is_nan(f64(p.room_db)) {
			t.room = base.db_to_gain(p.room_db)
		}
		if !math.is_nan(p.pan) {
			t.pan = p.pan
		}
		if p.effects.count >= 0 {
			t.chain = chain_into_song(song, from, p.effects, beat_seconds)
		}
		if p.sends.count > 0 {
			t.sends = sends_into_song(song, from, p.sends, t.sends, pi, base.path_join("parts", name))
		}
		if p.sidechain.source != "" {
			sc := sidechain_from_spec(song, p.sidechain, base.path_join("parts", name))
			if sc.mode != .None {
				t.sidechains = {i32(len(song.sidechains)), 1}
				append(&song.sidechains, sc)
			}
		}
	}
	if instrument.from == nil {
		path := part_in(s, name) != nil ? base.path_join("parts", name) : strings.concatenate({"style/", variant, "/parts/", name})
		base.report(&song.findings, "no_instrument", .Warning, path, "%s: no instrument, so it doesn't play: give it one (`instrument = {{ \"Synth\", ... }}`)", path)
		return -1
	}
	t.instrument = device_into_song(song, instrument.from, instrument.d, beat_seconds, &work.drafts)
	if t.instrument < 0 {
		return -1
	}
	append(&song.tracks, t)
	append(&work.notes, make([dynamic]Note_Row, context.temp_allocator))
	return len(song.tracks) - 1
}

// A track's sends: earlier ones (the style's) replaced by name.
@(private = "file")
sends_into_song :: proc(song: ^Song, from: ^spec.Spec, sends: Span, before: Span, part: i32, path: string) -> Span {
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
			if bus, ok := node_ref_from_name(song, s.to); ok && bus.kind == .Bus {
				rt := Route{{.Part, part}, bus, .Audio, base.db_to_gain(s.gain_db), false}
				if !slice.contains(song.routes[:], rt) {
					append(&song.routes, rt)
				}
				continue
			}
			base.report(&song.findings, "bad_value", .Error, base.path_join(path, "sends"), "%s/sends: there is no return or bus %q", path, s.to)
			continue
		}
		g := base.db_to_gain(s.gain_db)
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
	out := Sidechain{mode = .Hits, part = -1, pitch = -1, floor = base.db_to_gain(sc.depth_db), release = sc.release}
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
		if p, is_note := theory.pitch_from_string(note); is_note {
			out.pitch = p
		} else {
			out.pad = pad_intern(song, note)
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
	lo:       f64, // the earliest beat a note may start: from, or a pickup's
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
expand :: proc(song: ^Song, from_spec: ^spec.Spec, name: string, own: ^spec.Part_Spec, style, under: ^spec.Spec, pl: ^spec.Play_Spec, from, to: f64, out: ^[dynamic]Note_Row) {
	// its octave: the entry's, the song's part's, else the part's in the
	// style it plays over (`under`: a song's own entry inherits it too)
	octave := PART_OCTAVE
	if sp := part_in(under, name); sp != nil && !math.is_nan(sp.octave) {
		octave = int(sp.octave)
	}
	if own != nil && !math.is_nan(own.octave) {
		octave = int(own.octave)
	}
	if !math.is_nan(pl.octave) {
		octave = int(pl.octave)
	}
	x := Expand{song = song, from_spec = from_spec, play = pl, from = from, to = to, lo = from, octave = octave, out = out}
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
emit :: proc(x: ^Expand, beat, beats: f64, pitch: f32, velocity: f64, pad: u32, accent: f32 = 0) {
	if beat < x.lo - 1e-9 || beat >= x.to - 1e-9 {
		return
	}
	b := beat
	if x.swing > 0 && x.swing_at > 0 {
		q := (b - x.from) / x.swing_at
		if n := math.round(q); math.abs(q - n) < 1e-6 && int(n) %% 2 == 1 { // a pickup's before the range too
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
	append(x.out, Note_Row{time = max(t0, 0), duration = max(t1 - t0, 0.001), beat = beat, pitch = pitch, velocity = f32(clamp(vel, 0, 1)), pad = pad, accent = accent})
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
		pad := lane.pad != "" ? pad_intern(x.song, lane.pad) : 0
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
				accent: f32
				switch c {
				case 'x':
					vel = x.play.velocity
				case 'X':
					vel, accent = x.play.velocity, 1
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
				if pad == 0 {
					tok := x.play.note == "" ? "1" : x.play.note
					p, ok := token_pitch(x, tok, b, !strings.contains_any(tok, "ABCDEFGabcdefg"))
					if !ok {
						bad_play(x, "%s/note: %q is not a note or degree", x.play.path, tok)
						return
					}
					pitch = p
				}
				before := len(x.out)
				emit(x, b, hit_length(x, step, b), pitch, vel, pad, accent)
				held = len(x.out) > before
			}
			start += f64(bpb)
		}
	}
}

// Beats a sliding note's gate stays open past the next note's start.
SLIDE_OVERLAP :: 1.0 / 32

// A sequence's slot as played: a note (its pitch, accent, slide, velocity),
// a rest, or a hold of the note before; where it is in its cycle, in slots.
@(private = "file")
Cell :: struct {
	at, length: f64,
	kind:       enum u8 {Note, Rest, Hold},
	pitch:      f32,
	accent:     f32,
	slide:      bool,
	velocity:   f64,
}

@(private = "file")
expand_sequence :: proc(x: ^Expand) {
	sub := x.play.subdivision != "" ? x.play.subdivision : "8n"
	l, ok := tempo.length_from_string(sub, bpb_at(x.song, x.from))
	if !ok || l.in_seconds || l.value <= 0 {
		bad_play(x, "%s/subdivision: %q is not a Tone length (\"8n\", \"16n\")", x.play.path, sub)
		return
	}
	spec_ := x.from_spec
	tokens := spec_.tokens[x.play.rows.first:base.span_end(x.play.rows)]
	if len(tokens) == 0 || x.play.slots <= 0 {
		return
	}
	cycle := x.play.slots * l.value
	varies := spec_.varies[x.play.vary.first:base.span_end(x.play.vary)]
	slides := make([dynamic]int, context.temp_allocator) // notes whose gate runs into the next
	cells := make([dynamic]Cell, context.temp_allocator)
	// the pickup: its notes ending where the range starts
	if x.play.pickup.count > 0 {
		from := x.from - x.play.pickup_slots * l.value
		if from < -1e-9 {
			bad_play(x, "%s/pickup: it would start %.2f beats before the song does", x.play.path, -from)
		} else {
			for n in x.out {
				if n.beat < x.from - 1e-9 && tempo.beat_from_seconds(&x.song.tempo, n.time + n.duration) > from + 1e-9 {
					base.report(&x.song.findings, "pickup_overlaps", .Warning, x.play.path, "%s/pickup: it plays over the part's notes before it (at beat %.2f)", x.play.path, n.beat)
					break
				}
			}
			if cells_from_tokens(x, spec_.tokens[x.play.pickup.first:base.span_end(x.play.pickup)], from, l.value, &cells) {
				x.lo = from
				emit_cells(x, cells[:], from, l.value, &slides)
				x.lo = x.from
			}
		}
	}
	for c, k := x.from, 0; c < x.to - 1e-9; c, k = c + cycle, k + 1 {
		if !cells_from_tokens(x, tokens, c, l.value, &cells) {
			return
		}
		if len(varies) > 0 {
			vary_cells(x, varies[k % len(varies)], k, cells[:])
		}
		emit_cells(x, cells[:], c, l.value, &slides)
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

// A cycle's tokens from beat c as cells (a degree's pitch from the chord at
// its beat). False: a token is neither, reported.
@(private = "file")
cells_from_tokens :: proc(x: ^Expand, tokens: []spec.Token_Spec, c, slot: f64, out: ^[dynamic]Cell) -> bool {
	degrees := x.play.kind == .Degrees
	clear(out)
	for t in tokens {
		cell := Cell{at = t.at, length = t.length, velocity = x.play.velocity}
		switch t.text {
		case ".", "~", "r":
			cell.kind = .Rest
		case "-", "_":
			cell.kind = .Hold
		case:
			// "E5!" an accent, "E5~" its gate held into the next note (a mono
			// voice slides), "E5!~" both
			text := t.text
			for len(text) > 1 && (text[len(text) - 1] == '!' || text[len(text) - 1] == '~') {
				if text[len(text) - 1] == '!' {
					cell.accent = 1
				} else {
					cell.slide = true
				}
				text = text[:len(text) - 1]
			}
			p, is_pitch := token_pitch(x, text, c + t.at * slot, degrees)
			if !is_pitch {
				bad_play(x, "%s: %q is not a %s", x.play.path, t.text, degrees ? "degree (1, 5, 8; ! accent, ~ slide)" : "note (\"E5\", \"E5!\" accented, \"E5~\" sliding) or rest (\".\")")
				return false
			}
			cell.pitch = p
		}
		append(out, cell)
	}
	return true
}

// Repeat k of a sequence varied as v says (spec.Vary_Spec: its order).
@(private = "file")
vary_cells :: proc(x: ^Expand, v: spec.Vary_Spec, k: int, cells: []Cell) {
	key := x.song.key
	notes := make([dynamic]int, context.temp_allocator) // the cells that are notes
	for c, i in cells {
		if c.kind == .Note {
			append(&notes, i)
		}
	}
	if len(notes) == 0 {
		return
	}
	if v.reverse {
		for a, b := 0, len(notes) - 1; a < b; a, b = a + 1, b - 1 {
			cells[notes[a]].pitch, cells[notes[b]].pitch = cells[notes[b]].pitch, cells[notes[a]].pitch
		}
	}
	if v.invert {
		around, _ := theory.key_position(key, cells[notes[0]].pitch)
		for i in notes {
			step, offset := theory.key_position(key, cells[i].pitch)
			cells[i].pitch = theory.pitch_from_key_position(key, 2 * around - step, offset)
		}
	}
	for i in notes {
		if v.transpose != 0 {
			cells[i].pitch = theory.key_step(key, cells[i].pitch, int(math.round(v.transpose)))
		}
		cells[i].pitch += f32(12 * math.round(v.octave))
	}
	if v.thin > 0 {
		// seeded by the play and the repeat: another part's change moves nothing
		for i in notes[1:] {
			if base.hash_unit(base.hash_combine(x.seed, base.hash_combine(u64(k), u64(i)))) < v.thin {
				cells[i].kind = .Rest
			}
		}
	}
	if v.fill {
		// each run of rests steps from the note before toward the next (the
		// cycle's first after its last)
		for i := 0; i < len(cells); i += 1 {
			if cells[i].kind != .Rest {
				continue
			}
			prev, next := -1, -1
			for j := i - 1; j >= 0; j -= 1 {
				if cells[j].kind == .Note {
					prev = j
					break
				}
			}
			for j := i + 1; j < len(cells) + i; j += 1 {
				if cells[j % len(cells)].kind == .Note {
					next = j % len(cells)
					break
				}
			}
			if prev < 0 || next < 0 {
				continue
			}
			from, offset := theory.key_position(key, cells[prev].pitch)
			to, _ := theory.key_position(key, cells[next].pitch)
			dir := to > from ? 1 : -1
			run := 0
			for i < len(cells) && cells[i].kind == .Rest {
				run += 1
				step := from + dir * run
				if to != from && (dir > 0 ? step >= to : step <= to) {
					step = to - dir
				}
				cells[i] = Cell{at = cells[i].at, length = cells[i].length, kind = .Note, pitch = theory.pitch_from_key_position(key, step, offset), velocity = cells[prev].velocity * 0.85}
				i += 1
			}
		}
	}
	if v.velocity != 1 {
		for &c in cells {
			c.velocity *= v.velocity
		}
	}
}

// A cycle's cells from beat c played: a note emitted (swung, humanized), a
// hold extending the note before, a rest ending it.
@(private = "file")
emit_cells :: proc(x: ^Expand, cells: []Cell, c, slot: f64, slides: ^[dynamic]int) {
	held := false
	for cell in cells {
		b := c + cell.at * slot
		if b >= x.to - 1e-9 {
			break
		}
		switch cell.kind {
		case .Rest:
			held = false
		case .Hold:
			if held {
				extend_last(x, cell.length * slot)
			}
		case .Note:
			before := len(x.out)
			emit(x, b, hit_length(x, cell.length * slot, b), cell.pitch, cell.velocity, 0, cell.accent)
			held = len(x.out) > before
			if held && cell.slide {
				append(slides, len(x.out) - 1)
			}
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
			accent := f32(e.accent)
			if e.note == "" {
				emit(x, c + at, dur, 0, vel, 0, accent) // the instrument's own pitch
			} else if p, is_note := theory.pitch_from_string(e.note); is_note {
				emit(x, c + at, dur, p, vel, 0, accent)
			} else {
				emit(x, c + at, dur, 0, vel, pad_intern(x.song, e.note), accent) // a pad
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
		emit(x, b, hit_length(x, l.value, b), tones[k], x.play.velocity, 0)
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
		// the next chord leads from this one's close position: led from the
		// voiced one, an open voicing's raised tone would pull every chord
		// after it up, out of MIDI's range over a long section
		clear(previous)
		append(previous, ..notes[:])
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
	}
	bars := x.from_spec.bars[x.play.chords.rhythm.first:base.span_end(x.play.chords.rhythm)]
	if len(bars) == 0 {
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
				emit(x, b, end - b, n, x.play.velocity, 0)
			}
			b = end
		}
		return
	}
	// a step string a bar, the list cycled from the range's start, as steps' are
	cells := make([dynamic]u8, context.temp_allocator)
	bar := 0
	for start := x.from; start < x.to - 1e-9; start, bar = start + f64(bpb_at(x.song, start)), bar + 1 {
		clear(&cells)
		for c in transmute([]u8)bars[bar % len(bars)] {
			if c != ' ' && c != '|' {
				append(&cells, c)
			}
		}
		if len(cells) == 0 {
			continue
		}
		step := f64(bpb_at(x.song, start)) / f64(len(cells))
		for c, i in cells {
			if c != 'x' && c != 'X' {
				continue
			}
			b := start + f64(i) * step
			voiced(x, b, &previous, &notes)
			accent: f32 = c == 'X' ? 1 : 0
			for n in notes {
				emit(x, b, hit_length(x, step, b), n, x.play.velocity, 0, accent)
			}
		}
	}
}

// ---- transitions ---------------------------------------------------------------------

// Into a section, when it asks: a riser over the last two bars before it,
// an impact on its downbeat (each one note: the root of the chord it lands
// on at the part's octave, or the pad named), a roll of a pad over the beat
// before it (in place of that pad's hits there), a beat of silence for
// "pause". A riser, an impact and a fill play on the section's
// `transition_part` ("fx", "drums/snare": a part and a pad of it; a fill
// needs the pad): its track for the style the outgoing section plays, else
// its first.
add_transitions :: proc(s: ^spec.Spec, song: ^Song, work: ^Work) {
	for i in 1 ..< len(song.sections) {
		prev, next := song.sections[i - 1], song.sections[i]
		row := TRANSITIONS[next.transition]
		if row.play == nil {
			continue
		}
		at := next.start
		path := base.path_join(base.path_join("sections", next.name), "transition_part")
		ti := -1
		part, pad_name := next.transition_part, ""
		if slash := strings.index_byte(part, '/'); slash >= 0 {
			part, pad_name = part[:slash], part[slash + 1:]
		}
		pad := pad_name != "" ? pad_intern(song, pad_name) : 0
		if row.part {
			if part == "" || (row.pad && pad == 0) {
				base.report(&song.findings, "transition_needs_part", .Warning, path, "section %s: a %s plays on %s: give `transition_part`", next.name, row.name, row.wants)
				continue
			}
			for t, k in song.tracks {
				if song.parts[t.part] != part {
					continue
				}
				if ti < 0 || (t.style == prev.style && song.tracks[ti].style != prev.style) {
					ti = k
				}
			}
			if ti < 0 {
				base.report(&song.findings, "bad_value", .Error, path, "section %s: %q is not a part that plays (one with an instrument)", next.name, part)
				continue
			}
		}
		// its octave: the song's part's, else the part's in the style its
		// track plays (as the part's own entries)
		octave := PART_OCTAVE
		under := ti >= 0 ? style_spec(work, song.tracks[ti].style) : nil
		for p in ([]^spec.Part_Spec{part_in(under, part), part_in(s, part)}) {
			if p != nil && !math.is_nan(p.octave) {
				octave = int(p.octave)
			}
		}
		root := pad != 0 ? 0 : theory.pitch_from_degree(song.key, chord_from_beat(song, next.beat), 1, octave)
		source := strings.concatenate({"sections/", next.name, "/transition"})
		row.play({song, work, prev, next, at, ti, root, pad, source, row.velocity})
	}
}

// What a transition writes, into which section, on which track (-1: none:
// a pause), its note (a root or a pad), what made it, its level.
@(private = "file")
Transition_Call :: struct {
	song:       ^Song,
	work:       ^Work,
	prev, next: Section,
	at:         f64, // the section's start
	ti:         int,
	root:       f32,
	pad:        u32,
	source:     string,
	velocity:   f32,
}

// The transitions as rows: their names, whether they play on a part (and
// a pad of it), what to name for it, their level (v0.0.7's fx's: synth.lua's
// riser and impact), what they write (nil: nothing, as a cut's).
Transition_Row :: struct {
	name:     string,
	part:     bool,
	pad:      bool,
	wants:    string,
	velocity: f32,
	play:     proc(t: Transition_Call),
}

TRANSITIONS := [Transition]Transition_Row {
	.None   = {name = "none"},
	.Cut    = {name = "cut"},
	.Riser  = {"riser", true, false, "a part (\"fx\")", 0.35, transition_riser},
	.Fill   = {"fill", true, true, "a part and the pad it rolls (\"drums/snare\")", 0, transition_fill},
	.Impact = {"impact", true, false, "a part (\"fx\")", 0.8, transition_impact},
	.Pause  = {name = "pause", play = transition_pause},
}

@(private = "file")
transition_note :: proc(song: ^Song, t0, duration: f64, pitch, velocity: f32, pad: u32 = 0) -> Note_Row {
	return {time = t0, duration = duration, beat = tempo.beat_from_seconds(&song.tempo, t0), pitch = pitch, velocity = velocity, pad = pad}
}

// A riser over the last two bars before the section.
@(private = "file")
transition_riser :: proc(t: Transition_Call) {
	from_beat := max(t.prev.beat, t.next.beat - 2 * f64(t.prev.beats_per_bar))
	t0 := tempo.seconds_from_beat(&t.song.tempo, from_beat)
	append(&t.work.notes[t.ti], transition_note(t.song, t0, t.at - t0, t.root, t.velocity, t.pad))
	append(&t.song.regions, Region{t.song.tracks[t.ti].part, t0, t.at, t.source})
}

// An impact on its downbeat, a bar long.
@(private = "file")
transition_impact :: proc(t: Transition_Call) {
	bar := tempo.seconds_from_beat(&t.song.tempo, t.next.beat + f64(t.next.beats_per_bar)) - t.at
	append(&t.work.notes[t.ti], transition_note(t.song, t.at, bar, t.root, t.velocity, t.pad))
	append(&t.song.regions, Region{t.song.tracks[t.ti].part, t.at, t.at + bar, t.source})
}

// A roll of the pad over the beat before it, in place of the pad's hits
// there.
@(private = "file")
transition_fill :: proc(t: Transition_Call) {
	last := t.next.beat - 1
	notes := &t.work.notes[t.ti]
	#reverse for n, k in notes {
		if n.beat >= last - 1e-9 && n.beat < t.next.beat - 1e-9 && n.pad == t.pad {
			ordered_remove(notes, k)
		}
	}
	for st in 0 ..< 4 {
		b := last + f64(st) * 0.25
		t0 := tempo.seconds_from_beat(&t.song.tempo, b)
		append(notes, transition_note(t.song, t0, tempo.seconds_from_beat(&t.song.tempo, b + 0.25) - t0, 0, f32(0.35 + 0.15 * f64(st)), t.pad))
	}
	t0 := tempo.seconds_from_beat(&t.song.tempo, last)
	append(&t.song.regions, Region{t.song.tracks[t.ti].part, t0, t.at, t.source})
}

// A beat of silence before it: every note starting there taken out.
@(private = "file")
transition_pause :: proc(t: Transition_Call) {
	last := tempo.seconds_from_beat(&t.song.tempo, t.next.beat - 1)
	for &notes in t.work.notes {
		#reverse for n, k in notes {
			if n.time >= last - 1e-9 && n.time < t.at - 1e-9 {
				ordered_remove(&notes, k)
			}
		}
	}
}

// The notes of a track playing a layered instrument (an SFZ's), as it
// reads them, worked out here so a render from anywhere sees the same: a
// key in its keyswitch range switches (it doesn't sound) and every later
// note carries the last switch; each note its round (earlier notes of its
// key: a round robin's turn) and whether another is held when it starts
// (legato); and, when a region answers a note's end, a release note there
// (its duration: how long the note was held).
layered_notes :: proc(song: ^Song, work: ^Work) {
	for &notes, ti in work.notes {
		d := song.tracks[ti].instrument
		if d < 0 {
			continue
		}
		program := i32(song.params[d][.Program])
		if program < 0 || song.programs.programs[program].layer_mode != .All {
			continue
		}
		prog := song.programs.programs[program]
		slice.sort_by(notes[:], proc(a, b: Note_Row) -> bool {return a.time < b.time || (a.time == b.time && a.pitch < b.pitch)})
		last := prog.sw_default
		rounds: [128]u16
		held := make([dynamic]f64, context.temp_allocator) // the ends of the notes sounding
		releases := make([dynamic]Note_Row, context.temp_allocator)
		for &n in notes {
			key := int(math.round(n.pitch))
			if prog.sw_lo != 0 && key + 1 >= int(prog.sw_lo) && key + 1 <= int(prog.sw_hi) {
				n.kind = .Keyswitch
				last = u8(key + 1)
				continue
			}
			n.keyswitch = last
			if key >= 0 && key < 128 {
				n.round = rounds[key]
				rounds[key] += 1
			}
			#reverse for end, k in held {
				if end <= n.time + 1e-9 {
					unordered_remove(&held, k)
				}
			}
			n.legato = len(held) > 0
			append(&held, n.time + n.duration)
			if prog.release_layers {
				r := n
				r.kind = .Release
				r.time = n.time + n.duration
				r.beat = tempo.beat_from_seconds(&song.tempo, r.time)
				r.duration = n.duration // how long it was held (rt_decay)
				r.legato = false
				append(&releases, r)
			}
		}
		append(&notes, ..releases[:])
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
			row.seed = note_seed(song, song.tracks[ti], row)
			append_soa(&song.notes, row)
		}
	}
	notes_by_time(song)
}

// The regions by part, then start (the transitions' were added after the
// parts' own).
sort_regions :: proc(song: ^Song) {
	slice.stable_sort_by(song.regions[:], proc(a, b: Region) -> bool {
		return a.part < b.part || (a.part == b.part && a.start < b.start)
	})
}
