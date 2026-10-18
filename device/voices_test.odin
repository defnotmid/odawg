package odawg_device

import dsp "../dsp"
import base "../base"
import "core:fmt"
import "core:math"
import "core:testing"

// The kinds this file's voices are (the Tone classes, the DrumKit and the
// presets).
@(private = "file")
CLASSES :: bit_set[Device_Kind]{.Synth, .Mono_Synth, .FM_Synth, .AM_Synth, .Membrane_Synth, .Metal_Synth, .Noise_Synth, .Pluck_Synth, .Drum_Kit}

@(private = "file")
mine :: proc(kind: Device_Kind) -> bool {
	return kind in CLASSES || DEVICE_TABLE[kind].category == .Preset
}

// A note streamed into a buffer a second longer than its tail, `step`
// samples a call (0: one call for the whole buffer), as the engine plays it:
// from a zeroed state, until the voice says it is done.
@(private = "file")
Rendered :: struct {
	l, r:     []f32,
	tail:     int, // samples
	ended_at: int, // where the call that returned false started (-1: never)
}

@(private = "file")
render :: proc(kind: Device_Kind, n: Note, seed: u64 = 7, p: Maybe(Params) = nil, step := 0) -> Rendered {
	params := p.? or_else params_from_kind(kind)
	tail := int(math.ceil(note_tail(kind, &params, n) * RATE))
	out := Rendered {
		l        = make([]f32, tail + RATE, context.temp_allocator),
		r        = make([]f32, tail + RATE, context.temp_allocator),
		tail     = tail,
		ended_at = -1,
	}
	state := new(Voice_State, context.temp_allocator)
	env: Voice_Env
	size := step > 0 ? step : len(out.l)
	for at := 0; at < len(out.l); at += size {
		end := min(at + size, len(out.l))
		if !DEVICE_TABLE[kind].voice(state, &params, n, seed, i64(at), &env, out.l[at:end], out.r[at:end]) {
			out.ended_at = at
			break
		}
	}
	return out
}

@(private = "file")
kit_params :: proc(kit: Kit) -> Params {
	p := params_from_kind(.Drum_Kit)
	p[.Kit] = f32(kit)
	return p
}

@(private = "file")
peak :: proc(x: []f32) -> f32 {
	p: f32
	for v in x {
		p = max(p, abs(v))
	}
	return p
}

@(private = "file")
rms :: proc(x: []f32) -> f64 {
	s: f64
	for v in x {
		s += f64(v) * f64(v)
	}
	return math.sqrt(s / f64(max(len(x), 1)))
}

@(private = "file")
zero_crossings :: proc(x: []f32) -> int {
	count := 0
	for i in 1 ..< len(x) {
		if (x[i - 1] < 0) != (x[i] < 0) {
			count += 1
		}
	}
	return count
}

@(private = "file")
same :: proc(a, b: []f32) -> bool {
	if len(a) != len(b) {
		return false
	}
	for v, i in a {
		if v != b[i] {
			return false
		}
	}
	return true
}

// Checks one rendered note: finite, audible, no wild level at velocity 1,
// and silent for the second after its tail.
@(private = "file")
expect_sound :: proc(t: ^testing.T, name: string, got: Rendered) {
	finite := true
	for v, i in got.l {
		if math.is_nan(v) || math.is_inf(v) || math.is_nan(got.r[i]) || math.is_inf(got.r[i]) {
			finite = false
		}
	}
	testing.expectf(t, finite, "%s: non-finite samples", name)
	p := max(peak(got.l[:got.tail]), peak(got.r[:got.tail]))
	testing.expectf(t, p > 0.01, "%s: silent (peak %v)", name, p)
	testing.expectf(t, p < 3, "%s: peak %v at velocity 1", name, p)
	testing.expectf(t, max(peak(got.l[got.tail:]), peak(got.r[got.tail:])) == 0, "%s: sounded past its tail", name)
	testing.expectf(t, got.ended_at >= 0 && got.ended_at <= got.tail, "%s: still sounding after its tail (ended at %d, tail %d)", name, got.ended_at, got.tail)
}

