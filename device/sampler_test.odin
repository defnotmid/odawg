package odawg_device

import "core:math"
import "core:testing"

// A bank built by hand: one set whose samples are sines (or noise), so a
// test knows what a note must sound like.
@(private = "file")
Test_Bank :: struct {
	bank: Bank,
}

@(private = "file")
add_sine :: proc(b: ^Bank, hz: f64, seconds: f64, amplitude: f32 = 0.5) -> i32 {
	n := int(seconds * RATE)
	frames := make([]f32, 2 * n)
	for i in 0 ..< n {
		v := amplitude * f32(math.sin(2 * math.PI * hz * f64(i) / RATE))
		frames[2 * i], frames[2 * i + 1] = v, v
	}
	append(&b.f32s, frames)
	append(&b.owned, Chunk{.F32, i32(len(b.f32s) - 1)})
	append(&b.samples, Sample{chunk = i32(len(b.f32s) - 1), frames = i64(n), channels = 2, format = .F32})
	return i32(len(b.samples) - 1)
}

@(private = "file")
add_set :: proc(b: ^Bank, name: string, zones: []Zone) -> int {
	first := len(b.zones)
	append(&b.zones, ..zones)
	append(&b.sets, Sample_Set{name = name, zones = {i32(first), i32(len(zones))}})
	return len(b.sets) - 1
}


// Renders a note into a buffer of `total` samples in blocks of `block` (0:
// one call), as the engine does.
@(private = "file")
play :: proc(b: ^Bank, set: int, n: Note, total: int, block := 0, seed: u64 = 1, p: Maybe(Params) = nil) -> (l, r: []f32, calls_alive: bool) {
	params := p.? or_else params_from_kind(.Sampler)
	params[.Sample_Set] = f32(set)
	l = make([]f32, total, context.temp_allocator)
	r = make([]f32, total, context.temp_allocator)
	state := new(Voice_State, context.temp_allocator)
	env := Voice_Env{bank = b}
	step := block > 0 ? block : total
	alive := true
	for at := 0; at < total && alive; at += step {
		end := min(at + step, total)
		alive = voice_sampler(state, &params, n, seed, i64(at), &env, l[at:end], r[at:end])
	}
	return l, r, alive
}

// Frequency from zero crossings (linear interpolation between samples).
@(private = "file")
frequency :: proc(x: []f32) -> f64 {
	first, last := -1.0, -1.0
	count := 0
	for i in 1 ..< len(x) {
		if x[i - 1] < 0 && x[i] >= 0 {
			t := f64(i - 1) + f64(-x[i - 1] / (x[i] - x[i - 1]))
			if first < 0 {
				first = t
			}
			last = t
			count += 1
		}
	}
	return count > 1 ? f64(count - 1) * RATE / (last - first) : 0
}

@(private = "file")
rms :: proc(x: []f32) -> f64 {
	s: f64
	for v in x {
		s += f64(v) * f64(v)
	}
	return math.sqrt(s / f64(max(len(x), 1)))
}

@(test)
test_sampler_zone_selection :: proc(t: ^testing.T) {
	b: Bank
	defer bank_destroy(&b)
	s0 := add_sine(&b, 220, 0.1)
	s1 := add_sine(&b, 220, 0.1)
	s2 := add_sine(&b, 220, 0.1)
	s3 := add_sine(&b, 440, 0.1)
	set := add_set(&b, "test/set", {
		{sample = s0, lo_key = 40, hi_key = 59, root = 57, lo_velocity = 0, hi_velocity = 63, group = 0, sequence = 0, gain = 1},
		{sample = s1, lo_key = 40, hi_key = 59, root = 57, lo_velocity = 0, hi_velocity = 63, group = 0, sequence = 1, gain = 1},
		{sample = s2, lo_key = 40, hi_key = 59, root = 57, lo_velocity = 64, hi_velocity = 127, group = 2, gain = 1},
		{sample = s3, lo_key = 60, hi_key = 80, root = 69, lo_velocity = 0, hi_velocity = 127, group = 3, gain = 1},
	})
	first := b.sets[set].zones.first
	// key and velocity
	testing.expect(t, zone_for(&b, set, 50, 100, 1) == first + 2)
	testing.expect(t, zone_for(&b, set, 70, 10, 1) == first + 3)
	// outside every range: the nearest key, then velocity
	testing.expect(t, zone_for(&b, set, 100, 100, 1) == first + 3)
	testing.expect(t, zone_for(&b, set, 10, 127, 1) == first + 2)
	// the round robin: deterministic by seed, and both of the group play
	seen: [2]int
	for seed in u64(0) ..< 64 {
		z := zone_for(&b, set, 50, 30, seed)
		testing.expect(t, z == first || z == first + 1)
		testing.expect(t, z == zone_for(&b, set, 50, 30, seed))
		seen[z - first] += 1
	}
	testing.expect(t, seen[0] > 10 && seen[1] > 10)
	// nothing to pick
	testing.expect(t, zone_for(&b, 7, 50, 30, 1) == -1)
	testing.expect(t, zone_for(nil, 0, 50, 30, 1) == -1)
}

