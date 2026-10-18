package odawg_song

import "core:math"
import "core:strings"
import base "../base"
import device "../device"
import tempo "../tempo"
import theory "../theory"

// Questions about a composed song, in song seconds (from its first beat) or
// beats; a host adds `song.start` for its own clock. Positions and ranges
// use tempo's grammar: "drop", "drop@1m", "drop@-0.5s", "2:0:0", "end",
// "drop..outro", "drop@4m..".

section_from_beat :: proc(song: ^Song, beat: f64) -> int {
	for s, i in song.sections {
		if beat < s.beat + s.beats {
			return i
		}
	}
	return len(song.sections) - 1
}

section_from_seconds :: proc(song: ^Song, t: f64) -> int {
	return section_from_beat(song, tempo.beat_from_seconds(&song.tempo, t))
}

section_from_name :: proc(song: ^Song, name: string) -> int {
	for s, i in song.sections {
		if s.name == name {
			return i
		}
	}
	return -1
}

total_beats :: proc(song: ^Song) -> f64 {
	if len(song.sections) == 0 {
		return 0
	}
	last := song.sections[len(song.sections) - 1]
	return last.beat + last.beats
}

// The beat `bars` bars from the start, each bar its section's meter long.
beat_from_bars :: proc(song: ^Song, bars: f64) -> f64 {
	left := bars
	for s in song.sections {
		if left < f64(s.bars) {
			return s.beat + left * f64(s.beats_per_bar)
		}
		left -= f64(s.bars)
	}
	bpb := len(song.sections) > 0 ? song.sections[len(song.sections) - 1].beats_per_bar : 4
	return total_beats(song) + left * f64(bpb)
}

// The beat of a position. Bars in an offset are the anchor's section's.
beat_from_position :: proc(song: ^Song, text: string) -> (beat: f64, ok: bool) {
	s := strings.trim_space(text)
	anchor, offset := s, ""
	if at := strings.index_byte(s, '@'); at >= 0 {
		anchor, offset = s[:at], s[at + 1:]
	} else if _, is_length := tempo.length_from_string(s, 4); is_length {
		anchor, offset = "", s
	}
	origin: f64
	bpb := len(song.sections) > 0 ? song.sections[0].beats_per_bar : 4
	switch anchor {
	case "", "start":
	case "end":
		origin = total_beats(song)
		if len(song.sections) > 0 {
			bpb = song.sections[len(song.sections) - 1].beats_per_bar
		}
	case:
		found := false
		if i := section_from_name(song, anchor); i >= 0 {
			origin, bpb, found = song.sections[i].beat, song.sections[i].beats_per_bar, true
		} else {
			for m in song.markers {
				if m.name == anchor {
					origin, bpb, found = m.beat, song.sections[section_from_beat(song, m.beat)].beats_per_bar, true
					break
				}
			}
		}
		if !found {
			return 0, false
		}
	}
	if offset == "" {
		return origin, true
	}
	// "2:0:0" from the start counts bars across the sections' meters
	if anchor == "" && strings.count(offset, ":") > 0 {
		head := offset[:strings.index_byte(offset, ':')]
		bars := tempo.length_from_string(strings.concatenate({head, "s"}, context.temp_allocator), 4) or_return
		rest := tempo.length_from_string(strings.concatenate({"0", offset[len(head):]}, context.temp_allocator), bpb) or_return
		return beat_from_bars(song, bars.value) + rest.value, true
	}
	l := tempo.length_from_string(offset, bpb) or_return
	if l.in_seconds {
		return tempo.beat_from_seconds(&song.tempo, tempo.seconds_from_beat(&song.tempo, origin) + l.value), true
	}
	return origin + l.value, true
}

