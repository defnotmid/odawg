package odawg_theory

import "core:testing"

// Notes, chords and keys read as lead sheets write them.
@(test)
test_names :: proc(t: ^testing.T) {
	n, ok := pitch_from_string("C4")
	testing.expect(t, ok && n == 60)
	n, _ = pitch_from_string("F#3")
	testing.expect_value(t, n, 54)
	n, _ = pitch_from_string("Bb-1")
	testing.expect_value(t, n, 10)
	c, chord_ok := chord_from_string("Am7")
	testing.expect(t, chord_ok && c.root == 9 && c.count == 4 && c.intervals[1] == 3 && c.intervals[3] == 10)
	c, _ = chord_from_string("Fmaj7/C")
	testing.expect(t, c.root == 5 && c.bass == 0 && c.intervals[3] == 11)
	testing.expect_value(t, string_from_chord(c), "Fmaj7/C")
	_, bad := chord_from_string("Hm7")
	testing.expect(t, !bad)
	k, key_ok := key_from_string("A minor")
	testing.expect(t, key_ok && k.tonic == 9 && k.scale[2] == 3)
}

// Degrees follow the chord: in A minor over F, 1 is F, 3 is A, 5 is C, 8 is
// the octave; over a borrowed E major the 3 is its own G#.
@(test)
test_degrees :: proc(t: ^testing.T) {
	k, _ := key_from_string("A minor")
	f, _ := chord_from_string("F")
	testing.expect_value(t, pitch_from_degree(k, f, 1, 3), 53)
	testing.expect_value(t, pitch_from_degree(k, f, 3, 3), 57)
	testing.expect_value(t, pitch_from_degree(k, f, 5, 3), 60)
	testing.expect_value(t, pitch_from_degree(k, f, 8, 3), 65)
	e, _ := chord_from_string("E")
	testing.expect_value(t, pitch_from_degree(k, e, 3, 3), 56)
}

// Steps within a key: up and down its scale across octaves, a note outside
// it keeping its offset.
@(test)
test_key_steps :: proc(t: ^testing.T) {
	c, _ := key_from_string("C major")
	testing.expect_value(t, key_step(c, 60, 1), 62) // C4 -> D4
	testing.expect_value(t, key_step(c, 64, 1), 65) // E4 -> F4
	testing.expect_value(t, key_step(c, 71, 1), 72) // B4 -> C5
	testing.expect_value(t, key_step(c, 60, -1), 59) // C4 -> B3
	testing.expect_value(t, key_step(c, 60, 7), 72)
	testing.expect_value(t, key_step(c, 61, 1), 63) // C#4 -> D#4
	d, _ := key_from_string("D dorian")
	testing.expect_value(t, key_step(d, 62, 5), 71) // D4 -> B4, the raised sixth
}