// Every instrument and preset of DEVICE_TABLE, at its defaults, with and
// without a pitch, and every pad of every kit, renders finite, non-silent
// sound within note_tail.
@(test)
test_every_voice_renders :: proc(t: ^testing.T) {
	for row, kind in DEVICE_TABLE {
		if !mine(kind) || kind == .Drum_Kit {
			continue
		}
		expect_sound(t, row.name, render(kind, {duration = 0.3, velocity = 1}))
		expect_sound(t, row.name, render(kind, {duration = 0.3, pitch = 64, velocity = 1}))
	}
	for kit in Kit {
		for pad in Pad {
			// every pad the kit has (a row without layers: one it doesn't)
			if pad != .None && KIT_TABLE[kit][pad][0].gain != 0 {
				expect_sound(t, fmt.tprintf("%v %v", kit, pad), render(.Drum_Kit, {duration = 0.1, pad = pad, velocity = 1}, p = kit_params(kit)))
			}
		}
	}
	// Fat oscillators through a steep filter, and every colour of noise.
	fat := params_from_kind(.Mono_Synth)
	fat[.Oscillator_Type] = f32(dsp.Wave.Fat_Sawtooth)
	fat[.Oscillator_Count] = 5
	fat[.Filter_Rolloff] = -48
	expect_sound(t, "fat MonoSynth", render(.Mono_Synth, {duration = 0.2, pitch = 48, velocity = 1}, p = fat))
	for kind in dsp.Noise_Type {
		noise := params_from_kind(.Noise_Synth)
		noise[.Noise_Type] = f32(kind)
		expect_sound(t, "NoiseSynth", render(.Noise_Synth, {duration = 0.2, velocity = 1}, p = noise))
	}
}

// A note sounds the same however it is split into calls: one call, or
// calls of 1, 7, 128 or 800 samples (a 60 fps frame), bit for bit; and it
// never writes past the slice it is given.
@(test)
test_split_invariance :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, name: string, kind: Device_Kind, n: Note, p: Params) {
		whole := render(kind, n, 11, p)
		for step in ([]int{1, 7, 128, 800}) {
			split := render(kind, n, 11, p, step)
			testing.expectf(t, same(whole.l, split.l) && same(whole.r, split.r), "%s: differs split at %d", name, step)
			testing.expectf(t, split.ended_at >= 0 && split.ended_at <= split.tail, "%s: split at %d, ended at %d (tail %d)", name, step, split.ended_at, split.tail)
		}
	}
	for row, kind in DEVICE_TABLE {
		if mine(kind) && kind != .Drum_Kit {
			check(t, row.name, kind, {duration = 0.25, pitch = 62, velocity = 0.9}, params_from_kind(kind))
		}
	}
	for kit in Kit {
		for pad in Pad {
			// every pad the kit has (a row without layers: one it doesn't)
			if pad != .None && KIT_TABLE[kit][pad][0].gain != 0 {
				check(t, fmt.tprintf("%v %v", kit, pad), .Drum_Kit, {duration = 0.1, pad = pad, velocity = 1}, kit_params(kit))
			}
		}
	}
	fat := params_from_kind(.Mono_Synth)
	fat[.Oscillator_Type] = f32(dsp.Wave.Fat_Sawtooth)
	check(t, "fat MonoSynth", .Mono_Synth, {duration = 0.2, pitch = 48, velocity = 1}, fat)

	l := make([]f32, 400, context.temp_allocator)
	r := make([]f32, 400, context.temp_allocator)
	env: Voice_Env
	for _, kind in DEVICE_TABLE {
		if mine(kind) {
			p := kind == .Drum_Kit ? kit_params(.R808) : params_from_kind(kind)
			state := new(Voice_State, context.temp_allocator)
			DEVICE_TABLE[kind].voice(state, &p, {duration = 1, pitch = 60, velocity = 1, pad = .Crash}, 1, 0, &env, l[:100], r[:100])
		}
	}
	testing.expect(t, peak(l[:100]) > 0)
	testing.expect_value(t, peak(l[100:]), 0)
	testing.expect_value(t, peak(r[100:]), 0)
}

