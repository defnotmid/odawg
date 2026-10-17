// tempo: musical time. Tone's lengths ("8n.", "2m", "2:1:0"), positions in a
// song ("drop@1m") and ranges ("drop..outro"), and the tempo map that turns
// beats into seconds. A bare number is always seconds.
package odawg_tempo

import "core:math"
import "core:strconv"
import "core:strings"

// A length: beats (quarter notes) or seconds.
Length :: struct {
	value:      f64,
	in_seconds: bool,
}

// Parses a Tone length. A bar ("1m", and the first field of "2:1:0") is
// `beats_per_bar` quarters; "1n" is always four.
length_from_string :: proc(text: string, beats_per_bar: int) -> (l: Length, ok: bool) {
	s := strings.trim_space(text)
	if s == "" {
		return {}, false
	}
	sign := 1.0
	if s[0] == '-' || s[0] == '+' {
		sign = s[0] == '-' ? -1 : 1
		s = s[1:]
	}
	if strings.has_suffix(s, "s") && !strings.has_suffix(s, "ms") {
		v := strconv.parse_f64(s[:len(s) - 1]) or_return
		return {sign * v, true}, true
	}
	if strings.has_suffix(s, "ms") {
		v := strconv.parse_f64(s[:len(s) - 2]) or_return
		return {sign * v / 1000, true}, true
	}
	if strings.count(s, ":") > 0 {
		parts := strings.split(s, ":", context.temp_allocator)
		if len(parts) > 3 {
			return {}, false
		}
		bars := strconv.parse_f64(parts[0]) or_return
		quarters := len(parts) > 1 ? (strconv.parse_f64(parts[1]) or_return) : 0
		sixteenths := len(parts) > 2 ? (strconv.parse_f64(parts[2]) or_return) : 0
		return {sign * (bars * f64(beats_per_bar) + quarters + sixteenths / 4), false}, true
	}
	unit := s[len(s) - 1]
	dotted := false
	if unit == '.' {
		dotted = true
		s = s[:len(s) - 1]
		unit = s[len(s) - 1] if len(s) > 0 else 0
	}
	if unit != 'n' && unit != 't' && unit != 'm' {
		v := strconv.parse_f64(s) or_return // a number in a string: seconds, as in Tone
		return {sign * v, true}, true
	}
	n := strconv.parse_f64(s[:len(s) - 1]) or_return
	beats: f64
	switch unit {
	case 'm':
		beats = n * f64(beats_per_bar)
	case 'n':
		if n <= 0 {
			return {}, false
		}
		beats = 4 / n
	case 't':
		if n <= 0 {
			return {}, false
		}
		beats = 4 / n * 2 / 3
	}
	if dotted {
		beats *= 1.5
	}
	return {sign * beats, false}, true
}

// A position: an anchor (a section or marker name, "end", or "" for the
// song's start) and an offset from it.
Position :: struct {
	anchor: string,
	offset: Length,
}

position_from_string :: proc(text: string, beats_per_bar: int) -> (p: Position, ok: bool) {
	s := strings.trim_space(text)
	if s == "" {
		return {}, false
	}
	if at := strings.index_byte(s, '@'); at >= 0 {
		off := length_from_string(s[at + 1:], beats_per_bar) or_return
		return {s[:at], off}, true
	}
	// "2:0:0", "12.5s", "4m" from the start; otherwise a name.
	if l, is_length := length_from_string(s, beats_per_bar); is_length {
		return {"", l}, true
	}
	if !is_name(s) {
		return {}, false
	}
	return {s, {}}, true
}

// A range of the song: from `from` to `to`; a bare section name is that
// section, an open end is the end of the section the other end names (or
// of the song).
Range :: struct {
	from, to:         Position,
	open_from, open_to: bool,
	whole_section:    bool, // "drop": from its start to its end
}

range_from_string :: proc(text: string, beats_per_bar: int) -> (r: Range, ok: bool) {
	s := strings.trim_space(text)
	if dots := strings.index(s, ".."); dots >= 0 {
		a, b := strings.trim_space(s[:dots]), strings.trim_space(s[dots + 2:])
		if a == "" {
			r.open_from = true
		} else {
			r.from = position_from_string(a, beats_per_bar) or_return
		}
		if b == "" {
			r.open_to = true
		} else {
			r.to = position_from_string(b, beats_per_bar) or_return
		}
		return r, !(r.open_from && r.open_to)
	}
	r.from = position_from_string(s, beats_per_bar) or_return
	r.to = r.from
	r.whole_section = r.from.offset == {} && r.from.anchor != ""
	if !r.whole_section {
		r.open_to = true // "drop@4m": from there to the end of drop
	}
	return r, true
}

