package odawg_device

import dsp "../dsp"
import "core:math"
import "core:testing"

// ---- helpers -------------------------------------------------------------------------

// A note played through a voice in blocks of `block` samples (0: one call),
// into a buffer a second longer than its tail; also whether the voice said
// it was done by its tail.
@(private = "file")
play :: proc(kind: Device_Kind, p: ^Params, n: Note, seed: u64 = 11, block := 0) -> (l: []f32, tail: int, done: bool) {
	tail = int(math.ceil(note_tail(kind, p, n) * RATE))
	l = make([]f32, tail + RATE, context.temp_allocator)
	r := make([]f32, tail + RATE, context.temp_allocator)
	s := new(Voice_State, context.temp_allocator)
	step := block > 0 ? block : tail
	more := true
	for at := 0; at < tail; at += step {
		e := min(at + step, tail)
		more = DEVICE_TABLE[kind].voice(s, p, n, seed, i64(at), nil, l[at:e], r[at:e])
	}
	return l, tail, !more
}

// A line of notes through one mono voice (the state kept between notes, `at`
// 0 again at each), each note `starts` samples in, in blocks of `block`.
@(private = "file")
play_line :: proc(p: ^Params, notes: []Note, starts: []int, block := 0, s: ^Voice_State = nil) -> []f32 {
	last := len(notes) - 1
	end := starts[last] + int(math.ceil(note_tail(.Acid_Synth, p, notes[last]) * RATE))
	l := make([]f32, end, context.temp_allocator)
	r := make([]f32, end, context.temp_allocator)
	st := s != nil ? s : new(Voice_State, context.temp_allocator)
	for n, k in notes {
		stop := k < last ? starts[k + 1] : end
		step := block > 0 ? block : stop - starts[k]
		for at := 0; starts[k] + at < stop; at += step {
			a, b := starts[k] + at, min(starts[k] + at + step, stop)
			voice_acid_synth(st, p, n, 5, i64(at), nil, l[a:b], r[a:b])
		}
	}
	return l
}

@(private = "file")
machine_params :: proc(m: Machine) -> Params {
	p := params_from_kind(.Drum_Machine)
	p[.Machine] = f32(m)
	return p
}

@(private = "file")
peak_of :: proc(x: []f32) -> f32 {
	v: f32
	for s in x {
		v = max(v, abs(s))
	}
	return v
}

@(private = "file")
energy :: proc(x: []f32) -> f64 {
	e: f64
	for s in x {
		e += f64(s) * f64(s)
	}
	return e
}

// x through `stages` 12 dB SVFs of a type at a cutoff (a copy).
@(private = "file")
filtered :: proc(x: []f32, type: dsp.Filter_Type, hz: f32, stages := 4) -> []f32 {
	y := make([]f32, len(x), context.temp_allocator)
	copy(y, x)
	c := dsp.svf_coefficients(type, hz, -3, 0)
	for _ in 0 ..< stages {
		st: dsp.Svf_State
		dsp.svf_run(c, &st, y)
	}
	return y
}

// The magnitude of one frequency in x (Goertzel).
@(private = "file")
goertzel :: proc(x: []f32, hz: f64) -> f64 {
	w := math.TAU * hz / RATE
	c := 2 * math.cos(w)
	s1, s2: f64
	for v in x {
		s0 := f64(v) + c * s1 - s2
		s2, s1 = s1, s0
	}
	return math.sqrt(s1 * s1 + s2 * s2 - c * s1 * s2) / f64(len(x))
}

@(private = "file")
crossings :: proc(x: []f32) -> int {
	n := 0
	for i in 1 ..< len(x) {
		if (x[i - 1] < 0) != (x[i] < 0) {
			n += 1
		}
	}
	return n
}

// The first sample after which every 10 ms window is below `db` of the peak.
@(private = "file")
fall_time :: proc(x: []f32, db: f64) -> int {
	w := RATE / 100
	limit := f64(peak_of(x)) * math.pow(10, db / 20)
	last := 0
	for at := 0; at + w <= len(x); at += w {
		if math.sqrt(energy(x[at:at + w]) / f64(w)) >= limit {
			last = at + w
		}
	}
	return last
}

// ---- the drum machines ---------------------------------------------------------------