// Every pad of every kit plays kinds whose state fits a kit's layer slot.
@(test)
test_kit_layers_fit :: proc(t: ^testing.T) {
	for kit in Kit {
		for pad in Pad {
			for layer in KIT_TABLE[kit][pad] {
				if layer.gain != 0 {
					testing.expectf(t, layer.kind != .Pluck_Synth && layer.kind != .Drum_Kit && mine(layer.kind), "%v %v plays %v", kit, pad, layer.kind)
				}
			}
		}
	}
	testing.expect_value(t, note_pad({pitch = note_from_pad(.Open_Hat)}), Pad.Open_Hat)
	for pad in Pad {
		if pad != .None {
			testing.expect_value(t, note_pad({pitch = note_from_pad(pad)}), pad)
		}
	}
}

// The same seed gives the same samples; another seed changes every voice
// made of noise, and leaves a voice without noise as it was.
@(test)
test_seeded_noise :: proc(t: ^testing.T) {
	noisy := [?]Device_Kind{.Kick, .Hat, .Clap, .Snare, .Riser, .Glitch, .Pad, .Noise_Synth, .Pluck_Synth}
	n := Note {
		duration = 0.3,
		pitch    = 57,
		velocity = 0.8,
	}
	for kind in noisy {
		a, b, c := render(kind, n, 1), render(kind, n, 1), render(kind, n, 2)
		testing.expectf(t, same(a.l, b.l) && same(a.r, b.r), "%v: one seed, two renders", kind)
		testing.expectf(t, !same(a.l, c.l), "%v: another seed, the same noise", kind)
	}
	testing.expect(t, same(render(.FM_Synth, n, 1).l, render(.FM_Synth, n, 2).l))
	drum := Note {
		duration = 0.1,
		pad      = .Snare,
		velocity = 1,
	}
	k := kit_params(.R909)
	testing.expect(t, same(render(.Drum_Kit, drum, 3, k).l, render(.Drum_Kit, drum, 3, k).l))
	testing.expect(t, !same(render(.Drum_Kit, drum, 3, k).l, render(.Drum_Kit, drum, 4, k).l))
}

// The kick is synth.lua's sample for sample (its sine sweeping from 178 Hz
// down to 48 with exp(-30 t), decaying with exp(-7 t), and the click from the
// seed's noise), and its pitch is measurably falling.
@(test)
test_kick_ports_synth_lua :: proc(t: ^testing.T) {
	got := render(.Kick, {velocity = 0.9}, 42)
	testing.expect(t, abs(got.tail - int(0.4 * RATE)) <= 1)
	rng := base.rng_init(42)
	ph, worst := 0.0, 0.0
	for k in 0 ..< int(0.4 * RATE) {
		tk := f64(k) / RATE
		ph += math.TAU * (48 + 130 * math.exp(-tk * 30)) / RATE
		want := (math.sin(ph) * math.exp(-tk * 7) + f64(base.rng_noise(&rng)) * math.exp(-tk * 600) * 0.25) * 0.9
		worst = max(worst, abs(want - f64(got.l[k])))
	}
	testing.expectf(t, worst < 1e-5, "differs from synth.lua's kick by %v", worst)
	testing.expect(t, same(got.l, got.r)) // centred

	// Over 10..50 ms it averages about 104 Hz; over 200..400 ms, 48.
	early := f64(zero_crossings(got.l[int(0.01 * RATE):int(0.05 * RATE)])) / 2 / 0.04
	late := f64(zero_crossings(got.l[int(0.2 * RATE):int(0.4 * RATE)])) / 2 / 0.2
	testing.expectf(t, early > 85 && early < 125, "early pitch %v Hz", early)
	testing.expectf(t, late > 42 && late < 55, "late pitch %v Hz", late)
	// The level falls with exp(-7 t): 0.2 s later is about a quarter.
	ratio := rms(got.l[int(0.3 * RATE):int(0.35 * RATE)]) / rms(got.l[int(0.1 * RATE):int(0.15 * RATE)])
	testing.expectf(t, ratio > 0.15 && ratio < 0.4, "decay ratio %v", ratio)
}

