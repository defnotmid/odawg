package odawg_check

import "core:mem/virtual"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import base "../base"
import render "../render"
import song "../song"
import spec "../spec"

// A render measured as it streams, a chunk at a time (a sink's), is what it
// is measured whole: the same loudness (integrated, range, true and sample
// peak, momentary and short-term), mix peak and parts' peaks, so the same
// findings. A part with notes and no sound is found silent; a part with no
// notes isn't.
@(test)
test_measured_streaming :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	sp := new(spec.Spec)
	findings := make(base.Findings)
	testing.expect(t, spec.spec_from_json(`{ bpm: 120, seed: 3, sections: [ { name: "a", duration: "4m" } ],
		parts: { drums: { instrument: "MembraneSynth", play: [ { name: "a", notes: "C2 - C2 -", subdivision: "8n" } ] },
		         lead: { instrument: "PluckSynth", effects: [ { name: "FeedbackDelay", delay_time: "8n", feedback: 0.4, wet: 0.3 } ],
		                 play: [ { name: "a", notes: "A4 C5 E5 -", subdivision: "8n" } ] },
		         rest: { instrument: "Synth", gain_db: -200, play: [ { name: "a", notes: "C4", subdivision: "1m" } ] },
		         empty: { instrument: "Synth", play: [] } } }`, sp, &findings))
	s := new(song.Song)
	testing.expect(t, song.song_from_spec(sp, s))
	out := render.output_from_song(s, {stems = true})
	whole: Measuring
	measuring_init(&whole, s)
	measuring_push(&whole, out.left, out.right, out.stems)
	a := measures_from(&whole)
	for chunk in ([]int{8192, 1000, 1}) {
		streamed: Measuring
		measuring_init(&streamed, s)
		views := make([][2][]f32, len(out.stems))
		for at := 0; at < out.frames; at += chunk {
			n := min(chunk, out.frames - at)
			for st, p in out.stems {
				views[p] = {st[0][at:][:n], st[1][at:][:n]}
			}
			measuring_push(&streamed, out.left[at:][:n], out.right[at:][:n], views)
		}
		b := measures_from(&streamed)
		testing.expectf(t, a.loudness.integrated == b.loudness.integrated && a.loudness.range == b.loudness.range && a.loudness.true_peak == b.loudness.true_peak && a.loudness.sample_peak == b.loudness.sample_peak, "in chunks of %d: %v, whole: %v", chunk, b.loudness, a.loudness)
		testing.expectf(t, slice.equal(a.loudness.momentary, b.loudness.momentary) && slice.equal(a.loudness.short_term, b.loudness.short_term), "in chunks of %d the momentary or short-term loudness differs", chunk)
		testing.expect(t, a.mix_peak == b.mix_peak && slice.equal(a.part_peaks, b.part_peaks))
		for st, p in a.part_peak_steps {
			testing.expectf(t, slice.equal(st, b.part_peak_steps[p]), "in chunks of %d part %d's step peaks differ", chunk, p)
		}
		testing.expectf(t, slice.equal(a.mix_energy, b.mix_energy) && len(a.part_energy) == len(b.part_energy), "in chunks of %d the mix's energy differs", chunk)
		for e, p in a.part_energy {
			testing.expectf(t, slice.equal(e, b.part_energy[p]), "in chunks of %d part %d's energy differs", chunk, p)
		}
	}
	// the mix peak is the render's own, the silent part found silent
	testing.expect_value(t, a.mix_peak, render.peak_from_samples(out.left, out.right))
	got := make(base.Findings)
	findings_from_measures(s, &a, &got)
	silent, empty := false, false
	for f in got {
		silent ||= f.code == "silent_part" && f.path == "parts/rest"
		empty ||= f.code == "silent_part" && f.path == "parts/empty"
	}
	testing.expectf(t, silent, "a part with notes and no sound isn't found silent: %v", got[:])
	testing.expectf(t, !empty, "a part with no notes is found silent: %v", got[:])
	// a render without stems measures no part: none is found silent
	mix := render.output_from_song(s, {})
	only: Measuring
	measuring_init(&only, s)
	measuring_push(&only, mix.left, mix.right, nil)
	c := measures_from(&only)
	testing.expect_value(t, len(c.part_peaks), 0)
	none := make(base.Findings)
	findings_from_measures(s, &c, &none)
	for f in none {
		testing.expectf(t, f.code != "silent_part", "unmeasured, %s is found silent", f.path)
	}
}