@(test)
test_sampler_pitch :: proc(t: ^testing.T) {
	b: Bank
	defer bank_destroy(&b)
	s := add_sine(&b, 440, 1)
	set := add_set(&b, "test/sine", {{sample = s, lo_key = 0, hi_key = 127, root = 69, hi_velocity = 127, gain = 1}})
	for key in ([]f32{69, 76, 62, 81, 45}) {
		l, _, _ := play(&b, set, {pitch = key, velocity = 1, duration = 0.5}, RATE / 2)
		want := 440 * math.pow(2, f64(key - 69) / 12)
		got := frequency(l[RATE / 20:RATE * 2 / 5])
		testing.expectf(t, abs(got / want - 1) < 1e-4, "key %v: %v Hz, want %v", key, got, want)
	}
}

// Shifting a high tone up past Nyquist leaves (almost) nothing: the kernel
// is low-passed for the shift, so it doesn't fold back.
@(test)
test_sampler_no_aliasing :: proc(t: ^testing.T) {
	b: Bank
	defer bank_destroy(&b)
	s := add_sine(&b, 15000, 0.5)
	set := add_set(&b, "test/high", {{sample = s, lo_key = 0, hi_key = 127, root = 60, hi_velocity = 127, gain = 1}})
	l, _, _ := play(&b, set, {pitch = 72, velocity = 1, duration = 0.3}, RATE / 4) // 30 kHz: above Nyquist
	testing.expectf(t, rms(l[RATE / 40:]) < 0.5 * 0.7071 * 0.003, "aliased level %v", rms(l[RATE / 40:]))
	// a tone shifted below Nyquist keeps its level
	s2 := add_sine(&b, 5000, 0.5)
	set2 := add_set(&b, "test/mid", {{sample = s2, lo_key = 0, hi_key = 127, root = 60, hi_velocity = 127, gain = 1}})
	l2, _, _ := play(&b, set2, {pitch = 67, velocity = 1, duration = 0.3}, RATE / 4)
	testing.expectf(t, abs(rms(l2[RATE / 40:]) / (0.5 * 0.7071) - 1) < 0.01, "level %v", rms(l2[RATE / 40:]))
}

@(test)
test_sampler_block_split :: proc(t: ^testing.T) {
	b: Bank
	defer bank_destroy(&b)
	s := add_sine(&b, 333, 0.4)
	looped := add_sine(&b, 250, 0.2)
	set := add_set(&b, "test/split", {
		{sample = s, lo_key = 0, hi_key = 63, root = 60, hi_velocity = 127, gain = 0.8, pan = 0.3},
		{sample = looped, lo_key = 64, hi_key = 127, root = 64, hi_velocity = 127, gain = 1, loop_from = 192, loop_to = 192 + 192 * 40},
	})
	p := params_from_kind(.Sampler)
	p[.Attack] = 0.01
	p[.Release] = 0.05
	for n in ([]Note{{pitch = 63.3, velocity = 0.7, duration = 0.2}, {pitch = 70, velocity = 0.9, duration = 0.5}, {pitch = 48, velocity = 0.4, duration = 0.05}}) {
		total := int(note_tail(.Sampler, &p, n) * RATE) + 100
		wl, wr, _ := play(&b, 0, n, total, 0, 9, p)
		for block in ([]int{1, 37, 64, 1000, 4097}) {
			l, r, _ := play(&b, 0, n, total, block, 9, p)
			same := true
			for i in 0 ..< total {
				if l[i] != wl[i] || r[i] != wr[i] {
					same = false
					break
				}
			}
			testing.expectf(t, same, "note %v split in blocks of %d differs", n, block)
		}
	}
	_ = set
}

