package odawg_analyze

import "core:math"
import "core:testing"

// A sine of `peak_db` dBFS at `hz`, `seconds` long, in one or both channels.
@(private = "file")
sine :: proc(hz, peak_db, seconds: f64, rate: int, left := true, right := true) -> (l, r: []f32) {
	n := int(seconds * f64(rate))
	l = make([]f32, n)
	r = make([]f32, n)
	a := math.pow(10, peak_db / 20)
	for i in 0 ..< n {
		v := f32(a * math.sin(2 * math.PI * hz * f64(i) / f64(rate)))
		l[i] = left ? v : 0
		r[i] = right ? v : 0
	}
	return
}

// A 997 Hz sine in both channels reads its peak level in LUFS (EBU Tech
// 3341's -23 dBFS case, and -20), one channel at 0 dBFS reads -3.01 LUFS
// (BS.1770's reference), and at 44.1 kHz the derived K-weighting gives the
// same. Sample and true peak read the sine's peak, the momentary curve has
// a value every 100 ms from 0.4 s, and silence reads -inf.
@(test)
test_loudness_reference :: proc(t: ^testing.T) {
	Case :: struct {
		level:       f64,
		left, right: bool,
		rate:        int,
		want:        f64,
	}
	cases := []Case{{-23, true, true, 48000, -23}, {-20, true, true, 48000, -20}, {0, true, false, 48000, -3.01}, {-23, true, true, 44100, -23}}
	for c in cases {
		l, r := sine(997, c.level, 10, c.rate, c.left, c.right)
		defer delete(l)
		defer delete(r)
		m := loudness_from_samples(l, r, c.rate)
		defer loudness_destroy(&m)
		testing.expectf(t, abs(m.integrated - c.want) < 0.05, "%v: integrated %.3f LUFS, want %.2f", c, m.integrated, c.want)
		testing.expectf(t, abs(m.sample_peak - c.level) < 0.01, "%v: sample peak %.3f", c, m.sample_peak)
		testing.expectf(t, abs(m.true_peak - c.level) < 0.05, "%v: true peak %.3f", c, m.true_peak)
		testing.expectf(t, len(m.momentary) == 97, "%v: %d momentary values, want 97", c, len(m.momentary))
		testing.expectf(t, abs(f64(m.momentary[50]) - c.want) < 0.05, "%v: momentary %.3f", c, m.momentary[50])
		testing.expectf(t, m.range < 0.1, "%v: a steady sine has range %.2f LU", c, m.range)
	}
	silent := make([]f32, 48000)
	defer delete(silent)
	m := loudness_from_samples(silent, silent, 48000)
	defer loudness_destroy(&m)
	testing.expect(t, math.is_inf(m.integrated, -1))
}

// EBU Tech 3342's first case: 20 s of a 1 kHz sine at -20 LUFS then 20 s at
// -30 has a loudness range of 10 LU.
@(test)
test_loudness_range :: proc(t: ^testing.T) {
	al, ar := sine(1000, -20, 20, 48000)
	bl, br := sine(1000, -30, 20, 48000)
	defer delete(al)
	defer delete(ar)
	defer delete(bl)
	defer delete(br)
	l := make([]f32, 2 * len(al))
	r := make([]f32, 2 * len(al))
	defer delete(l)
	defer delete(r)
	copy(l, al)
	copy(l[len(al):], bl)
	copy(r, ar)
	copy(r[len(ar):], br)
	m := loudness_from_samples(l, r, 48000)
	defer loudness_destroy(&m)
	testing.expectf(t, abs(m.range - 10) < 1, "range %.2f LU, want 10", m.range)
}

// True peak finds the peaks between samples: a 12 kHz sine sampled 45
// degrees off its peaks reads 3 dB above its sample peak.
@(test)
test_true_peak_between_samples :: proc(t: ^testing.T) {
	n := 48000
	l := make([]f32, n)
	defer delete(l)
	for i in 0 ..< n {
		l[i] = f32(0.5 * math.sin(2 * math.PI * 12000 * f64(i) / 48000 + math.PI / 4))
	}
	m := loudness_from_samples(l, l, 48000)
	defer loudness_destroy(&m)
	testing.expectf(t, abs(m.sample_peak - (-9.03)) < 0.05, "sample peak %.3f", m.sample_peak)
	testing.expectf(t, abs(true_peak_from_samples(l, l) - (-6.02)) < 0.1, "true peak %.3f", true_peak_from_samples(l, l))
}

// A meter fed a stream in uneven pieces measures what the whole buffer
// measures, to the digit: the stream and the export report one loudness.
@(test)
test_meter_in_pieces :: proc(t: ^testing.T) {
	n := 48000 * 7
	l := make([]f32, n)
	r := make([]f32, n)
	defer delete(l)
	defer delete(r)
	for i in 0 ..< n {
		x := f64(i) / 48000
		l[i] = f32(0.3 * math.sin(2 * math.PI * 440 * x) * (0.5 + 0.5 * math.sin(x)))
		r[i] = f32(0.25 * math.sin(2 * math.PI * 997 * x + 0.3))
	}
	whole := loudness_from_samples(l, r, 48000)
	defer loudness_destroy(&whole)
	m: Meter
	meter_init(&m, 48000)
	defer meter_destroy(&m)
	PIECES := [5]int{1, 7, 800, 4093, 333}
	for at, k := 0, 0; at < n; k += 1 {
		piece := min(PIECES[k % 5], n - at)
		meter_push(&m, l[at:][:piece], r[at:][:piece])
		at += piece
	}
	pieces := loudness_from_meter(&m)
	defer loudness_destroy(&pieces)
	testing.expect_value(t, pieces.integrated, whole.integrated)
	testing.expect_value(t, pieces.range, whole.range)
	testing.expect_value(t, pieces.true_peak, whole.true_peak)
	testing.expect_value(t, pieces.sample_peak, whole.sample_peak)
}
