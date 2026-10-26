package odawg_song

import "core:math"
import "core:slice"
import "core:strings"
import base "../base"
import tempo "../tempo"
import theory "../theory"

// The defaults a generator falls into when nothing is chosen on purpose
// (SOUND_DESIGN.md, writing a song that isn't the default one), as signs a
// composed song is read for. A song showing DEFAULT_SIGNS or more of them
// is a finding (default_song): one sign, or a few, is a choice (a dub
// vamp at 118 with a kick on every beat); most of them at once is the
// song nobody chose. Each sign is a row: add a row, never a branch.
DEFAULT_SIGNS :: 4

Default_Sign :: struct {
	name:  string,
	holds: proc(s: ^Song) -> bool,
}

DEFAULT_SIGN_TABLE := []Default_Sign {
	{"a tempo of 118-122", sign_tempo},
	{"a kick on every beat", sign_four_on_the_floor},
	{"A minor, D minor or C major, or i-VI-III-VII (I-V-vi-IV turned)", sign_default_key},
	{"no feel (on the grid, every part at one velocity, no accents)", sign_no_feel},
	{"the same parts in every section", sign_static_arrangement},
	{"a chord loop (two chords, or one progression throughout)", sign_chord_loop},
}

// What is read for the signs is music: two parts or more, playing over
// four bars or more between them. A one-shot (a host's sound: one part, a
// note, no tempo or key) would show the defaults it never chose.
DEFAULT_MUSIC_PARTS :: 2
DEFAULT_MUSIC_BARS :: 4

// Reads the composed song for the signs; at DEFAULT_SIGNS or more, a
// warning naming them.
default_song :: proc(s: ^Song) {
	if len(s.sections) == 0 || len(s.notes) == 0 || !is_music(s) {
		return
	}
	held := make([dynamic]string, context.temp_allocator)
	for row in DEFAULT_SIGN_TABLE {
		if row.holds(s) {
			append(&held, row.name)
		}
	}
	if len(held) >= DEFAULT_SIGNS {
		base.report(&s.findings, "default_song", .Warning, "song", "the song sits on %d of the defaults a generator falls into: %s. Choose some on purpose: a tempo, a key, a feel, an arrangement (SOUND_DESIGN.md, writing a song that isn't the default one)", len(held), strings.join(held[:], "; ", context.temp_allocator))
	}
}

// Two parts or more with notes, and four bars or more holding a note (by
// its beat) between them.
@(private = "file")
is_music :: proc(s: ^Song) -> bool {
	parts := make([]bool, len(s.parts), context.temp_allocator)
	beats := make([dynamic]f64, context.temp_allocator)
	for t in s.tracks {
		for i in t.notes.first ..< base.span_end(t.notes) {
			if s.notes.kind[i] == .Attack {
				parts[t.part] = true
				append(&beats, s.notes.beat[i])
			}
		}
	}
	count := 0
	for p in parts {
		count += p ? 1 : 0
	}
	if count < DEFAULT_MUSIC_PARTS {
		return false
	}
	slice.sort(beats[:])
	bars := 0
	for sec in s.sections {
		bpb := f64(sec.beats_per_bar)
		for bar := sec.beat; bar < sec.beat + sec.beats - 1e-6; bar += bpb {
			k, _ := slice.binary_search_by(beats[:], bar - 1e-6, proc(x, target: f64) -> slice.Ordering {return x < target ? .Less : .Greater})
			if k < len(beats) && beats[k] < bar + bpb - 1e-6 {
				bars += 1
			}
		}
	}
	return bars >= DEFAULT_MUSIC_BARS
}

// Every section's tempo within 118-122.
@(private = "file")
sign_tempo :: proc(s: ^Song) -> bool {
	for sec in s.sections {
		if min(sec.bpm0, sec.bpm1) < 118 || max(sec.bpm0, sec.bpm1) > 122 {
			return false
		}
	}
	return true
}

// Where the drums play (a bar with a note of a part playing a kick pad, or
// of a part whose role is drums), a kick on every beat in 90% of those
// bars or more. The kick: a `kick` pad (a machine's, a set's), or a drums
// part's lowest pitch. A song with neither isn't judged (false): a part's
// name isn't read.
@(private = "file")
sign_four_on_the_floor :: proc(s: ^Song) -> bool {
	kick := base.name_id("kick")
	drums := make([]bool, len(s.parts), context.temp_allocator)
	lowest := make([]f32, len(s.parts), context.temp_allocator)
	slice.fill(lowest, math.F32_MAX)
	for t in s.tracks {
		for i in t.notes.first ..< base.span_end(t.notes) {
			if s.notes.kind[i] != .Attack {
				continue
			}
			if s.notes.pad[i] == kick {
				drums[t.part] = true
			}
			if s.roles[t.part] == .Drums {
				drums[t.part] = true
				lowest[t.part] = min(lowest[t.part], s.notes.pitch[i])
			}
		}
	}
	// the beats a kick lands on, and the bars the drums play in (beats as
	// composed: swing and humanize don't move them)
	kicks := make([dynamic]f64, context.temp_allocator)
	played := make([dynamic]f64, context.temp_allocator)
	for t in s.tracks {
		if !drums[t.part] {
			continue
		}
		for i in t.notes.first ..< base.span_end(t.notes) {
			if s.notes.kind[i] != .Attack {
				continue
			}
			b := s.notes.beat[i]
			append(&played, b)
			is_kick := s.notes.pad[i] == kick || (s.roles[t.part] == .Drums && s.notes.pad[i] == 0 && s.notes.pitch[i] == lowest[t.part])
			if is_kick {
				append(&kicks, b)
			}
		}
	}
	if len(played) == 0 {
		return false
	}
	slice.sort(kicks[:])
	slice.sort(played[:])
	near :: proc(xs: []f64, at, width: f64) -> bool {
		k, _ := slice.binary_search_by(xs, at - 1e-6, proc(x, target: f64) -> slice.Ordering {return x < target ? .Less : .Greater})
		return k < len(xs) && xs[k] < at + width - 1e-6
	}
	bars, full := 0, 0
	for sec in s.sections {
		bpb := f64(sec.beats_per_bar)
		for bar := sec.beat; bar < sec.beat + sec.beats - 1e-6; bar += bpb {
			if !near(played[:], bar, bpb) {
				continue
			}
			bars += 1
			every := true
			for k in 0 ..< sec.beats_per_bar {
				every &&= near(kicks[:], bar + f64(k), 1e-3)
			}
			full += every ? 1 : 0
		}
	}
	return bars > 0 && f64(full) >= 0.9 * f64(bars)
}

