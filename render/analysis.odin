package odawg_render

import "core:math"
import "core:slice"
import analyze "../analyze"

// What a song's sound is made of, as rows the tables hold (Table_Kind
// .Bands, .Stereo, .Crest) and an Analyzer streams: every picture of it (a
// spectrogram, a band lane per part, a live display while it plays) is a
// view of these rows, and every summary (odawg analyze's report) is made
// from them.

// The third-octave bands' centres (ISO 266), 20 Hz to 20 kHz.
BAND_HZ := [31]f32{20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000}

// The FFT a bands row reads (170 ms at 48 kHz: 5.86 Hz a bin).
BANDS_FFT :: 8192

// Each band's bins [first, last] of that FFT, made once: every bin from 1
// to BANDS_FFT/2 - 1 belongs to the band whose [centre / 2^(1/6), centre *
// 2^(1/6)) holds its frequency, and a band no bin falls in (the lowest:
// 20 Hz spans 17.8 to 22.4 Hz, between two bins) reads its nearest bin.
// With BAND_HZ, BANDS_FFT and RATE, the whole contract a band row keeps
// (a shader filling rows matches these).
BAND_BINS: [len(BAND_HZ)][2]i32

@(init, private = "file")
band_bins_init :: proc "contextless" () {
	hz_per_bin := f64(RATE) / BANDS_FFT
	for &b in BAND_BINS {
		b = {-1, -2}
	}
	for k in 1 ..< BANDS_FFT / 2 {
		f := f64(k) * hz_per_bin
		for c, i in BAND_HZ {
			lo, hi := f64(c) / math.pow(2, 1.0 / 6), f64(c) * math.pow(2, 1.0 / 6)
			if f >= lo && f < hi {
				if BAND_BINS[i][0] < 0 {
					BAND_BINS[i][0] = i32(k)
				}
				BAND_BINS[i][1] = i32(k)
			}
		}
	}
	for &b, i in BAND_BINS {
		if b[0] < 0 {
			k := i32(clamp(math.round(f64(BAND_HZ[i]) / hz_per_bin), 1, BANDS_FFT / 2 - 1))
			b = {k, k}
		}
	}
}

// The floor every level in dB is held above (silence).
FLOOR_DB :: -120

@(private = "file")
db_from_power :: #force_inline proc "contextless" (p: f64) -> f32 {
	return p > 1e-12 ? f32(max(10 * math.log10(p), FLOOR_DB)) : FLOOR_DB
}

// A row of bands: the mid channel's mean square in each third octave (its
// bins: BAND_BINS), from a Hann-windowed FFT of the window, as dBFS (a
// full-scale sine: -3).
fill_bands :: proc(t: ^Table, row: []f32, l, r: []f32) {
	N :: BANDS_FFT
	re, im: [N]f32
	window_power: f64
	n := min(len(l), len(r), N)
	for k in 0 ..< n {
		w := 0.5 * (1 - math.cos(2 * math.PI * f64(k) / N))
		re[k] = f32(0.5 * (f64(l[k]) + f64(r[k])) * w)
		window_power += w * w
	}
	analyze.fft(re[:], im[:])
	for bins, b in BAND_BINS {
		power: f64
		for k in bins[0] ..= bins[1] {
			power += f64(re[k]) * f64(re[k]) + f64(im[k]) * f64(im[k])
		}
		// one-sided, normalised by the window's power: the band's mean square
		row[b] = db_from_power(2 * power / (N * max(window_power, 1e-12)))
	}
}

// A row of stereo: width as the side's power over the mid's (dB; mono is
// FLOOR_DB, wide is near 0) and the sides' correlation (1 mono, 0
// unrelated, -1 out of phase; 0 when silent).
fill_stereo :: proc(t: ^Table, row: []f32, l, r: []f32) {
	mid, side, ll, rr, lr: f64
	for k in 0 ..< min(len(l), len(r)) {
		a, b := f64(l[k]), f64(r[k])
		m, s := 0.5 * (a + b), 0.5 * (a - b)
		mid += m * m
		side += s * s
		ll += a * a
		rr += b * b
		lr += a * b
	}
	row[0] = mid > 1e-12 ? f32(max(10 * math.log10(max(side, 1e-30) / mid), FLOOR_DB)) : FLOOR_DB
	row[1] = ll > 1e-12 && rr > 1e-12 ? f32(lr / math.sqrt(ll * rr)) : 0
}

// A row of levels: the sample peak and the RMS of both sides, dBFS.
fill_crest :: proc(t: ^Table, row: []f32, l, r: []f32) {
	peak: f32
	power: f64
	n := min(len(l), len(r))
	for k in 0 ..< n {
		peak = max(peak, abs(l[k]), abs(r[k]))
		power += 0.5 * (f64(l[k]) * f64(l[k]) + f64(r[k]) * f64(r[k]))
	}
	row[0] = peak > 0 ? f32(max(20 * math.log10(f64(peak)), FLOOR_DB)) : FLOOR_DB
	row[1] = db_from_power(power / f64(max(n, 1)))
}

