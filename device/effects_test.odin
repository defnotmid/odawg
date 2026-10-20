package odawg_device

import "core:math"
import "core:mem"
import "core:testing"
import analyze "../analyze"
import base "../base"

// A stereo sine of `peak_db` dBFS at `hz`, `seconds` long.
@(private = "file")
fx_test_sine :: proc(hz, peak_db, seconds: f64) -> (l, r: []f32) {
	n := int(seconds * RATE)
	l = make([]f32, n)
	r = make([]f32, n)
	a := base.db_to_gain(peak_db)
	for i in 0 ..< n {
		l[i] = f32(a * math.sin(math.TAU * hz * f64(i) / RATE))
		r[i] = l[i]
	}
	return
}

// Deterministic white noise at `gain`.
@(private = "file")
fx_test_noise :: proc(seed: u64, n: int, gain: f32) -> (l, r: []f32) {
	l = make([]f32, n)
	r = make([]f32, n)
	rng := base.rng_init(seed)
	for i in 0 ..< n {
		l[i] = gain * base.rng_noise(&rng)
		r[i] = gain * base.rng_noise(&rng)
	}
	return
}

@(private = "file")
fx_test_clone :: proc(x: []f32) -> []f32 {
	y := make([]f32, len(x))
	copy(y, x)
	return y
}

@(private = "file")
fx_test_peak_db :: proc(x: []f32) -> f64 {
	p: f32
	for v in x {
		p = max(p, abs(v))
	}
	return base.gain_to_db(f64(p))
}

@(private = "file")
fx_test_rms_db :: proc(x: []f32) -> f64 {
	sum: f64
	for v in x {
		sum += f64(v) * f64(v)
	}
	return 10 * math.log10(sum / f64(len(x)))
}

@(private = "file")
fx_test_same :: proc(a, b: []f32) -> bool {
	return len(a) == len(b) && mem.compare(mem.slice_to_bytes(a), mem.slice_to_bytes(b)) == 0
}

// Streams a buffer through a fresh instance of `kind`, reset at song sample
// `at`, in blocks of `block` samples (0: one call), as the engine does.
@(private = "file")
fx_test_stream :: proc(kind: Device_Kind, p: ^Params, l, r: []f32, block := 0, at: i64 = 0, key_l: []f32 = nil, key_r: []f32 = nil) {
	row := &DEVICE_TABLE[kind]
	state := make([]u8, row.effect_size(p))
	defer delete(state)
	row.effect_reset(state, p, at)
	scratch := new(Fx_Scratch)
	defer free(scratch)
	step := block > 0 ? block : max(len(l), 1)
	for start := 0; start < len(l); start += step {
		end := min(start + step, len(l))
		kl := key_l != nil ? key_l[start:end] : nil
		kr := key_r != nil ? key_r[start:end] : nil
		row.effect(state, p, l[start:end], r[start:end], kl, kr, scratch)
	}
}

@(private = "file")
fx_test_effect_kinds :: proc() -> (kinds: [dynamic]Device_Kind) {
	for row, kind in DEVICE_TABLE {
		if row.effect != nil {
			append(&kinds, kind)
		}
	}
	return
}

