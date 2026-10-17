package odawg_analyze

import "core:math"

// Spectra and levels of a moment of a stereo buffer, for pictures that
// follow the sound: the magnitude spectrum of a window of the mono mix
// (fframes' `visualize_audio_frame`), and the energy of a window (its RMS,
// peak and three bands). Ported from onimite's spectrum.odin. Each is
// computed from the samples alone, so any moment can be asked in any order.

// How a spectrum's window is shaped, as rows.
Window :: enum u8 {
	None,
	Hann,
	Hamming,
}

WINDOW_TABLE := [Window]proc(k, n: int) -> f32 {
	.None    = proc(k, n: int) -> f32 {return 1},
	.Hann    = proc(k, n: int) -> f32 {return 0.5 * (1 - math.cos(2 * math.PI * f32(k) / f32(n)))},
	.Hamming = proc(k, n: int) -> f32 {return 0.54 - 0.46 * math.cos(2 * math.PI * f32(k) / f32(n - 1))},
}

// The largest spectrum: 2048 samples, 1024 magnitudes.
SPECTRUM_MAX :: 2048

// The magnitudes of the `2 * len(out)` samples from `at` of the mono mix
// `0.707 * (L + R)`, windowed; silence when they run outside the buffer.
// `2 * len(out)` is a power of two up to SPECTRUM_MAX.
spectrum_from_samples :: proc(l, r: []f32, at: int, window: Window, out: []f32) {
	n := 2 * len(out)
	re_buf, im_buf: [SPECTRUM_MAX]f32
	re, im := re_buf[:n], im_buf[:n]
	if at >= 0 && at + n <= min(len(l), len(r)) {
		w := WINDOW_TABLE[window]
		for k in 0 ..< n {
			re[k] = (l[at + k] + r[at + k]) * 0.70710678 * w(k, n)
		}
	}
	fft(re, im)
	for k in 0 ..< n / 2 {
		out[k] = math.sqrt(re[k] * re[k] + im[k] * im[k])
	}
}

// How loud a window of the sound is, each 0..1: the RMS (doubled) and peak
// of the mono mix `0.5 * (L + R)` over its samples, and the energy below
// 375 Hz, to 2.8 kHz and above (a 512-sample Hann spectrum at 48 kHz).
Energy :: struct {
	rms, peak, low, mid, high: f32,
}

// The energy of the `n` samples from `at` (those inside the buffer).
energy_from_samples :: proc(l, r: []f32, at, n: int) -> (e: Energy) {
	end := min(at + n, len(l), len(r))
	if at < 0 || at >= end {
		return
	}
	sum_sq, peak: f32
	for k in at ..< end {
		s := (l[k] + r[k]) * 0.5
		sum_sq += s * s
		peak = max(peak, abs(s))
	}
	e.rms = clamp(math.sqrt(sum_sq / f32(end - at)) * 2, 0, 1)
	e.peak = clamp(peak, 0, 1)
	N :: 512
	bins: [N / 2]f32
	spectrum_from_samples(l, r, at, .Hann, bins[:])
	band :: proc(b: []f32, lo, hi: int, scale: f32) -> f32 {
		sum: f32
		for v in b[lo:hi] {
			sum += v
		}
		return clamp(sum / f32(max(hi - lo, 1)) / scale, 0, 1)
	}
	e.low = band(bins[:], 1, 4, 32)
	e.mid = band(bins[:], 4, 30, 12)
	e.high = band(bins[:], 30, 140, 4)
	return
}

// In-place iterative radix-2 FFT (len a power of two).
fft :: proc(re, im: []f32) {
	n := len(re)
	j := 0
	for i in 1 ..< n {
		bit := n >> 1
		for j & bit != 0 {
			j ~= bit
			bit >>= 1
		}
		j |= bit
		if i < j {
			re[i], re[j] = re[j], re[i]
			im[i], im[j] = im[j], im[i]
		}
	}
	for size := 2; size <= n; size <<= 1 {
		ang := -2 * math.PI / f64(size)
		wr, wi := math.cos(ang), math.sin(ang)
		for start := 0; start < n; start += size {
			cr, ci: f64 = 1, 0
			for k in 0 ..< size / 2 {
				a := start + k
				b := a + size / 2
				tr := f32(cr) * re[b] - f32(ci) * im[b]
				ti := f32(cr) * im[b] + f32(ci) * re[b]
				re[b] = re[a] - tr
				im[b] = im[a] - ti
				re[a] += tr
				im[a] += ti
				cr, ci = cr * wr - ci * wi, cr * wi + ci * wr
			}
		}
	}
}