// Every pad of both machines renders finite and audible (peak above -40 dBFS,
// no louder than 0 dBFS), is quiet by the end of its tail (its last 10 ms at
// least 50 dB under its peak), writes nothing past it, and the voice says it
// is done there.
@(test)
test_machine_pads_render :: proc(t: ^testing.T) {
	for m in Machine {
		p := machine_params(m)
		for pad in Pad {
			if MACHINE_TABLE[m][pad].level == 0 {
				continue // a pad the machine doesn't have (an empty row) is silent
			}
			n := Note{duration = 0.1, velocity = 1, pad = pad}
			l, tail, done := play(.Drum_Machine, &p, n)
			pk := peak_of(l)
			finite := true
			for v in l {
				finite &&= !math.is_nan(v) && !math.is_inf(v)
			}
			end := l[tail - RATE / 100:tail]
			testing.expectf(t, finite, "%v %v: not finite", m, pad)
			testing.expectf(t, pk > 0.01 && pk <= 1, "%v %v: peak %v", m, pad, pk)
			testing.expectf(t, peak_of(end) < pk * 0.0032, "%v %v: still %v at its tail (peak %v)", m, pad, peak_of(end), pk)
			testing.expectf(t, peak_of(l[tail:]) == 0, "%v %v: wrote past its tail", m, pad)
			testing.expectf(t, done, "%v %v: not done at its tail", m, pad)
		}
	}
}

// A pad's samples are the same bit for bit whether it renders in one call or
// in blocks of 1, 7, 128 or 800 samples.
@(test)
test_machine_block_split :: proc(t: ^testing.T) {
	for m in Machine {
		p := machine_params(m)
		p[.Tone] = 0.7
		for pad in Pad {
			n := Note{duration = 0.1, velocity = 0.9, pad = pad}
			whole, tail, _ := play(.Drum_Machine, &p, n, 3)
			for block in ([]int{1, 7, 128, 800}) {
				split, _, _ := play(.Drum_Machine, &p, n, 3, block)
				same := true
				for i in 0 ..< tail {
					same &&= whole[i] == split[i]
				}
				testing.expectf(t, same, "%v %v: blocks of %d differ", m, pad, block)
			}
		}
	}
}

// Hits differ a little (the hardware's drift) from seed to seed, and the
// same seed gives the same hit.
@(test)
test_machine_drift :: proc(t: ^testing.T) {
	p := machine_params(.R808)
	n := Note{duration = 0.1, velocity = 1, pad = .Kick}
	a, tail, _ := play(.Drum_Machine, &p, n, 1)
	b, _, _ := play(.Drum_Machine, &p, n, 2)
	c, _, _ := play(.Drum_Machine, &p, n, 1)
	diff, same: f64
	for i in 0 ..< tail {
		diff += abs(f64(a[i] - b[i]))
		same += abs(f64(a[i] - c[i]))
	}
	testing.expect(t, diff > 0 && same == 0)
	pa, pb := peak_of(a), peak_of(b)
	testing.expectf(t, abs(pa - pb) < 0.1 * pa, "the drift is not subtle: %v vs %v", pa, pb)
}

// The 808 kick's blip settles to its tuning (52 Hz, within the drift), `.Tune`
// moves it by semitones, and `.Decay` stretches its fall: twice the decay,
// about twice as long to fall 40 dB.
@(test)
test_808_kick_pitch_and_decay :: proc(t: ^testing.T) {
	p := machine_params(.R808)
	n := Note{duration = 0.1, velocity = 1, pad = .Kick}
	l, _, _ := play(.Drum_Machine, &p, n)
	window := l[RATE / 8:RATE / 8 + RATE / 4]
	hz := f64(crossings(window)) / 2 / 0.25
	testing.expectf(t, abs(hz - 52) < 52 * 0.04, "settles at %v Hz", hz)
	// the blip: the first half cycle (up from rest, back through zero) is
	// shorter than the settled pitch's
	first := 1
	for first < len(l) && !(l[first - 1] >= 0 && l[first] < 0) {
		first += 1
	}
	half := 0.5 * RATE / hz
	testing.expectf(t, f64(first) < 0.8 * half, "no blip: the first half cycle takes %v samples, the settled one %v", first, half)

	p[.Tune] = 12
	up, _, _ := play(.Drum_Machine, &p, n)
	hz_up := f64(crossings(up[RATE / 8:RATE / 8 + RATE / 4])) / 2 / 0.25
	testing.expectf(t, abs(hz_up / hz - 2) < 0.08, "tune 12: %v Hz from %v", hz_up, hz)

	p[.Tune] = 0
	p[.Decay] = 2
	long, _, _ := play(.Drum_Machine, &p, n)
	t1, t2 := fall_time(l, -40), fall_time(long, -40)
	ratio := f64(t2) / f64(t1)
	testing.expectf(t, ratio > 1.6 && ratio < 2.4, "decay 2 falls in %v x the time", ratio)
}