// Every effect row names its procs, and its output doesn't depend on how
// the stream is cut into blocks: one call and blocks of 1, 7, 128 and 800
// samples give the same bits, half wet (the dry mix) and with a sidechain
// key; the samples are finite and of a sane level.
@(test)
test_effects_block_split :: proc(t: ^testing.T) {
	kinds := fx_test_effect_kinds()
	defer delete(kinds)
	n := 3 * RATE / 2
	al, ar := fx_test_noise(5, n, 0.8)
	kl, kr := fx_test_sine(70, -3, 1.5)
	defer delete(al)
	defer delete(ar)
	defer delete(kl)
	defer delete(kr)
	for kind in kinds {
		row := &DEVICE_TABLE[kind]
		testing.expectf(t, row.effect != nil && row.effect_size != nil && row.effect_reset != nil, "%v lacks a proc", kind)
		p := params_from_kind(kind)
		p[.Wet] = 0.6
		keyed := kind == .Compressor || kind == .Gate
		key_l, key_r := keyed ? kl : nil, keyed ? kr : nil
		whole_l, whole_r := fx_test_clone(al), fx_test_clone(ar)
		defer delete(whole_l)
		defer delete(whole_r)
		fx_test_stream(kind, &p, whole_l, whole_r, 0, 0, key_l, key_r)
		ok := true
		for i in 0 ..< n {
			ok &&= !math.is_nan(whole_l[i]) && !math.is_inf(whole_l[i]) && abs(whole_l[i]) < 10 && !math.is_nan(whole_r[i]) && !math.is_inf(whole_r[i]) && abs(whole_r[i]) < 10
		}
		testing.expectf(t, ok, "%v: bad samples", kind)
		for block in ([]int{1, 7, 128, 800}) {
			l, r := fx_test_clone(al), fx_test_clone(ar)
			defer delete(l)
			defer delete(r)
			fx_test_stream(kind, &p, l, r, block, 0, key_l, key_r)
			testing.expectf(t, fx_test_same(l, whole_l) && fx_test_same(r, whole_r), "%v: blocks of %d differ from one call", kind, block)
		}
	}
}

// A reset at song sample K puts what moves in time (LFOs, the reverb's
// drift) where a stream from sample 0 has it: with silence before K, the
// stream from 0 and the stream reset at K give the same bits from K on.
@(test)
test_effects_reset_at :: proc(t: ^testing.T) {
	kinds := fx_test_effect_kinds()
	defer delete(kinds)
	K :: 100_003
	n := 40_000
	al, ar := fx_test_noise(9, n, 0.7)
	defer delete(al)
	defer delete(ar)
	for kind in kinds {
		p := params_from_kind(kind)
		p[.Wet] = 0.8
		from_zero_l := make([]f32, K + n)
		from_zero_r := make([]f32, K + n)
		defer delete(from_zero_l)
		defer delete(from_zero_r)
		copy(from_zero_l[K:], al)
		copy(from_zero_r[K:], ar)
		fx_test_stream(kind, &p, from_zero_l, from_zero_r, 512)
		l, r := fx_test_clone(al), fx_test_clone(ar)
		defer delete(l)
		defer delete(r)
		fx_test_stream(kind, &p, l, r, 512, K)
		testing.expectf(t, fx_test_same(l, from_zero_l[K:]) && fx_test_same(r, from_zero_r[K:]), "%v: reset at %d differs from the stream from 0", kind, K)
	}
}

// The linear effects (filters, EQ, delays, chorus, reverb, modulated or
// not) obey superposition: processing a + b is processing a and b and
// adding, which the engine relies on to sum each part's send through its
// own copy of a return effect.
@(test)
test_linearity :: proc(t: ^testing.T) {
	n := RATE
	al, ar := fx_test_noise(1, n, 0.4)
	bl, br := fx_test_sine(220, -6, 1)
	defer delete(al)
	defer delete(ar)
	defer delete(bl)
	defer delete(br)
	kinds := []Device_Kind{.Filter, .EQ3, .Reverb, .Feedback_Delay, .Ping_Pong_Delay, .Chorus, .Auto_Filter, .Stereo_Widener}
	buf: [6][]f32
	for &b in buf {
		b = make([]f32, n)
	}
	defer for b in buf {
		delete(b)
	}
	for kind in kinds {
		p := params_from_kind(kind)
		p[.Wet] = 0.7
		p[.Low], p[.High] = 4, -6
		p[.Rolloff], p[.Filter_Rolloff] = -24, -24
		p[.Delay_Time] = 0.0123
		p[.Feedback] = 0.6
		for i in 0 ..< n {
			buf[0][i], buf[1][i] = al[i] + bl[i], ar[i] + br[i]
		}
		copy(buf[2], al)
		copy(buf[3], ar)
		copy(buf[4], bl)
		copy(buf[5], br)
		fx_test_stream(kind, &p, buf[0], buf[1], 1000)
		fx_test_stream(kind, &p, buf[2], buf[3], 1000)
		fx_test_stream(kind, &p, buf[4], buf[5], 1000)
		worst: f32
		for i in 0 ..< n {
			worst = max(worst, abs(buf[0][i] - buf[2][i] - buf[4][i]), abs(buf[1][i] - buf[3][i] - buf[5][i]))
		}
		testing.expectf(t, worst < 1e-4, "%v: superposition off by %v", kind, worst)
	}
}