// The other ports keep synth.lua's shapes: the closed hat, open hat and
// crash are one twice high-passed noise at three lengths, panned 0.12 right;
// done is two blips 0.12 s apart, the second a fifth up; velocity is linear.
@(test)
test_preset_ports :: proc(t: ^testing.T) {
	// One hat at three lengths: the closed hat with decay 14 is the open hat's
	// first 45 ms, and the crash with decay 14 is the open hat for 0.22 s.
	open := render(.Open_Hat, {velocity = 1}, 5)
	hat := params_from_kind(.Hat)
	hat[.Decay] = 14
	closed := render(.Hat, {velocity = 1}, 5, hat)
	testing.expect(t, same(closed.l[:closed.tail - 1], open.l[:closed.tail - 1]))
	crash := params_from_kind(.Crash)
	crash[.Decay] = 14
	long := render(.Crash, {velocity = 1}, 5, crash)
	testing.expect(t, same(long.l[:open.tail - 1], open.l[:open.tail - 1]))
	testing.expect(t, abs(peak(open.r) / peak(open.l) - 1.12 / 0.88) < 1e-3)

	done := render(.Done, {velocity = 1})
	gap := int(0.12 * RATE)
	first := f64(zero_crossings(done.l[:int(0.08 * RATE)])) / 2 / 0.08
	second := f64(zero_crossings(done.l[gap:gap + int(0.08 * RATE)])) / 2 / 0.08
	testing.expectf(t, abs(first - 1320) < 60, "first blip %v Hz", first)
	testing.expectf(t, abs(second - 1980) < 60, "second blip %v Hz", second)
	testing.expect_value(t, peak(done.l[int(0.09 * RATE) + 1:gap]), 0)

	quiet := render(.Bass, {duration = 0.3, pitch = 40, velocity = 0.25})
	loud := render(.Bass, {duration = 0.3, pitch = 40, velocity = 1})
	testing.expect(t, abs(peak(loud.l) / peak(quiet.l) - 4) < 1e-3)
}

// Goertzel power at one frequency over a Hann-windowed buffer.
@(private = "file")
power_at :: proc(x: []f32, hz: f64) -> f64 {
	c := 2 * math.cos(math.TAU * hz / RATE)
	s1, s2: f64
	for v, i in x {
		hann := 0.5 - 0.5 * math.cos(math.TAU * f64(i) / f64(len(x) - 1))
		s := f64(v) * hann + c * s1 - s2
		s2, s1 = s1, s
	}
	return s1 * s1 + s2 * s2 - c * s1 * s2
}

// The band-limited saw aliases far less than a naive one: a saw at 2637 Hz
// has no partials below its fundamental, so whatever power sits there is
// aliasing, and the polyBLEP saw has at least 10 dB less of it. The other
// band-limited waves stay in their naive range.
@(test)
test_band_limited_saw :: proc(t: ^testing.T) {
	hz := base.midi_to_hz(100)
	N :: 8192
	inc := make([]f64, N, context.temp_allocator)
	blep := make([]f32, N, context.temp_allocator)
	naive := make([]f32, N, context.temp_allocator)
	for i in 0 ..< N {
		inc[i] = hz / RATE
		naive[i] = dsp.naive_wave(.Sawtooth, math.mod(f64(i) * hz / RATE, 1))
	}
	osc := dsp.Osc {
		wave = .Sawtooth,
	}
	dsp.osc_run(&osc, inc, blep)
	alias_blep, alias_naive: f64
	for f := 100.0; f < hz - 150; f += 23 {
		alias_blep += power_at(blep, f)
		alias_naive += power_at(naive, f)
	}
	db := 10 * math.log10(alias_naive / alias_blep)
	testing.expectf(t, db > 10, "polyBLEP removes only %v dB of aliasing", db)
	ratio := power_at(blep, hz) / power_at(naive, hz)
	testing.expectf(t, ratio > 0.8 && ratio < 1.25, "fundamental ratio %v", ratio)
	for wave in ([]dsp.Wave{.Triangle, .Square, .Pulse}) {
		o := dsp.Osc {
			wave  = wave,
			width = 0.3,
		}
		dsp.osc_run(&o, inc, blep)
		p := peak(blep)
		testing.expectf(t, p > 0.5 && p < 1.5, "%v peaks at %v", wave, p)
	}
}