// A part far under the mix in every section it plays is buried, told the
// raise that puts it 12 LU under where it's loudest. What counts is where
// it has notes: a part buried in one section and heard in another isn't;
// a part's tail in a quiet section neither clears it (faded) nor, in a
// range where it has no notes, finds it buried; a part with no notes in a
// range isn't judged there.
@(test)
test_buried_part :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	sp := new(spec.Spec)
	findings := make(base.Findings)
	// a 0-8 s, then c 8-10 s where nothing starts (faded's reverb tail alone:
	// the rest release in 50 ms), then b 10-18 s (its tail still under it)
	testing.expect(t, spec.spec_from_json(`{ bpm: 120, seed: 3, sections: [ { name: "a", duration: "4m" }, { name: "c", duration: "1m" }, { name: "b", duration: "4m" } ],
		automation: { "parts/half/gain_db": [ [ "a", -32, "step" ], [ "b", -10, "step" ] ] },
		parts: { lead: { instrument: { name: "Synth", "envelope/release": 0.05 }, play: [ { name: ["a", "b"], notes: "A4 - C5 -", subdivision: "4n" } ] },
		         under: { instrument: { name: "Synth", "envelope/release": 0.05 }, gain_db: -10, play: [ { name: ["a", "b"], notes: "E4 - - -", subdivision: "4n" } ] },
		         buried: { instrument: { name: "Synth", "envelope/release": 0.05 }, gain_db: -32, play: [ { name: ["a", "b"], notes: "C4 - - -", subdivision: "4n" } ] },
		         late: { instrument: { name: "Synth", "envelope/release": 0.05 }, gain_db: -32, play: [ { name: "b", notes: "G4 - - -", subdivision: "4n" } ] },
		         half: { instrument: { name: "Synth", "envelope/release": 0.05 }, play: [ { name: ["a", "b"], notes: "D4 - - -", subdivision: "4n" } ] },
		         faded: { instrument: { name: "Synth", "envelope/release": 0.05 }, effects: [ { name: "Reverb", decay: 10, wet: 1 } ], gain_db: -32, play: [ { name: "a", notes: "F4 - - -", subdivision: "4n" } ] } } }`, sp, &findings))
	s := new(song.Song)
	testing.expect(t, song.song_from_spec(sp, s))
	Case :: struct {
		from, to: f64,
		buried:   []string, // the parts found buried, the rest not
	}
	cases := []Case {
		{0, 0, {"buried", "late", "faded"}}, // half is heard in b; faded's tail in c doesn't clear it
		{0, 8, {"buried", "half", "faded"}}, // late has no notes in a
		{10, 18, {"buried", "late"}}, // faded's tail is in b, its notes aren't
	}
	for cs in cases {
		out := render.output_from_song(s, {from = cs.from, to = cs.to, stems = true})
		got := make(base.Findings)
		findings_from_render(s, &out, &got)
		said: map[string]string
		for x in got {
			if x.code == "buried_part" {
				said[strings.trim_prefix(x.path, "parts/")] = x.message
			}
		}
		for part in s.parts {
			want := slice.contains(cs.buried, part)
			testing.expectf(t, (part in said) == want, "from %v to %v: %s found buried %v, want %v (%v)", cs.from, cs.to, part, part in said, want, said)
		}
		// the raise it names: the 30 LU or so it sits under, less 12
		msg := said["buried"]
		at := strings.index(msg, "by about ")
		testing.expectf(t, at >= 0, "no raise named: %q", msg)
		if at >= 0 {
			db, _ := strconv.parse_f64(strings.fields(msg[at + len("by about "):])[0])
			testing.expectf(t, db > 10 && db < 25, "from %v: a raise of %v dB for a part 32 dB down beside one 10 dB down", cs.from, db)
		}
	}
}

