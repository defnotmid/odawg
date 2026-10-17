// theory: notes, chords and keys as Tone and lead sheets write them.
package odawg_theory

import "core:strconv"
import "core:strings"

// Notes, chords and keys as Tone and lead sheets write them: "C4" is MIDI 60
// (scientific pitch), "F#3", "Bb2"; chords "Am7", "Fmaj7", "C/G", "Dsus4",
// "G6"; keys "A minor", "D dorian", "C" (major). A chord progression is a
// chord per bar ("Am7 F C G"), "." holding the one before.

// Semitones of a note letter above C.
@(private = "file")
LETTER := [7]int{9, 11, 0, 2, 4, 5, 7} // A B C D E F G

// A pitch class from "C", "F#", "Bb", "Ebb" (0..11) and how many bytes it
// took.
pitch_class_from_string :: proc(s: string) -> (pc: int, n: int, ok: bool) {
	if len(s) == 0 {
		return
	}
	c := s[0] | 0x20 // lower case
	if c < 'a' || c > 'g' {
		return
	}
	pc = LETTER[c - 'a']
	n = 1
	for n < len(s) && (s[n] == '#' || s[n] == 'b') {
		pc += s[n] == '#' ? 1 : -1
		n += 1
	}
	return (pc % 12 + 12) % 12, n, true
}

// A MIDI note from "C4" (60), "F#3", "Bb-1", or a number string ("57").
pitch_from_string :: proc(s: string) -> (midi: f32, ok: bool) {
	t := strings.trim_space(s)
	if v, is_number := strconv.parse_f64(t); is_number {
		return f32(v), true
	}
	pc, n := pitch_class_from_string(t) or_return
	octave := strconv.parse_int(t[n:]) or_return
	return f32((octave + 1) * 12 + pc), true
}

