package odawg_analyze

import "core:math"
import "core:math/rand"
import "core:testing"

// Kicks on a 128 BPM grid from 0.31 s with quieter hats between them, over
// low noise: every kick is found within 3 ms, the hats are weaker, and the
// beat comes out at 128 BPM with its first beat on the first kick.
@(test)
test_onsets :: proc(t: ^testing.T) {
	BPM :: 128
	FIRST :: 0.31
	RATE :: 48000
	period := f32(60) / BPM
	n := RATE * 12
	l := make([]f32, n)
	r := make([]f32, n)
	defer delete(l)
	defer delete(r)
	gen := rand.create(7)
	g := rand.default_random_generator(&gen)
	for i in 0 ..< n {
		v := (rand.float32(g) - 0.5) * 0.002
		l[i], r[i] = v, v
	}
	kicks := make([dynamic]f32, context.temp_allocator)
	for beat := f32(FIRST); beat < 11.5; beat += period {
		append(&kicks, beat)
		s0 := int(beat * RATE)
		for k in 0 ..< RATE / 4 {
			tt := f32(k) / RATE
			v := math.sin(2 * math.PI * (50 + 120 * math.exp(-tt * 30)) * tt) * math.exp(-tt * 9) * 0.8
			l[s0 + k] += v
			r[s0 + k] += v
		}
		h0 := int((beat + period / 2) * RATE)
		for k in 0 ..< RATE / 20 {
			v := (rand.float32(g) - 0.5) * 0.25 * math.exp(-f32(k) / RATE * 60)
			l[h0 + k] += v
			r[h0 + k] += v
		}
	}
	o := onsets_from_samples(l, r, RATE)
	defer onsets_destroy(&o)
	for kick in kicks {
		found := false
		for x in o.onsets {
			if abs(x.time - kick) < 0.003 {
				found = true
				testing.expectf(t, x.strength > 0.5, "kick at %.3f: strength %.2f", kick, x.strength)
			}
		}
		testing.expectf(t, found, "no onset within 3 ms of the kick at %.3f", kick)
	}
	testing.expectf(t, abs(o.bpm - BPM) < 0.5, "bpm %.2f", o.bpm)
	testing.expectf(t, abs(o.offset - FIRST) < 0.005, "offset %.3f", o.offset)
}