// ---- streaming ----------------------------------------------------------------------

// A table's rows made as the sound streams: blocks of any size pushed in
// order, each row made once its window's samples are all in, kept in a ring
// of the last `keep` rows; nothing allocated after analyzer_init. Its rows
// are on the song's clock (step k reads samples [row_start(k), +window)),
// so started anywhere (analyzer_init's `at`) it makes the rows whose windows
// it holds whole: what a table filled from the whole song has there.
Analyzer :: struct {
	table:   Table, // the kind and its step; values: the ring of rows
	window:  int,
	history: [2][]f32, // the last samples pushed, a power of two each
	mask:    i64,
	first:   i64, // the first song sample it has
	pos:     i64, // the song sample the next pushed one is
	next:    int, // the next step to make
	steps:   []int, // per ring slot: the step it holds (-1: none)
	scratch: [2][]f32, // a window, contiguous
}

// `values`: the caller's memory for the ring of rows (keep x width; nil:
// its own), so a view draws them where they land.
analyzer_init :: proc(a: ^Analyzer, kind: Table_Kind, step_num, step_den: int, keep: int, at: i64, size := 0, shape := analyze.Window.None, allocator := context.allocator, values: []f32 = nil) {
	a^ = {}
	a.table = {kind = kind, stem = -1, step_num = max(step_num, 1), step_den = max(step_den, 1), size = size, shape = shape}
	a.table.width = TABLE_KINDS[kind].width(&a.table)
	a.table.rows = max(keep, 1)
	if values != nil && len(values) >= a.table.rows * a.table.width {
		a.table.values, a.table.lent = values[:a.table.rows * a.table.width], true
	} else {
		a.table.values = make([]f32, a.table.rows * a.table.width, allocator)
	}
	a.window = TABLE_KINDS[kind].window(&a.table)
	ring := 1
	for ring < a.window + 1 {
		ring *= 2
	}
	a.mask = i64(ring - 1)
	a.history = {make([]f32, ring, allocator), make([]f32, ring, allocator)}
	a.scratch = {make([]f32, a.window, allocator), make([]f32, a.window, allocator)}
	a.steps = make([]int, a.table.rows, allocator)
	analyzer_seek(a, at)
}

analyzer_destroy :: proc(a: ^Analyzer, allocator := context.allocator) {
	if !a.table.lent {
		delete(a.table.values, allocator)
	}
	delete(a.history[0], allocator)
	delete(a.history[1], allocator)
	delete(a.scratch[0], allocator)
	delete(a.scratch[1], allocator)
	delete(a.steps, allocator)
	a^ = {}
}

// Starts again at song sample `at` (a seek): no rows, nothing held.
analyzer_seek :: proc(a: ^Analyzer, at: i64) {
	a.first, a.pos = at, at
	// the first step whose window starts at or after `at`
	t := &a.table
	a.next = int((at * i64(t.step_den) + i64(t.step_num) - 1) / i64(t.step_num))
	for &s in a.steps {
		s = -1
	}
}

// Takes the next samples of the stream (song samples from a.pos on) and
// makes every row whose window they complete.
analyzer_push :: proc(a: ^Analyzer, l, r: []f32) {
	// in pieces the ring holds beside a window, rows made after each, so no
	// sample a row still needs is written over
	n := min(len(l), len(r))
	piece := int(a.mask + 1) - a.window
	for at := 0; at < n; at += piece {
		m := min(piece, n - at)
		analyzer_take(a, l[at:][:m], r[at:][:m])
	}
}

@(private = "file")
analyzer_take :: proc(a: ^Analyzer, l, r: []f32) {
	t := &a.table
	kind := TABLE_KINDS[t.kind]
	n := len(l)
	for i in 0 ..< n {
		a.history[0][(a.pos + i64(i)) & a.mask] = l[i]
		a.history[1][(a.pos + i64(i)) & a.mask] = r[i]
	}
	a.pos += i64(n)
	for {
		start := i64(row_start(t, a.next))
		if start + i64(a.window) > a.pos {
			break
		}
		for k in 0 ..< a.window {
			a.scratch[0][k] = a.history[0][(start + i64(k)) & a.mask]
			a.scratch[1][k] = a.history[1][(start + i64(k)) & a.mask]
		}
		slot := a.next % t.rows
		kind.fill(t, t.values[slot * t.width:][:t.width], a.scratch[0], a.scratch[1])
		a.steps[slot] = a.next
		a.next += 1
	}
}

// Row `step` while the ring still holds it (nil: not made yet, or gone).
analyzer_row :: proc(a: ^Analyzer, step: int) -> []f32 {
	t := &a.table
	if step < 0 {
		return nil
	}
	slot := step % t.rows
	if a.steps[slot] != step {
		return nil
	}
	return t.values[slot * t.width:][:t.width]
}