// The beats [from, to) of a range: a section is all of it, an end that is a
// section runs to that section's end, an open end to the end of the section
// the other end names (or the song's).
beats_from_range :: proc(song: ^Song, text: string) -> (from, to: f64, ok: bool) {
	s := strings.trim_space(text)
	section_end :: proc(song: ^Song, name: string) -> (f64, bool) {
		if i := section_from_name(song, name); i >= 0 {
			return song.sections[i].beat + song.sections[i].beats, true
		}
		return 0, false
	}
	anchor_of :: proc(p: string) -> string {
		if at := strings.index_byte(p, '@'); at >= 0 {
			return p[:at]
		}
		return p
	}
	if dots := strings.index(s, ".."); dots >= 0 {
		a, b := strings.trim_space(s[:dots]), strings.trim_space(s[dots + 2:])
		if a == "" && b == "" {
			return 0, 0, false
		}
		from = a == "" ? 0 : (beat_from_position(song, a) or_return)
		if b == "" {
			end, is_section := section_end(song, anchor_of(a))
			to = is_section ? end : total_beats(song)
		} else if end, is_section := section_end(song, b); is_section {
			to = end
		} else {
			to = beat_from_position(song, b) or_return
		}
		return from, to, to > from
	}
	if i := section_from_name(song, s); i >= 0 {
		return song.sections[i].beat, song.sections[i].beat + song.sections[i].beats, true
	}
	from = beat_from_position(song, s) or_return
	end, is_section := section_end(song, anchor_of(s))
	to = is_section ? end : total_beats(song)
	return from, to, to > from
}

// Song seconds of a position.
seconds_from_position :: proc(song: ^Song, text: string) -> (seconds: f64, ok: bool) {
	b := beat_from_position(song, text) or_return
	return tempo.seconds_from_beat(&song.tempo, b), true
}

// How long a length lasts from a position (a bar is shorter where the
// tempo is higher).
seconds_from_length :: proc(song: ^Song, length, at: string) -> (seconds: f64, ok: bool) {
	start := at == "" ? 0 : (beat_from_position(song, at) or_return)
	bpb := len(song.sections) > 0 ? song.sections[section_from_beat(song, start)].beats_per_bar : 4
	l := tempo.length_from_string(length, bpb) or_return
	if l.in_seconds {
		return l.value, true
	}
	return tempo.seconds_from_beat(&song.tempo, start + l.value) - tempo.seconds_from_beat(&song.tempo, start), true
}

// The grid point ("8n", "1m") nearest song seconds `t`, counted from the
// start of the section it is in.
seconds_snapped :: proc(song: ^Song, t: f64, grid: string) -> (seconds: f64, ok: bool) {
	if len(song.sections) == 0 {
		return t, false
	}
	b := tempo.beat_from_seconds(&song.tempo, t)
	s := song.sections[section_from_beat(song, b)]
	l := tempo.length_from_string(grid, s.beats_per_bar) or_return
	if l.in_seconds || l.value <= 0 {
		return t, false
	}
	return tempo.seconds_from_beat(&song.tempo, s.beat + math.round((b - s.beat) / l.value) * l.value), true
}

// Where a moment is in the form.
Place :: struct {
	section:  int,
	name:     string,
	progress: f64, // 0..1 through the section
	bar:      int, // 0-based bar in the section
	beat:     f64, // beat in the bar
}

place_from_seconds :: proc(song: ^Song, t: f64) -> (p: Place, ok: bool) {
	if len(song.sections) == 0 || t < 0 || t >= song.duration {
		return {}, false
	}
	b := tempo.beat_from_seconds(&song.tempo, t)
	i := section_from_beat(song, b)
	s := song.sections[i]
	into := b - s.beat
	return {i, s.name, clamp((t - s.start) / (s.stop - s.start), 0, 1), int(into / f64(s.beats_per_bar)), math.mod(into, f64(s.beats_per_bar))}, true
}

chord_from_beat :: proc(song: ^Song, beat: f64) -> theory.Chord {
	if len(song.sections) == 0 {
		return theory.tonic_chord(song.key)
	}
	s := song.sections[section_from_beat(song, beat)]
	if s.chords.count == 0 {
		return theory.tonic_chord(song.key)
	}
	bar := max(int(math.floor((beat - s.beat) / f64(s.beats_per_bar) + 1e-9)), 0)
	return song.chords[int(s.chords.first) + bar % int(s.chords.count)]
}