is_name :: proc(s: string) -> bool {
	if s == "" {
		return false
	}
	for c, i in s {
		alpha := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
		if !(alpha || (i > 0 && ((c >= '0' && c <= '9') || c == '-' || c == '.'))) {
			return false
		}
	}
	return true
}

// ---- the tempo map -----------------------------------------------------------------

// A stretch of the tempo map: `beats` long from `beat` (at `seconds`), the
// tempo moving linearly in beats from bpm0 to bpm1 (equal for a steady
// tempo). Over a ramp seconds = 60 n / (b1 - b0) * ln(b1 / b0), the model of
// onimite's examples/common/tempo.lua.
Tempo_Segment :: struct {
	beat, seconds: f64,
	beats:         f64,
	bpm0, bpm1:    f64,
}

Tempo_Map :: struct {
	segments: [dynamic]Tempo_Segment,
}

// Seconds that `beats` last when the tempo ramps from bpm0 to bpm1.
seconds_from_ramp :: proc "contextless" (beats, bpm0, bpm1: f64) -> f64 {
	if math.abs(bpm1 - bpm0) < 1e-9 {
		return 60 * beats / bpm0
	}
	return 60 * beats / (bpm1 - bpm0) * math.ln(bpm1 / bpm0)
}

tempo_push :: proc(m: ^Tempo_Map, beats, bpm0, bpm1: f64) {
	beat, secs: f64
	if n := len(m.segments); n > 0 {
		last := m.segments[n - 1]
		beat, secs = last.beat + last.beats, last.seconds + seconds_from_ramp(last.beats, last.bpm0, last.bpm1)
	}
	append(&m.segments, Tempo_Segment{beat, secs, beats, bpm0, bpm1})
}

@(private = "file")
segment_from_beat :: proc(m: ^Tempo_Map, beat: f64) -> Tempo_Segment {
	#reverse for g in m.segments {
		if beat >= g.beat {
			return g
		}
	}
	return m.segments[0] if len(m.segments) > 0 else {0, 0, 0, 120, 120}
}

@(private = "file")
segment_from_seconds :: proc(m: ^Tempo_Map, t: f64) -> Tempo_Segment {
	#reverse for g in m.segments {
		if t >= g.seconds {
			return g
		}
	}
	return m.segments[0] if len(m.segments) > 0 else {0, 0, 0, 120, 120}
}

// Seconds at a beat (beats past the end keep the last tempo).
seconds_from_beat :: proc(m: ^Tempo_Map, beat: f64) -> f64 {
	g := segment_from_beat(m, beat)
	d := beat - g.beat
	if math.abs(g.bpm1 - g.bpm0) < 1e-9 || d > g.beats {
		if d > g.beats { 	// past a ramp's end: the end tempo
			return g.seconds + seconds_from_ramp(g.beats, g.bpm0, g.bpm1) + (d - g.beats) * 60 / g.bpm1
		}
		return g.seconds + d * 60 / g.bpm0
	}
	bpm := g.bpm0 + (g.bpm1 - g.bpm0) * d / g.beats
	return g.seconds + 60 * g.beats / (g.bpm1 - g.bpm0) * math.ln(bpm / g.bpm0)
}

// The (fractional) beat at seconds.
beat_from_seconds :: proc(m: ^Tempo_Map, t: f64) -> f64 {
	g := segment_from_seconds(m, t)
	d := t - g.seconds
	if math.abs(g.bpm1 - g.bpm0) < 1e-9 {
		return g.beat + d * g.bpm0 / 60
	}
	length := seconds_from_ramp(g.beats, g.bpm0, g.bpm1)
	if d > length {
		return g.beat + g.beats + (d - length) * g.bpm1 / 60
	}
	bpm := g.bpm0 * math.exp(d * (g.bpm1 - g.bpm0) / (60 * g.beats))
	return g.beat + g.beats * (bpm - g.bpm0) / (g.bpm1 - g.bpm0)
}

// The tempo at a beat.
bpm_from_beat :: proc(m: ^Tempo_Map, beat: f64) -> f64 {
	g := segment_from_beat(m, beat)
	if math.abs(g.bpm1 - g.bpm0) < 1e-9 {
		return g.bpm0
	}
	return g.bpm0 + (g.bpm1 - g.bpm0) * clamp((beat - g.beat) / g.beats, 0, 1)
}