@(test)
test_sampler_envelope_and_end :: proc(t: ^testing.T) {
	b: Bank
	defer bank_destroy(&b)
	s := add_sine(&b, 200, 0.3)
	looped := add_sine(&b, 200, 0.3)
	set := add_set(&b, "test/env", {
		{sample = s, lo_key = 0, hi_key = 59, root = 60, hi_velocity = 127, gain = 1},
		{sample = looped, lo_key = 60, hi_key = 70, root = 60, hi_velocity = 127, gain = 1, loop_from = 240, loop_to = 240 * 41},
		{sample = s, lo_key = 71, hi_key = 127, root = 71, hi_velocity = 127, gain = 1, one_shot = true},
	})
	p := params_from_kind(.Sampler)
	p[.Release] = 0.1
	// held past its sample's end: an unlooped sample stops with it
	l, _, alive := play(&b, set, {pitch = 59, velocity = 1, duration = 1}, RATE, 512, 1, p)
	testing.expect(t, !alive)
	testing.expect(t, rms(l[RATE / 2:]) == 0)
	// a looped one keeps sounding while the gate is held, then releases
	l2, _, alive2 := play(&b, set, {pitch = 60, velocity = 1, duration = 0.8}, RATE + RATE / 2, 512, 1, p)
	testing.expect(t, rms(l2[RATE * 6 / 10:RATE * 7 / 10]) > 0.3)
	testing.expect(t, rms(l2[RATE:]) == 0)
	testing.expect(t, !alive2)
	// a one-shot ignores the gate: it plays its whole sample
	l3, _, _ := play(&b, set, {pitch = 71, velocity = 1, duration = 0.01}, RATE / 2, 512, 1, p)
	testing.expect(t, rms(l3[RATE / 5:RATE / 4]) > 0.3)
	// velocity scales a layer linearly
	soft, _, _ := play(&b, set, {pitch = 59, velocity = 0.5, duration = 0.2}, RATE / 5)
	loud, _, _ := play(&b, set, {pitch = 59, velocity = 1, duration = 0.2}, RATE / 5)
	testing.expect(t, abs(rms(soft[1000:5000]) / rms(loud[1000:5000]) - 64.0 / 127) < 0.01)
	// no bank, no set: silence, done at once
	l4, _, alive4 := play(nil, 0, {pitch = 60, velocity = 1, duration = 0.2}, 1000)
	testing.expect(t, !alive4 && rms(l4) == 0)
}

@(test)
test_sampler_pads :: proc(t: ^testing.T) {
	b: Bank
	defer bank_destroy(&b)
	kick := add_sine(&b, 60, 0.2)
	snare := add_sine(&b, 300, 0.2)
	set := add_set(&b, "test/kit", {
		{sample = kick, lo_key = 36, hi_key = 36, root = 36, hi_velocity = 127, gain = 1, one_shot = true},
		{sample = snare, lo_key = 38, hi_key = 38, root = 38, hi_velocity = 127, gain = 1, one_shot = true},
	})
	l, _, _ := play(&b, set, {pad = .Snare, velocity = 1, duration = 0.01}, RATE / 10)
	testing.expect(t, abs(frequency(l[100:]) - 300) < 1)
	l2, _, _ := play(&b, set, {pad = .Kick, velocity = 1, duration = 0.01}, RATE / 10)
	testing.expect(t, abs(frequency(l2[100:]) - 60) < 0.5)
	// a pad with a pitch plays the pad's sample at that pitch
	l3, _, _ := play(&b, set, {pad = .Snare, pitch = 50, velocity = 1, duration = 0.01}, RATE / 10)
	testing.expect(t, abs(frequency(l3[100:]) - 600) < 2)
	testing.expect(t, tail_sampler(nil, {pad = .Kick}) == SAMPLER_ONE_SHOT_TAIL)
}

// A sample recorded at 44.1 kHz plays in tune at RATE: its rate is part of
// the step, nothing resampled when it loads.
@(test)
test_sampler_file_rate :: proc(t: ^testing.T) {
	b: Bank
	defer bank_destroy(&b)
	// 441 Hz recorded at 44.1 kHz: 100 frames a cycle there
	n := 44100
	frames := make([]f32, 2 * n)
	for i in 0 ..< n {
		v := 0.5 * f32(math.sin(2 * math.PI * 441 * f64(i) / 44100))
		frames[2 * i], frames[2 * i + 1] = v, v
	}
	append(&b.f32s, frames)
	append(&b.owned, Chunk{.F32, i32(len(b.f32s) - 1)})
	append(&b.samples, Sample{chunk = i32(len(b.f32s) - 1), frames = i64(n), channels = 2, format = .F32, rate = 44100})
	set := add_set(&b, "rate", {{sample = i32(len(b.samples) - 1), lo_key = 0, hi_key = 127, root = 69, hi_velocity = 127, gain = 1}})
	l, _, _ := play(&b, set, {duration = 0.5, pitch = 69, velocity = 1}, RATE / 2)
	hz := frequency(l[2000:])
	testing.expectf(t, abs(hz - 441) < 0.5, "a 44.1 kHz sample at its root plays %f Hz", hz)
	// an octave up is twice that
	l2, _, _ := play(&b, set, {duration = 0.5, pitch = 81, velocity = 1}, RATE / 2)
	hz2 := frequency(l2[2000:])
	testing.expectf(t, abs(hz2 - 882) < 1, "an octave up plays %f Hz", hz2)
}