// The envelope has Tone's shape: a linear attack, an exponential decay that
// lands on the sustain exactly at attack + decay, and a release that reaches
// zero exactly at its end.
@(test)
test_envelope_curves :: proc(t: ^testing.T) {
	p: Params
	p[.Envelope_Attack], p[.Envelope_Decay], p[.Envelope_Sustain], p[.Envelope_Release] = 0.01, 0.2, 0.5, 0.3
	e := adsr_from_params(&p, .Envelope_Attack, .Envelope_Decay, .Envelope_Sustain, .Envelope_Release)
	v := make([]f32, int(0.8 * RATE), context.temp_allocator)
	dsp.adsr_run(&e, v, int(0.4 * RATE))
	testing.expect(t, abs(v[int(0.005 * RATE)] - 0.5) < 0.01) // halfway up the attack
	testing.expect(t, v[int(0.05 * RATE)] < 0.75 && v[int(0.05 * RATE)] > 0.5) // decaying, not linearly
	testing.expect(t, abs(v[int(0.21 * RATE) + 1] - 0.5) < 1e-4)
	testing.expect(t, abs(v[int(0.39 * RATE)] - 0.5) < 1e-6)
	testing.expect(t, v[int(0.45 * RATE)] < 0.5 && v[int(0.45 * RATE)] > 0.05)
	testing.expect(t, v[int(0.69 * RATE)] > 0)
	testing.expect_value(t, v[int(0.7 * RATE) + 1], 0)
	testing.expect(t, e.stage == .Idle)
}

// PluckSynth is in tune: the Karplus-Strong loop, its low-pass included,
// repeats once per period of the note (measured between zero crossings).
@(test)
test_pluck_in_tune :: proc(t: ^testing.T) {
	p := params_from_kind(.Pluck_Synth)
	p[.Resonance] = 0.99
	got := render(.Pluck_Synth, {duration = 1, pitch = 69, velocity = 1}, 3, p)
	first, last := -1.0, -1.0
	count := 0
	for i in int(0.3 * RATE) ..< int(0.8 * RATE) {
		if got.l[i - 1] < 0 && got.l[i] >= 0 {
			x := f64(i - 1) + f64(-got.l[i - 1] / (got.l[i] - got.l[i - 1]))
			if first < 0 {
				first = x
			}
			last = x
			count += 1
		}
	}
	period := (last - first) / f64(max(count - 1, 1))
	testing.expectf(t, abs(period - RATE / 440.0) < 0.1, "period %v samples, want %v", period, RATE / 440.0)
}

// A DrumKit plays its pads: kick and snare differ, the kits differ, a General
// MIDI pitch with no pad picks the pad, a pitch retunes a tom, and the synth
// kit's low tom is synth.lua's tom at 82 Hz at the pad's level.
@(test)
test_drum_kit :: proc(t: ^testing.T) {
	synth := kit_params(.Synth)
	kick := render(.Drum_Kit, {duration = 0.1, pad = .Kick, velocity = 1}, 7, synth)
	testing.expect(t, !same(kick.l, render(.Drum_Kit, {duration = 0.1, pad = .Snare, velocity = 1}, 7, synth).l))
	testing.expect(t, !same(kick.l, render(.Drum_Kit, {duration = 0.1, pad = .Kick, velocity = 1}, 7, kit_params(.R808)).l))
	testing.expect(t, same(kick.l, render(.Drum_Kit, {duration = 0.1, pitch = 36, velocity = 1}, 7, synth).l))

	low := render(.Drum_Kit, {duration = 0.1, pad = .Tom_Low, velocity = 1}, 7, synth)
	high := render(.Drum_Kit, {duration = 0.1, pad = .Tom_Low, pitch = 52, velocity = 1}, 7, synth)
	window := int(0.1 * RATE)
	testing.expect(t, zero_crossings(high.l[window:2 * window]) > zero_crossings(low.l[window:2 * window]) * 3 / 2)
	direct := render(.Tom, {pitch = 40, velocity = 0.75}, base.hash_combine(7, 1)) // the first layer's seed
	testing.expect(t, same(low.l[:direct.tail], direct.l[:direct.tail]))
}