// The balance table: every part against the mix in every section and over
// the song (part-major, sections + 1 rows a part). Where a part plays is
// where its notes are written: one humanized ahead of its section's first
// beat plays in that section, not the one before. A row's peak is its
// stem's over the section; a click reads loud in peak and low in loudness,
// so it can be told from a quiet part.
@(test)
test_balance_rows :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	sp := new(spec.Spec)
	findings := make(base.Findings)
	testing.expect(t, spec.spec_from_json(`{ bpm: 120, seed: 7, sections: [ { name: "a", duration: "2m", chords: "C F" }, { name: "b", duration: "2m", chords: "G C" } ],
		parts: { pad: { instrument: "Synth", play: [ { name: ["a", "b"], chords: { voicing: "open" }, octave: 4 } ] },
		         hit: { instrument: { name: "NoiseSynth", "envelope/decay": 0.02, "envelope/sustain": 0 }, play: [ { name: "b", notes: "C4", subdivision: "1m" } ] },
		         late: { instrument: "Synth", play: [ { name: "b", notes: "E4 G4 C5 G4", subdivision: "4n", humanize: 0.02 } ] } } }`, sp, &findings))
	s := new(song.Song)
	testing.expect(t, song.song_from_spec(sp, s))
	// late's first note, written on b's first beat, humanized ahead of it
	early := false
	for i in 0 ..< len(s.notes) {
		early ||= s.parts[s.tracks[0].part] != "" && s.notes.beat[i] == s.sections[1].beat && s.notes.time[i] < s.sections[1].start
	}
	testing.expect(t, early, "no note humanized ahead of b (the seed): the test can't see it")
	out := render.output_from_song(s, {stems = true})
	m: Measuring
	measuring_init(&m, s)
	defer measuring_destroy(&m)
	measuring_push(&m, out.left, out.right, out.stems)
	measures := measures_from(&m)
	rows := balance_from_measures(s, &measures)
	per := len(s.sections) + 1
	testing.expect_value(t, len(rows), len(s.parts) * per)
	row :: proc(s: ^song.Song, rows: []Balance_Row, part: string, section: int) -> Balance_Row {
		return rows[song.part_index(s, part) * (len(s.sections) + 1) + section]
	}
	testing.expect(t, row(s, rows, "pad", 0).plays && row(s, rows, "pad", 1).plays, "pad plays in a and b")
	testing.expect(t, !row(s, rows, "late", 0).plays && row(s, rows, "late", 1).plays, "late plays in b alone, its early note too")
	testing.expect(t, !row(s, rows, "hit", 0).plays && row(s, rows, "hit", 1).plays, "hit plays in b alone")
	for r in rows {
		if r.plays && !math.is_inf(r.lufs) {
			testing.expectf(t, abs(r.under - (r.mix - r.lufs)) < 1e-9, "under %v is not mix %v less lufs %v", r.under, r.mix, r.lufs)
		}
	}
	// the song row: over the sections it plays
	pad_song, late_song := row(s, rows, "pad", 2), row(s, rows, "late", 2)
	lo, hi := min(row(s, rows, "pad", 0).lufs, row(s, rows, "pad", 1).lufs), max(row(s, rows, "pad", 0).lufs, row(s, rows, "pad", 1).lufs)
	testing.expectf(t, pad_song.plays && pad_song.lufs >= lo - 0.5 && pad_song.lufs <= hi + 0.5, "pad over the song %v, its sections %v..%v", pad_song.lufs, lo, hi)
	testing.expectf(t, late_song.lufs == row(s, rows, "late", 1).lufs && late_song.mix == row(s, rows, "late", 1).mix, "late over the song is late in b")
	// each row's peak is its stem's over the section's whole steps
	STEP :: render.RATE / 10
	for p in 0 ..< len(s.parts) {
		st := out.stems[p]
		for sec, j in s.sections {
			first := (int(math.round(sec.start * render.RATE)) + STEP - 1) / STEP
			last := int(math.round(sec.stop * render.RATE)) / STEP
			want := f64(base.gain_to_db(base.Gain(render.peak_from_samples(st[0][first * STEP:min(last * STEP, len(st[0]))], st[1][first * STEP:min(last * STEP, len(st[1]))]))))
			testing.expectf(t, rows[p * per + j].peak_db == want, "%s in %s: peak %v, its stem's %v", s.parts[p], sec.name, rows[p * per + j].peak_db, want)
		}
	}
	// a click (20 ms of noise): its peak far over its loudness, more than a
	// held part's
	hit, pad := row(s, rows, "hit", 1), row(s, rows, "pad", 1)
	testing.expectf(t, hit.peak_db - hit.lufs > pad.peak_db - pad.lufs + 3, "hit peak %.1f / %.1f LUFS against pad %.1f / %.1f", hit.peak_db, hit.lufs, pad.peak_db, pad.lufs)
}