// An in-key note: a degree of the chord at a position, in an octave (a blip
// that sits in the harmony).
pitch_from_degree_at :: proc(song: ^Song, degree: int, at: string, octave: int) -> (midi: f32, ok: bool) {
	b := beat_from_position(song, at) or_return
	return theory.pitch_from_degree(song.key, chord_from_beat(song, b), degree, octave), true
}

// Which notes a question is about: a part ("" any), a pad or note ("kick",
// "A2"; "" any), a range ("" all); the notes written (made ones too, an SFZ's
// release notes and keyswitches, with `made`).
Note_Filter :: struct {
	part:  string,
	note:  string,
	range: string,
	made:  bool,
}

// A filter made ready for a scan of the notes.
@(private = "file")
Matcher :: struct {
	part:     i32, // -1 any
	pad:      u32, // 0 any
	pitch:    f32, // -1 any
	from, to: f64, // seconds
	made:     bool, // the notes compose made too
}

@(private = "file")
matcher_from_filter :: proc(song: ^Song, f: Note_Filter) -> (m: Matcher, ok: bool) {
	m = {part = -1, pitch = -1, from = -math.INF_F64, to = math.INF_F64, made = f.made}
	if f.part != "" {
		for n, i in song.parts {
			if n == f.part {
				m.part = i32(i)
			}
		}
		if m.part < 0 {
			return m, false
		}
	}
	if f.note != "" {
		if p, is_pitch := theory.pitch_from_string(f.note); is_pitch {
			m.pitch = p
		} else {
			m.pad = base.name_id(f.note)
		}
	}
	if f.range != "" {
		b0, b1 := beats_from_range(song, f.range) or_return
		m.from, m.to = tempo.seconds_from_beat(&song.tempo, b0), tempo.seconds_from_beat(&song.tempo, b1)
	}
	return m, true
}

@(private = "file")
matches :: proc(song: ^Song, m: Matcher, i: i32) -> bool {
	n := song.notes[i]
	if n.kind != .Attack && !m.made {
		return false
	}
	if m.part >= 0 && song.tracks[n.track].part != m.part {
		return false
	}
	if m.pad != 0 && n.pad != m.pad {
		return false
	}
	if m.pitch >= 0 && math.abs(n.pitch - m.pitch) > 0.01 {
		return false
	}
	return n.time >= m.from - 1e-9 && n.time < m.to - 1e-9
}

// The notes a track plays as written (not the ones compose made: an SFZ's
// release notes and keyswitches).
track_note_count :: proc(song: ^Song, track: int) -> int {
	t := song.tracks[track]
	count := 0
	for i in t.notes.first ..< base.span_end(t.notes) {
		count += song.notes.kind[i] == .Attack ? 1 : 0
	}
	return count
}

// The notes matching a filter, in time order (indices into song.notes).
notes_from_filter :: proc(song: ^Song, f: Note_Filter, out: ^[dynamic]i32) -> bool {
	m := matcher_from_filter(song, f) or_return
	for i in song.by_time {
		if matches(song, m, i) {
			append(out, i)
		}
	}
	return true
}

// 1 at each matching note, falling by e^(-decay * beats since it):
// beat_clock's pulse, from the notes that are really there (0 before the
// filter's range, the last one in it fading after).
pulse_from_seconds :: proc(song: ^Song, t: f64, f: Note_Filter, decay: f64) -> f64 {
	m, ok := matcher_from_filter(song, f)
	if !ok {
		return 0
	}
	last := -math.INF_F64
	for i in song.by_time {
		if song.notes.time[i] > t {
			break
		}
		if matches(song, m, i) {
			last = song.notes.beat[i]
		}
	}
	if math.is_inf(last) {
		return 0
	}
	return math.exp(-decay * (tempo.beat_from_seconds(&song.tempo, t) - last))
}