// The hats and cymbals are bright: their energy above 5 kHz outweighs the
// energy below, on both machines.
@(test)
test_machine_hat_spectrum :: proc(t: ^testing.T) {
	for m in Machine {
		p := machine_params(m)
		for pad in ([]Pad{.Hat, .Open_Hat}) {
			l, tail, _ := play(.Drum_Machine, &p, {duration = 0.1, velocity = 1, pad = pad})
			hi := energy(filtered(l[:tail], .Highpass, 5000))
			lo := energy(filtered(l[:tail], .Lowpass, 5000))
			testing.expectf(t, hi > 2 * lo, "%v %v: above 5 kHz %v, below %v", m, pad, hi, lo)
		}
	}
}

// A pad note's pitch tunes it, and a note without a pad is the kick as an
// 808 bass at its pitch.
@(test)
test_machine_pitched :: proc(t: ^testing.T) {
	p := machine_params(.R808)
	l, _, _ := play(.Drum_Machine, &p, {duration = 0.5, velocity = 1, pitch = 31}) // G1, 49 Hz
	hz := f64(crossings(l[RATE / 5:RATE / 5 + RATE / 4])) / 2 / 0.25
	testing.expectf(t, abs(hz - 49) < 2.5, "the 808 bass at G1 plays %v Hz", hz)
}

// ---- the acid synth ------------------------------------------------------------------

@(private = "file")
acid_params :: proc() -> Params {return params_from_kind(.Acid_Synth)}

// An accented note (velocity 1) peaks higher and is brighter (more of its
// energy above 1 kHz) than the same note unaccented (velocity 0.8).
@(test)
test_acid_accent :: proc(t: ^testing.T) {
	p := acid_params()
	plain := play_line(&p, {{duration = 0.2, pitch = 36, velocity = 0.8}}, {0})
	accent := play_line(&p, {{duration = 0.2, pitch = 36, velocity = 1}}, {0})
	bright :: proc(x: []f32) -> f64 {return energy(filtered(x, .Highpass, 1000)) / energy(x)}
	testing.expectf(t, peak_of(accent) > 1.3 * peak_of(plain), "accent peak %v, plain %v", peak_of(accent), peak_of(plain))
	testing.expectf(t, bright(accent) > bright(plain), "accent brightness %v, plain %v", bright(accent), bright(plain))
	testing.expect(t, peak_of(accent) <= 1)
}

// Successive accents build: the third accent in a row opens the filter
// further than the first (the accent capacitor has not drained).
@(test)
test_acid_accent_builds :: proc(t: ^testing.T) {
	p := acid_params()
	s := new(Voice_State, context.temp_allocator)
	st := (^Acid_State)(s)
	step := RATE / 8
	peaks: [3]f32
	l := make([]f32, step, context.temp_allocator)
	r := make([]f32, step, context.temp_allocator)
	for k in 0 ..< 3 {
		n := Note{duration = 0.06, pitch = 36, velocity = 1}
		for i in 0 ..< step {
			voice_acid_synth(s, &p, n, 5, i64(i), nil, l[i:i + 1], r[i:i + 1])
			peaks[k] = max(peaks[k], st.charge)
		}
	}
	testing.expectf(t, peaks[2] > peaks[0] * 1.1, "accent charge %v", peaks)
}