// The key a generator reaches for (A minor, D minor, C major), or a
// section playing i-VI-III-VII as a cycle in any key (Am F C G; turned, it's
// I-V-vi-IV: C G Am F).
@(private = "file")
sign_default_key :: proc(s: ^Song) -> bool {
	AEOLIAN :: [7]i8{0, 2, 3, 5, 7, 8, 10}
	IONIAN :: [7]i8{0, 2, 4, 5, 7, 9, 11}
	k := s.key
	if (k.scale == AEOLIAN && (k.tonic == 9 || k.tonic == 2)) || (k.scale == IONIAN && k.tonic == 0) {
		return true
	}
	// a chord's third: 3 minor, 4 major (0: neither)
	third :: proc(c: theory.Chord) -> int {
		intervals := c.intervals
		for iv in intervals[:c.count] {
			if iv == 3 || iv == 4 {
				return int(iv)
			}
		}
		return 0
	}
	// i, VI, III, VII above a minor tonic
	SHAPE :: [4][2]int{{0, 3}, {8, 4}, {3, 4}, {10, 4}}
	for sec in s.sections {
		chords := s.chords[sec.chords.first:base.span_end(sec.chords)]
		if len(chords) != 4 && !(len(chords) == 8 && slice.equal(chords[:4], chords[4:])) {
			continue
		}
		for turn in 0 ..< 4 {
			tonic := chords[turn].root
			fits := true
			for shape, j in SHAPE {
				c := chords[(turn + j) % 4]
				fits &&= (c.root - tonic + 12) % 12 == shape[0] && third(c) == shape[1]
			}
			if fits {
				return true
			}
		}
	}
	return false
}

// No feel: every note on its beat's grid time (no swing, no humanize,
// wherever they'd come from), every part at one velocity, no accents.
@(private = "file")
sign_no_feel :: proc(s: ^Song) -> bool {
	velocity := make([]f32, len(s.parts), context.temp_allocator)
	slice.fill(velocity, -1)
	for t in s.tracks {
		for i in t.notes.first ..< base.span_end(t.notes) {
			if s.notes.kind[i] != .Attack {
				continue
			}
			if s.notes.accent[i] > 0 || abs(s.notes.time[i] - tempo.seconds_from_beat(&s.tempo, s.notes.beat[i])) > 0.0005 {
				return false
			}
			v := &velocity[t.part]
			if v^ < 0 {
				v^ = s.notes.velocity[i]
			} else if v^ != s.notes.velocity[i] {
				return false
			}
		}
	}
	return true
}

// With two sections or more, every one playing the same parts (a note of
// each written there).
@(private = "file")
sign_static_arrangement :: proc(s: ^Song) -> bool {
	if len(s.sections) < 2 {
		return false
	}
	plays := sections_parts(s)
	first := plays[:len(s.parts)]
	for j in 1 ..< len(s.sections) {
		if !slice.equal(first, plays[j * len(s.parts):][:len(s.parts)]) {
			return false
		}
	}
	return true
}

// Two chords or fewer over the song, or (two sections or more) every section
// the same progression.
@(private = "file")
sign_chord_loop :: proc(s: ^Song) -> bool {
	chords_seen := make([dynamic]theory.Chord, context.temp_allocator)
	for sec in s.sections {
		for c in s.chords[sec.chords.first:base.span_end(sec.chords)] {
			if !slice.contains(chords_seen[:], c) {
				append(&chords_seen, c)
			}
		}
	}
	if len(chords_seen) > 0 && len(chords_seen) <= 2 {
		return true
	}
	if len(s.sections) < 2 {
		return false
	}
	first := s.chords[s.sections[0].chords.first:base.span_end(s.sections[0].chords)]
	for sec in s.sections[1:] {
		if !slice.equal(first, s.chords[sec.chords.first:base.span_end(sec.chords)]) {
			return false
		}
	}
	return true
}

// Which parts have a note written in which section (by its beat):
// [section * parts + part]. In temp memory.
@(private = "file")
sections_parts :: proc(s: ^Song) -> []bool {
	plays := make([]bool, len(s.sections) * len(s.parts), context.temp_allocator)
	for t in s.tracks {
		for i in t.notes.first ..< base.span_end(t.notes) {
			if s.notes.kind[i] != .Attack {
				continue
			}
			b := s.notes.beat[i]
			for sec, j in s.sections {
				if b >= sec.beat && b < sec.beat + sec.beats {
					plays[j * len(s.parts) + int(t.part)] = true
				}
			}
		}
	}
	return plays
}
