package odawg_tempo

import "core:math"
import "core:testing"

// Tone's lengths read as quarters (bars by the meter) or seconds.
@(test)
test_lengths :: proc(t: ^testing.T) {
	cases := []struct {
		text:    string,
		bpb:     int,
		value:   f64,
		seconds: bool,
	}{{"4n", 4, 1, false}, {"8n", 4, 0.5, false}, {"8n.", 4, 0.75, false}, {"8t", 4, 1.0 / 3, false}, {"1m", 4, 4, false}, {"2m", 3, 6, false}, {"1:2:2", 4, 6.5, false}, {"0.5s", 4, 0.5, true}, {"250ms", 4, 0.25, true}, {"1.5", 4, 1.5, true}, {"-4n", 4, -1, false}}
	for c in cases {
		l, ok := length_from_string(c.text, c.bpb)
		testing.expectf(t, ok && math.abs(l.value - c.value) < 1e-9 && l.in_seconds == c.seconds, "%s: %v", c.text, l)
	}
	_, ok := length_from_string("drop", 4)
	testing.expect(t, !ok)
}

// The ramp's closed form agrees with integrating the tempo, and seconds and
// beats invert each other across steps and ramps.
@(test)
test_tempo_map :: proc(t: ^testing.T) {
	m: Tempo_Map
	defer delete(m.segments)
	tempo_push(&m, 16, 60, 60)
	tempo_push(&m, 16, 60, 128)
	tempo_push(&m, 8, 128, 128)
	// integrate 60/bpm over the ramp's beats
	sum := 0.0
	N :: 100000
	for i in 0 ..< N {
		b := (f64(i) + 0.5) / N * 16
		sum += 60 / (60 + 68 * b / 16) * 16 / N
	}
	testing.expectf(t, math.abs(seconds_from_ramp(16, 60, 128) - sum) < 1e-6, "ramp %f vs %f", seconds_from_ramp(16, 60, 128), sum)
	for beat in ([]f64{0, 3.5, 16, 20.25, 31.9, 32, 39, 45}) {
		s := seconds_from_beat(&m, beat)
		testing.expectf(t, math.abs(beat_from_seconds(&m, s) - beat) < 1e-9, "beat %f -> %f s -> %f", beat, s, beat_from_seconds(&m, s))
	}
	testing.expect(t, math.abs(bpm_from_beat(&m, 24) - 94) < 1e-9)
}