// The name of a MIDI note ("A2"), sharps for black keys.
string_from_pitch :: proc(midi: f32, allocator := context.temp_allocator) -> string {
	NAMES := [12]string{"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}
	m := int(midi + 0.5)
	return strings.concatenate({NAMES[(m % 12 + 12) % 12], strconv.write_int(make([]u8, 8, context.temp_allocator), i64(m / 12 - 1), 10)}, allocator)
}

// ---- chords ----------------------------------------------------------------------

// A chord: its root, its tones as semitones above the root (the first is
// 0), and a bass when it is an inversion or a slash chord.
Chord :: struct {
	root:      int, // pitch class
	intervals: [6]i8,
	count:     int,
	bass:      int, // pitch class; -1: the root
}

// Lead-sheet qualities, longest first so "maj7" wins over "m".
@(private = "file")
Quality :: struct {
	suffix:    string,
	intervals: []i8,
}

QUALITIES := []Quality {
	{"maj13", {0, 4, 7, 11, 14, 21}},
	{"maj9", {0, 4, 7, 11, 14}},
	{"maj7", {0, 4, 7, 11}},
	{"mmaj7", {0, 3, 7, 11}},
	{"m7b5", {0, 3, 6, 10}},
	{"madd9", {0, 3, 7, 14}},
	{"add9", {0, 4, 7, 14}},
	{"sus2", {0, 2, 7}},
	{"sus4", {0, 5, 7}},
	{"dim7", {0, 3, 6, 9}},
	{"aug", {0, 4, 8}},
	{"dim", {0, 3, 6}},
	{"m11", {0, 3, 7, 10, 14, 17}},
	{"m13", {0, 3, 7, 10, 14, 21}},
	{"m9", {0, 3, 7, 10, 14}},
	{"m7", {0, 3, 7, 10}},
	{"m6", {0, 3, 7, 9}},
	{"13", {0, 4, 7, 10, 14, 21}},
	{"11", {0, 4, 7, 10, 14, 17}},
	{"9", {0, 4, 7, 10, 14}},
	{"7", {0, 4, 7, 10}},
	{"6", {0, 4, 7, 9}},
	{"5", {0, 7}},
	{"m", {0, 3, 7}},
	{"", {0, 4, 7}},
}

chord_from_string :: proc(s: string) -> (c: Chord, ok: bool) {
	t := strings.trim_space(s)
	slash := strings.index_byte(t, '/')
	body := slash >= 0 ? t[:slash] : t
	pc, n := pitch_class_from_string(body) or_return
	c.root, c.bass = pc, -1
	rest := body[n:]
	if rest == "M7" || rest == "Maj7" || rest == "Δ" {
		rest = "maj7"
	}
	if rest == "min" || rest == "-" {
		rest = "m"
	}
	if strings.has_prefix(rest, "min") {
		rest = strings.concatenate({"m", rest[3:]}, context.temp_allocator)
	}
	for q in QUALITIES {
		if rest == q.suffix {
			for iv, i in q.intervals {
				c.intervals[i] = iv
			}
			c.count = len(q.intervals)
			break
		}
	}
	if c.count == 0 {
		return {}, false
	}
	if slash >= 0 {
		bass, _ := pitch_class_from_string(t[slash + 1:]) or_return
		c.bass = bass
	}
	return c, true
}

// The chord's tones as MIDI notes in close position from the root in
// `octave` (C4 = octave 4), its slash bass below them.
pitches_from_chord :: proc(c: Chord, octave: int, out: ^[dynamic]f32) {
	base := (octave + 1) * 12 + c.root
	if c.bass >= 0 {
		b := (octave + 1) * 12 + c.bass
		for b >= base {
			b -= 12
		}
		append(out, f32(b))
	}
	for i in 0 ..< c.count {
		append(out, f32(base + int(c.intervals[i])))
	}
}

// Moves `notes` (a chord's tones) to the inversion nearest `previous`, so a
// progression's voices move by small steps (voice leading).
voice_lead :: proc(notes: []f32, previous: []f32) {
	if len(previous) == 0 || len(notes) == 0 {
		return
	}
	center: f32
	for p in previous {
		center += p
	}
	center /= f32(len(previous))
	for &n in notes {
		for n - center > 6 {
			n -= 12
		}
		for center - n > 6 {
			n += 12
		}
	}
	// keep them sorted, as close position wants
	for i in 1 ..< len(notes) {
		for j := i; j > 0 && notes[j] < notes[j - 1]; j -= 1 {
			notes[j], notes[j - 1] = notes[j - 1], notes[j]
		}
	}
}

// ---- keys ------------------------------------------------------------------------

Key :: struct {
	tonic: int, // pitch class
	scale: [7]i8, // semitones above the tonic
}

@(private = "file")
Mode :: struct {
	name:  string,
	scale: [7]i8,
}

@(private = "file")
MODES := []Mode {
	{"major", {0, 2, 4, 5, 7, 9, 11}},
	{"ionian", {0, 2, 4, 5, 7, 9, 11}},
	{"minor", {0, 2, 3, 5, 7, 8, 10}},
	{"aeolian", {0, 2, 3, 5, 7, 8, 10}},
	{"dorian", {0, 2, 3, 5, 7, 9, 10}},
	{"phrygian", {0, 1, 3, 5, 7, 8, 10}},
	{"lydian", {0, 2, 4, 6, 7, 9, 11}},
	{"mixolydian", {0, 2, 4, 5, 7, 9, 10}},
	{"locrian", {0, 1, 3, 5, 6, 8, 10}},
	{"harmonic_minor", {0, 2, 3, 5, 7, 8, 11}},
}

// "A minor", "D dorian", "C", "F# major", "Am".
key_from_string :: proc(s: string) -> (k: Key, ok: bool) {
	t := strings.trim_space(s)
	pc, n := pitch_class_from_string(t) or_return
	k.tonic = pc
	mode := strings.to_lower(strings.trim_space(t[n:]), context.temp_allocator)
	if mode == "" {
		mode = "major"
	}
	if mode == "m" {
		mode = "minor"
	}
	mode, _ = strings.replace_all(mode, " ", "_", context.temp_allocator)
	for m in MODES {
		if m.name == mode {
			k.scale = m.scale
			return k, true
		}
	}
	return {}, false
}

// The MIDI note of scale degree `degree` (1-based; 8 is the octave)
// counted up the key's scale from `root_pc` in `octave`. When root_pc is not
// in the scale (a borrowed chord), the chord's own tones answer 3, 5 and 7
// and the major or minor scale on its root the rest.
pitch_from_degree :: proc(k: Key, c: Chord, degree: int, octave: int) -> f32 {
	d := degree - 1
	octaves := d >= 0 ? d / 7 : (d - 6) / 7
	step := d - octaves * 7
	base := (octave + 1 + octaves) * 12 + c.root
	// the chord's own third, fifth and seventh first: they define it
	if step == 2 || step == 4 || step == 6 {
		WANT := [7]i8{0, 0, 3, 0, 7, 0, 10}
		want := WANT[step]
		for i in 0 ..< c.count {
			iv := c.intervals[i] % 12
			if abs(int(iv) - int(want)) <= 1 && iv != 0 {
				return f32(base + int(iv))
			}
		}
	}
	idx := -1
	for s, i in k.scale {
		if (k.tonic + int(s)) % 12 == c.root {
			idx = i
		}
	}
	if idx < 0 {
		minor := c.count >= 2 && c.intervals[1] == 3
		scale := minor ? [7]i8{0, 2, 3, 5, 7, 8, 10} : [7]i8{0, 2, 4, 5, 7, 9, 11}
		return f32(base + int(scale[step]))
	}
	j := idx + step
	up := int(k.scale[j % 7]) + (j / 7) * 12 - int(k.scale[idx])
	return f32(base + up)
}

// A progression: a chord per bar ("Am7 Fmaj7 C G", "|" ignored, "." holds
// the bar before), cycling over the section.
progression_from_string :: proc(s: string, out: ^[dynamic]Chord) -> bool {
	fields := strings.fields(s, context.temp_allocator)
	for f in fields {
		if f == "|" {
			continue
		}
		if f == "." || f == "-" {
			if len(out) == 0 {
				return false
			}
			append(out, out[len(out) - 1])
			continue
		}
		c := chord_from_string(f) or_return
		append(out, c)
	}
	return len(out) > 0
}

// The key's tonic triad (minor when its third is).
tonic_chord :: proc(k: Key) -> Chord {
	return {root = k.tonic, intervals = {0, k.scale[2] == 3 ? 3 : 4, 7, 0, 0, 0}, count = 3, bass = -1}
}

// A chord's lead-sheet name ("Am7", "F/C").
string_from_chord :: proc(c: Chord, allocator := context.temp_allocator) -> string {
	NAMES := [12]string{"C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"}
	suffix := "?"
	for q in QUALITIES {
		if len(q.intervals) != c.count {
			continue
		}
		same := true
		for iv, i in q.intervals {
			if c.intervals[i] != iv {
				same = false
			}
		}
		if same {
			suffix = q.suffix
			break
		}
	}
	bass := c.bass >= 0 ? strings.concatenate({"/", NAMES[c.bass]}, context.temp_allocator) : ""
	return strings.concatenate({NAMES[c.root], suffix, bass}, allocator)
}
