package odawg_analyze

// A loudness meter that takes a stream in pieces of any length: the
// K-weighting filters' states, the mean square of every finished 100 ms step,
// the sample peak, and the true peak (the 4x reconstruction needs the last 16
// samples, kept across pieces). What it measures is what
// loudness_from_samples measures on the whole buffer, to the digit, while it
// holds only the steps' energies (36 000 numbers an hour).

TRUE_PEAK_TAPS :: 8

TRUE_PEAK_KERNEL: [3][2 * TRUE_PEAK_TAPS]f32

@(init)
init_true_peak_kernel :: proc "contextless" () {
	for ph in 0 ..< 3 {
		frac := f64(ph + 1) / 4
		for k in 0 ..< 2 * TRUE_PEAK_TAPS {
			TRUE_PEAK_KERNEL[ph][k] = f32(lanczos(f64(k - TRUE_PEAK_TAPS + 1) - frac, TRUE_PEAK_TAPS))
		}
	}
}

Meter :: struct {
	rate, step:  int,
	shelf, hp:   K_Biquad,
	k:           [2][4]f64, // per channel: the shelf's and the high-pass's states
	acc:         f64, // this step's sum so far
	in_step:     int,
	energy:      [dynamic]f64, // each finished step's mean square
	sample_peak: f32,
	true_peak:   f32,
	history:     [2][4 * TRUE_PEAK_TAPS]f32, // mirrored 16-sample ring buffer per channel
	pushed:      i64, // samples taken
}

meter_init :: proc(m: ^Meter, rate: int, allocator := context.allocator) {
	m^ = {rate = rate, step = rate / 10}
	m.energy = make([dynamic]f64, allocator)
	m.shelf, m.hp = k_coefficients(rate)
}

meter_destroy :: proc(m: ^Meter) {
	delete(m.energy)
	m^ = {}
}

// Takes the next samples of the stream.
meter_push :: proc(m: ^Meter, l, r: []f32) {
	TAPS :: TRUE_PEAK_TAPS
	MASK :: 2 * TAPS - 1
	n := min(len(l), len(r))
	for i in 0 ..< n {
		x := [2]f32{l[i], r[i]}
		g := m.pushed
		pos := int(g) & MASK
		e: f64
		for c in 0 ..< 2 {
			v := x[c]
			m.sample_peak = max(m.sample_peak, abs(v))
			m.true_peak = max(m.true_peak, abs(v))
			// K-weighting: high shelf, then RLB high-pass (direct form II transposed)
			st := &m.k[c]
			fv := f64(v)
			y := m.shelf.b0 * fv + st[0]
			st[0] = m.shelf.b1 * fv - m.shelf.a1 * y + st[1]
			st[1] = m.shelf.b2 * fv - m.shelf.a2 * y
			z := m.hp.b0 * y + st[2]
			st[2] = m.hp.b1 * y - m.hp.a1 * z + st[3]
			st[3] = m.hp.b2 * y - m.hp.a2 * z
			w := f64(f32(z))
			e += w * w
			// true peak: the sample TAPS back is between its 8 before and 8 after
			h := &m.history[c]
			h[pos] = v
			h[pos + 2 * TAPS] = v
			at := g - TAPS // the sample whose in-betweens are now known
			if at >= TAPS - 1 {
				win := h[pos + 1:][:2 * TAPS]
				for ph in 0 ..< 3 {
					sum: f32
					for k in 0 ..< 2 * TAPS {
						sum += win[k] * TRUE_PEAK_KERNEL[ph][k]
					}
					m.true_peak = max(m.true_peak, abs(sum))
				}
			}
		}
		m.acc += e
		m.in_step += 1
		if m.in_step == m.step {
			append(&m.energy, m.acc / f64(m.step))
			m.acc, m.in_step = 0, 0
		}
		m.pushed += 1
	}
}