// The Limiter keeps the true peak (not just the sample peak) at its
// threshold on a signal 7 dB over it, with content near Nyquist whose
// inter-sample peaks are above its samples, and doesn't pull it far below;
// at Tone's default the ceiling is -12 dB. Below its threshold it is a
// delay of exactly latency_limiter samples, its dry signal too.
@(test)
test_limiter :: proc(t: ^testing.T) {
	n := 2 * RATE
	l, r := fx_test_noise(7, n, 0.3)
	defer delete(l)
	defer delete(r)
	for i in 0 ..< n {
		// 12 kHz at a 45 degree phase: samples land at 0.707 of the peaks.
		hf := f32(0.9 * math.sin(math.TAU * 12000 * f64(i) / RATE + math.PI / 4))
		lf := f32(0.6 * math.sin(math.TAU * 110 * f64(i) / RATE))
		l[i] += hf + lf
		r[i] += 0.8 * hf - lf
	}
	testing.expectf(t, analyze.true_peak_from_samples(l, r) > 4, "the input's true peak is only %.2f dBTP", analyze.true_peak_from_samples(l, r))
	p := params_from_kind(.Limiter)
	p[.Threshold] = -1
	fx_test_stream(.Limiter, &p, l, r, 333)
	tp := analyze.true_peak_from_samples(l, r)
	testing.expectf(t, tp <= -0.9, "true peak %.3f dBTP over the -1 dB threshold", tp)
	testing.expectf(t, tp > -2, "true peak %.3f dBTP: limited too far", tp)
	d := params_from_kind(.Limiter)
	fx_test_stream(.Limiter, &d, l, r, 4096)
	testing.expectf(t, analyze.true_peak_from_samples(l, r) <= -11.9, "default: %.3f dBTP", analyze.true_peak_from_samples(l, r))

	latency := DEVICE_TABLE[.Limiter].effect_latency(&d)
	testing.expect_value(t, latency, 247)
	ql, qr := fx_test_sine(440, -20, 0.5)
	defer delete(ql)
	defer delete(qr)
	ol, or := fx_test_clone(ql), fx_test_clone(qr)
	defer delete(ol)
	defer delete(or)
	half := params_from_kind(.Limiter)
	half[.Wet] = 0.5
	fx_test_stream(.Limiter, &half, ol, or, 100)
	worst: f32
	for i in 0 ..< len(ql) {
		want := i >= latency ? ql[i - latency] * f32(2 * math.cos(math.PI / 4)) : 0
		worst = max(worst, abs(ol[i] - want))
	}
	testing.expectf(t, worst < 1e-5, "below threshold the limiter isn't a %d-sample delay (off by %v)", latency, worst)
}

// Distortion's causal oversampling delays it by latency_distortion: a quiet
// sine (where Tone's curve is nearly a gain of 4.78) comes out that gain
// times the input that many samples back.
@(test)
test_distortion_latency :: proc(t: ^testing.T) {
	p := params_from_kind(.Distortion)
	latency := DEVICE_TABLE[.Distortion].effect_latency(&p)
	testing.expect_value(t, latency, 31)
	l, r := fx_test_sine(300, -80, 0.5)
	defer delete(l)
	defer delete(r)
	out_l, out_r := fx_test_clone(l), fx_test_clone(r)
	defer delete(out_l)
	defer delete(out_r)
	fx_test_stream(.Distortion, &p, out_l, out_r, 64)
	gain := f32((3 + 40) * 20 * math.PI / 180 / math.PI)
	worst, peak: f32
	for i in latency ..< len(l) {
		worst = max(worst, abs(out_l[i] - gain * l[i - latency]))
		peak = max(peak, abs(out_l[i]))
	}
	testing.expectf(t, worst < 0.005 * peak, "not a %d-sample delay of the input: off by %v of %v", latency, worst, peak)
}