// A slide (the last gate still open when the next note starts) glides the
// pitch over the portamento and retriggers nothing: the filter envelope and
// the level carry on. With the gate closed, the next note is a new attack.
@(test)
test_acid_slide :: proc(t: ^testing.T) {
	p := acid_params()
	p[.Portamento] = 0.06
	start := RATE / 5
	s := new(Voice_State, context.temp_allocator)
	st := (^Acid_State)(s)
	a := Note{duration = 0.3, pitch = 36, velocity = 0.8} // its gate runs past the next note's start
	b := Note{duration = 0.2, pitch = 48, velocity = 0.8}
	buf := make([]f32, RATE, context.temp_allocator)
	voice_acid_synth(s, &p, a, 5, 0, nil, buf[:start], buf[:start])
	meg, level := st.meg, st.amp * st.hold
	voice_acid_synth(s, &p, b, 5, 0, nil, buf[start:start + 1], buf[start:start + 1])
	testing.expect(t, st.legato)
	testing.expectf(t, st.meg <= meg && st.meg > 0.99 * meg, "the filter envelope jumped: %v to %v", meg, st.meg)
	testing.expectf(t, abs(st.amp * st.hold - level) < 0.01, "the level jumped: %v to %v", level, st.amp * st.hold)
	from, to := math.log2(base_hz(36)), math.log2(base_hz(48))
	voice_acid_synth(s, &p, b, 5, 1, nil, buf[start + 1:start + RATE / 50], buf[start + 1:start + RATE / 50])
	mid := (st.pitch - from) / (to - from)
	testing.expectf(t, mid > 0.1 && mid < 0.9, "20 ms into the slide the pitch is %v of the way", mid)
	voice_acid_synth(s, &p, b, 5, RATE / 50, nil, buf[start + RATE / 50:start + RATE / 4], buf[start + RATE / 50:start + RATE / 4])
	testing.expectf(t, abs(st.pitch - to) < 0.01, "the slide ends at %v, not %v", st.pitch, to)

	// the gate closed before the next note: a new attack
	s2 := new(Voice_State, context.temp_allocator)
	st2 := (^Acid_State)(s2)
	short := a
	short.duration = 0.1
	voice_acid_synth(s2, &p, short, 5, 0, nil, buf[:start], buf[:start])
	voice_acid_synth(s2, &p, b, 5, 0, nil, buf[start:start + 1], buf[start:start + 1])
	testing.expect(t, !st2.legato)
	testing.expectf(t, st2.meg > 0.99, "no new attack: the filter envelope at %v", st2.meg)
	testing.expectf(t, abs(st2.pitch - to) < 1e-9, "a new attack jumps to its pitch")
}

@(private = "file")
base_hz :: proc(midi: f64) -> f64 {return 440 * math.pow(2, (midi - 69) / 12)}

// Resonance raises the peak at the cutoff: with the envelope off and the
// cutoff at 800 Hz, the saw's harmonic there stands further above a low one
// at a high `.Filter_Q` than at a low one.
@(test)
test_acid_resonance :: proc(t: ^testing.T) {
	ratio :: proc(q: f32) -> f64 {
		p := acid_params()
		p[.Filter_Envelope_Octaves] = 0
		p[.Filter_Frequency] = 800
		p[.Filter_Q] = q
		l := play_line(&p, {{duration = 0.5, pitch = 24, velocity = 0.8}}, {0}) // C1, 32.7 Hz
		x := l[RATE / 10:RATE / 10 + RATE / 4]
		f := base_hz(24)
		near := goertzel(x, f * math.round(800 / f))
		low := goertzel(x, f * 6)
		return near / low
	}
	soft, sharp := ratio(1), ratio(9)
	testing.expectf(t, sharp > 3 * soft, "the cutoff's harmonic over a low one: %v at q 9, %v at q 1", sharp, soft)
}

// A line with slides and accents is the same bit for bit in one call per
// note or in blocks of 1, 7, 128 and 800 samples.
@(test)
test_acid_block_split :: proc(t: ^testing.T) {
	p := acid_params()
	p[.Filter_Q] = 9.5
	step := RATE / 8
	notes := []Note {
		{duration = 0.06, pitch = 36, velocity = 0.8},
		{duration = 0.2, pitch = 48, velocity = 1}, // slides into the next
		{duration = 0.06, pitch = 39, velocity = 0.8},
		{duration = 0.06, pitch = 36, velocity = 1},
		{duration = 0.3, pitch = 43, velocity = 0.36},
	}
	starts := []int{0, step, 2 * step, 3 * step, 4 * step}
	whole := play_line(&p, notes, starts)
	for block in ([]int{1, 7, 128, 800}) {
		split := play_line(&p, notes, starts, block)
		same := len(split) == len(whole)
		for i in 0 ..< min(len(split), len(whole)) {
			same &&= whole[i] == split[i]
		}
		testing.expectf(t, same, "blocks of %d differ", block)
	}
	pk := peak_of(whole)
	testing.expectf(t, pk > 0.05 && pk <= 1, "peak %v", pk)
}
