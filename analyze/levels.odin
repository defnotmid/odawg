package odawg_analyze

import "core:math"

// Where a stereo buffer clips and where it is silent (onimite's `audio
// analyze`, ported).

// Samples at or past full scale, each channel's counted.
clipped_from_samples :: proc(l, r: []f32) -> (n: int) {
	for v in l {
		n += int(abs(v) >= 1)
	}
	for v in r {
		n += int(abs(v) >= 1)
	}
	return
}

// The silent spans, in seconds: 50 ms windows whose mean square (both
// channels) is under `threshold_db` dBFS, merged, those `min_seconds` long
// or longer.
silences_from_samples :: proc(l, r: []f32, rate: int, threshold_db := -60.0, min_seconds := 0.5, allocator := context.allocator) -> [dynamic][2]f64 {
	out := make([dynamic][2]f64, allocator)
	n := min(len(l), len(r))
	win := max(rate / 20, 1)
	threshold := math.pow(10, threshold_db / 10)
	run := -1
	windows := n / win
	for w in 0 ..= windows {
		quiet := false
		if w < windows {
			sum: f64
			for i in w * win ..< (w + 1) * win {
				sum += f64(l[i]) * f64(l[i]) + f64(r[i]) * f64(r[i])
			}
			quiet = sum / f64(2 * win) < threshold
		}
		if quiet && run < 0 {
			run = w
		} else if !quiet && run >= 0 {
			a, b := f64(run * win) / f64(rate), f64(w * win) / f64(rate)
			if b - a >= min_seconds {
				append(&out, [2]f64{a, b})
			}
			run = -1
		}
	}
	return out
}