// The Reverb's tail falls about 60 dB over .Decay seconds (measured on its
// energy envelope from -5 to -35 dB, as T30), its output is finite, by the
// end of its tail it is at least 50 dB down, and its sides are
// decorrelated.
@(test)
test_reverb_decay :: proc(t: ^testing.T) {
	for decay in ([]f32{0.8, 2.5}) {
		p := params_from_kind(.Reverb)
		p[.Decay] = decay
		tail := effect_tail(.Reverb, &p)
		n := int((tail + 0.5) * RATE)
		l := make([]f32, n)
		r := make([]f32, n)
		defer delete(l)
		defer delete(r)
		l[0], r[0] = 1, 1
		fx_test_stream(.Reverb, &p, l, r, 480)
		WIN :: RATE / 100
		env := make([]f64, n / WIN)
		defer delete(env)
		finite := true
		top := -math.INF_F64
		top_at := 0
		for &e, w in env {
			sum: f64
			for i in w * WIN ..< (w + 1) * WIN {
				sum += f64(l[i]) * f64(l[i]) + f64(r[i]) * f64(r[i])
				finite &&= !math.is_nan(l[i]) && !math.is_inf(l[i]) && !math.is_nan(r[i]) && !math.is_inf(r[i])
			}
			e = 10 * math.log10(max(sum, 1e-30))
			if e > top {
				top, top_at = e, w
			}
		}
		testing.expectf(t, finite, "decay %v: non-finite output", decay)
		at_5, at_35 := -1, -1
		for w in top_at ..< len(env) {
			if at_5 < 0 && env[w] < top - 5 {
				at_5 = w
			}
			if at_35 < 0 && env[w] < top - 35 {
				at_35 = w
			}
		}
		testing.expectf(t, at_5 >= 0 && at_35 > at_5, "decay %v: the tail never fell 35 dB", decay)
		if at_35 > at_5 {
			t30 := 2 * f64(at_35 - at_5) / 100
			testing.expectf(t, t30 > 0.7 * f64(decay) && t30 < 1.3 * f64(decay), "decay %v: measured RT60 %.2f s", decay, t30)
		}
		end := int(tail * 100)
		testing.expectf(t, env[end] < top - 50, "decay %v: only %.1f dB down at the tail's end", decay, top - env[end])
		dot, ll, rr: f64
		for i in 0 ..< n {
			dot += f64(l[i]) * f64(r[i])
			ll += f64(l[i]) * f64(l[i])
			rr += f64(r[i]) * f64(r[i])
		}
		testing.expectf(t, abs(dot) / math.sqrt(ll * rr) < 0.3, "decay %v: left and right correlate %.2f", decay, dot / math.sqrt(ll * rr))
	}
}