// A part's role holds it to its role's band where it plays: a comp part 30
// dB down is told the raise that puts it in band (and raised by that, it
// isn't told again); a pad pushed up is told to come down; a texture far
// under the mix is in its band and not buried; an fx hit is judged by its
// peak (a quiet click told, a loud one not). A song naming roles without a
// melody is told so; an unknown role is an error.
@(test)
test_role_balance :: proc(t: ^testing.T) {
	text :: proc(keys_gain: string, lead_role: string) -> string {
		return strings.concatenate({`{ bpm: 120, seed: 5, sections: [ { name: "a", duration: "4m", chords: "C F G C" }, { name: "b", duration: "4m", chords: "A F G C" } ],
			parts: {
				lead: { instrument: "Synth", role: "`, lead_role, `", play: [ { name: ["a", "b"], notes: "C5 E5 G5 E5", subdivision: "4n" } ] },
				keys: { instrument: "Synth", role: "comp", gain_db: `, keys_gain, `, play: [ { name: ["a", "b"], chords: { voicing: "open", rhythm: "x.x.x.x." }, octave: 4 } ] },
				bass: { instrument: "Synth", role: "bass", play: [ { name: ["a", "b"], degrees: "1 . 5 .", subdivision: "4n", octave: 2 } ] },
				pad: { instrument: "Synth", role: "pad", gain_db: 6, play: [ { name: ["a", "b"], chords: { voicing: "spread" }, octave: 3 } ] },
				tex: { instrument: "Synth", role: "texture", gain_db: -24, play: [ { name: ["a", "b"], notes: "C6", subdivision: "1m" } ] },
				fx_quiet: { instrument: { name: "NoiseSynth", "envelope/decay": 0.02, "envelope/sustain": 0 }, role: "fx", gain_db: -40, play: [ { name: "b", notes: "C4", subdivision: "1m" } ] },
				fx_loud: { instrument: { name: "NoiseSynth", "envelope/decay": 0.02, "envelope/sustain": 0 }, role: "fx", gain_db: 6, play: [ { name: "b", notes: "C4", subdivision: "1m" } ] } } }`}, context.temp_allocator)
	}
	check_song :: proc(t: ^testing.T, text: string) -> (said: map[string]string, codes: map[string]bool) {
		sp := new(spec.Spec)
		findings := make(base.Findings)
		testing.expect(t, spec.spec_from_json(text, sp, &findings))
		s := new(song.Song)
		song.song_from_spec(sp, s)
		for f in s.findings {
			codes[f.code] = true
		}
		out := render.output_from_song(s, {stems = true})
		got := make(base.Findings)
		findings_from_render(s, &out, &got)
		for f in got {
			codes[f.code] = true
			if f.code == "role_balance" || f.code == "buried_part" {
				said[strings.concatenate({f.code, " ", f.path})] = f.message
			}
		}
		return
	}
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	said, codes := check_song(t, text("-30", "melody"))
	keys := said["role_balance parts/keys"]
	testing.expectf(t, strings.contains(keys, "raise parts/keys/gain_db"), "comp 30 dB down: %q (all: %v)", keys, said)
	testing.expectf(t, strings.contains(said["role_balance parts/pad"], "lower parts/pad/gain_db"), "a pad pushed up: %q", said["role_balance parts/pad"])
	testing.expectf(t, "buried_part parts/tex" not_in said, "a texture with its role is buried_part's: %v", said)
	testing.expectf(t, "role_balance parts/fx_quiet" in said && "role_balance parts/fx_loud" not_in said, "fx by peak: %v", said)
	testing.expect(t, !codes["no_melody"], "a song with a melody is told it has none")
	// raised by what it was told, the comp part sits in its band
	if at := strings.index(keys, "by about "); at >= 0 {
		raise, _ := strconv.parse_f64(strings.fields(keys[at + len("by about "):])[0])
		again, _ := check_song(t, text(fmt.tprintf("%.1f", -30 + raise), "melody"))
		testing.expectf(t, "role_balance parts/keys" not_in again, "raised by %.1f dB it's still told: %q", raise, again["role_balance parts/keys"])
	}
	// roles named, none a melody; a role that isn't one
	_, codes = check_song(t, text("-30", "counter"))
	testing.expect(t, codes["no_melody"], "no melody: not told")
	_, codes = check_song(t, text("-30", "lead_vocal"))
	testing.expect(t, codes["bad_value"], "an unknown role: not an error")
}
