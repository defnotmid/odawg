package odawg_analyze

import "core:math"
import "core:testing"

// A full-scale sine on bin 64 of a 1024-point spectrum peaks there at N/2
// of the 0.707 * (L + R) mix; the Hamming window on a constant puts its sum
// in bin 0; a window past the end is silence. The energy of a loud low
// tone is in its low band.
@(test)
test_spectrum :: proc(t: ^testing.T) {
	n := 48000
	l := make([]f32, n)
	r := make([]f32, n)
	defer delete(l)
	defer delete(r)
	for i in 0 ..< n {
		l[i] = f32(math.sin(2 * math.PI * 64 * f64(i) / 1024))
	}
	out := make([]f32, 512)
	defer delete(out)
	spectrum_from_samples(l, r, 16000, .None, out)
	peak := 0
	for v, i in out {
		if v > out[peak] {peak = i}
	}
	testing.expect_value(t, peak, 64)
	testing.expectf(t, abs(out[64] - 512 * 0.70710678) < 5, "sine bin %v", out[64])
	spectrum_from_samples(l, r, n - 100, .None, out)
	testing.expect_value(t, out[64], 0)
	dc := []f32{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1}
	ham: [8]f32
	spectrum_from_samples(dc, dc, 0, .Hamming, ham[:])
	want: f32
	for k in 0 ..< 16 {
		want += 2 * 0.70710678 * (0.54 - 0.46 * math.cos(2 * math.PI * f32(k) / 15))
	}
	testing.expectf(t, abs(ham[0] - want) < 1e-3 * want, "hamming dc %v, want %v", ham[0], want)
	for i in 0 ..< n {
		l[i] = f32(0.8 * math.sin(2 * math.PI * 100 * f64(i) / 48000))
		r[i] = l[i]
	}
	e := energy_from_samples(l, r, 1000, 1600)
	testing.expectf(t, e.peak > 0.79 && e.rms > 0.99 && e.low > 10 * e.mid, "energy %v", e)
}