// The latest row made (its step; -1: none yet).
analyzer_latest :: proc(a: ^Analyzer) -> (row: []f32, step: int) {
	if a.next == 0 {
		return nil, -1
	}
	step = a.next - 1
	return analyzer_row(a, step), step
}

// ---- summaries ----------------------------------------------------------------------

// A source's sound over a stretch, in onimite's audio analyze terms (its
// JSON field names): loudness and true peak (filled by the caller from a
// meter over the same stretch: analyze.Meter), crest, stereo width and
// correlation, the 31 bands.
Measures :: struct {
	name:            string `json:"name,omitempty"`,
	integrated_lufs: f64 `json:"integrated_lufs"`,
	true_peak_dbtp:  f64 `json:"true_peak_dbtp"`,
	peak_dbfs:       f64 `json:"peak_dbfs"`,
	rms_dbfs:        f64 `json:"rms_dbfs"`,
	crest_db:        f64 `json:"crest_db"`,
	width_db:        f64 `json:"width_db"`,
	correlation:     f64 `json:"correlation"`,
	bands_db:        []f64 `json:"bands_db"`,
}

// Two parts crowding each other in a band over a section.
Masking_Row :: struct {
	section:    string `json:"section"`,
	a:          string `json:"a"`,
	b:          string `json:"b"`,
	band_hz:    f64 `json:"band_hz"`,
	overlap_db: f64 `json:"overlap_db"`,
}

// Two parts within MASK_CLOSE_DB of each other in a band, the quieter
// within MASK_REACH_DB of the mix there, crowd each other.
MASK_CLOSE_DB :: 6
MASK_REACH_DB :: 15

// The measures of steps [steps[0], steps[1]) of a source's tables (all but
// its loudness): the band levels and the RMS averaged as power, the peak
// the highest, the crest their difference, width and correlation averaged
// over the rows that sound (silent rows left out; a step with no row is
// silent).
measures_from_tables :: proc(bands, stereo, crest: ^Table, steps: [2]int, allocator := context.allocator) -> (out: Measures) {
	out.integrated_lufs, out.true_peak_dbtp = FLOOR_DB, FLOOR_DB
	out.bands_db = make([]f64, len(BAND_HZ), allocator)
	band_power: [len(BAND_HZ)]f64
	peak := f64(FLOOR_DB)
	power, side, corr: f64
	n, nb: int
	for k in steps[0] ..< steps[1] {
		if c := table_row(crest, k); c != nil && c[1] > FLOOR_DB + 1 {
			peak = max(peak, f64(c[0]))
			power += math.pow(10, f64(c[1]) / 10)
			if st := table_row(stereo, k); st != nil {
				side += math.pow(10, f64(st[0]) / 10)
				corr += f64(st[1])
			}
			n += 1
		}
		if b := table_row(bands, k); b != nil {
			for v, i in b {
				band_power[i] += math.pow(10, f64(v) / 10)
			}
			nb += 1
		}
	}
	out.peak_dbfs, out.rms_dbfs, out.width_db = FLOOR_DB, FLOOR_DB, FLOOR_DB
	if n > 0 {
		out.peak_dbfs = peak
		out.rms_dbfs = 10 * math.log10(power / f64(n))
		out.crest_db = out.peak_dbfs - out.rms_dbfs
		out.width_db = max(10 * math.log10(max(side / f64(n), 1e-12)), FLOOR_DB)
		out.correlation = corr / f64(n)
	}
	for p, i in band_power {
		out.bands_db[i] = nb > 0 && p > 0 ? max(10 * math.log10(p / f64(nb)), FLOOR_DB) : FLOOR_DB
	}
	return
}

// Where `stems` (named) crowd each other over `section`, against the mix's
// bands there: the `keep` most crowded rows, loudest first.
masking_from :: proc(mix: Measures, stems: []Measures, section: string, keep: int, allocator := context.allocator) -> []Masking_Row {
	rows := make([dynamic]Masking_Row, context.temp_allocator)
	for pa in 0 ..< len(stems) {
		for pb in pa + 1 ..< len(stems) {
			A, B := stems[pa], stems[pb]
			for band in 0 ..< len(BAND_HZ) {
				la, lb, lm := A.bands_db[band], B.bands_db[band], mix.bands_db[band]
				quiet := min(la, lb)
				if abs(la - lb) <= MASK_CLOSE_DB && quiet >= lm - MASK_REACH_DB && quiet > FLOOR_DB + 1 {
					append(&rows, Masking_Row{section, A.name, B.name, f64(BAND_HZ[band]), quiet})
				}
			}
		}
	}
	slice.sort_by(rows[:], proc(a, b: Masking_Row) -> bool {return a.overlap_db > b.overlap_db})
	return slice.clone(rows[:min(len(rows), keep)], allocator)
}