// Above threshold the Compressor's output rises 1/ratio dB per dB (hard
// knee: a -6 dBFS sine at threshold -24, ratio 4 comes out at -19.5);
// below threshold it leaves the signal alone; a sidechain key ducks a quiet
// signal it would otherwise pass; a Gate closes on what's under its
// threshold.
@(test)
test_dynamics_levels :: proc(t: ^testing.T) {
	p := params_from_kind(.Compressor)
	p[.Threshold], p[.Ratio], p[.Knee], p[.Attack], p[.Release] = -24, 4, 0, 0.002, 0.1
	{
		l, r := fx_test_sine(1000, -6, 1)
		defer delete(l)
		defer delete(r)
		fx_test_stream(.Compressor, &p, l, r, 512)
		got := fx_test_peak_db(l[RATE / 2:])
		testing.expectf(t, abs(got - -19.5) < 0.3, "-6 dBFS in: %.2f dB out, want -19.5", got)
	}
	{
		l, r := fx_test_sine(1000, -30, 1)
		defer delete(l)
		defer delete(r)
		fx_test_stream(.Compressor, &p, l, r, 512)
		got := fx_test_peak_db(l[RATE / 2:])
		testing.expectf(t, abs(got - -30) < 0.05, "-30 dBFS in: %.2f dB out", got)
	}
	{
		l, r := fx_test_sine(200, -30, 1)
		kl, kr := fx_test_sine(60, -6, 1)
		defer delete(l)
		defer delete(r)
		defer delete(kl)
		defer delete(kr)
		fx_test_stream(.Compressor, &p, l, r, 512, 0, kl, kr)
		got := fx_test_peak_db(l[RATE / 2:])
		testing.expectf(t, abs(got - -43.5) < 1, "keyed: %.2f dB out, want -43.5 (13.5 dB ducked)", got)
	}
	{
		l, r := fx_test_sine(440, -50, 0.5)
		defer delete(l)
		defer delete(r)
		g := params_from_kind(.Gate)
		fx_test_stream(.Gate, &g, l, r, 512)
		testing.expectf(t, fx_test_peak_db(l[RATE / 4:]) < -100, "the gate let %.1f dB through", fx_test_peak_db(l[RATE / 4:]))
	}
}

// EQ3 at 0 dB is flat across the bands and its crossovers (it only shifts
// phase), and a band's gain lands in it; Tone's default Filter (lowpass at
// 350 Hz, q 1 read in dB as Web Audio does) peaks 1 dB at its cutoff and
// falls about 12 dB an octave above it.
@(test)
test_filter_responses :: proc(t: ^testing.T) {
	Case :: struct {
		kind:     Device_Kind,
		low, mid: f32,
		hz:       f64,
		want:     f64,
	}
	cases := []Case {
		{.EQ3, 0, 0, 60, 0},
		{.EQ3, 0, 0, 400, 0},
		{.EQ3, 0, 0, 2500, 0},
		{.EQ3, 0, 0, 9000, 0},
		{.EQ3, -12, 0, 60, -12},
		{.EQ3, 0, 6, 1000, 6},
		{.Filter, 0, 0, 350, 1},
		{.Filter, 0, 0, 50, 0},
	}
	for c in cases {
		l, r := fx_test_sine(c.hz, -6, 1)
		defer delete(l)
		defer delete(r)
		p := params_from_kind(c.kind)
		p[.Low], p[.Mid] = c.low, c.mid
		fx_test_stream(c.kind, &p, l, r, 512)
		got := fx_test_rms_db(l[RATE / 2:]) - (-6 - 3.0103)
		testing.expectf(t, abs(got - c.want) < 0.3, "%v: %.2f dB at %v Hz, want %v", c, got, c.hz, c.want)
	}
	l, r := fx_test_sine(700, -6, 1)
	defer delete(l)
	defer delete(r)
	p := params_from_kind(.Filter)
	fx_test_stream(.Filter, &p, l, r, 512)
	got := fx_test_rms_db(l[RATE / 2:]) - (-6 - 3.0103)
	testing.expectf(t, got < -8 && got > -14, "an octave above the cutoff: %.2f dB", got)
}

// The tails: a reverb's is its pre-delay and decay, a delay's lasts until
// its echoes are 60 dB down, the limiter and filters add none.
@(test)
test_effect_tails :: proc(t: ^testing.T) {
	p := params_from_kind(.Reverb)
	testing.expect_value(t, f32(effect_tail(.Reverb, &p)), f32(1.51))
	d := params_from_kind(.Feedback_Delay)
	tail := effect_tail(.Feedback_Delay, &d)
	echoes := math.ln(f64(1e-3)) / math.ln(f64(0.125))
	testing.expectf(t, tail >= 0.25 * (echoes + 1) && tail < 60, "delay tail %v", tail)
	l := params_from_kind(.Limiter)
	testing.expect_value(t, effect_tail(.Limiter, &l), 0)
	f := params_from_kind(.Filter)
	testing.expect_value(t, effect_tail(.Filter, &f), 0)
}
