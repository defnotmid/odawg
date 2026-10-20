package odawg_dsp

import "core:testing"

// Tone's envelope: a linear attack, a decay approaching the sustain (not
// linearly, and there exactly at its time), held, then a release from there
// to nothing by its time; the same samples however the run is cut.
@(test)
test_envelope_curves :: proc(t: ^testing.T) {
	envelope :: proc() -> Adsr {return {attack = 0.01, decay = 0.2, sustain = 0.5, release = 0.3, stage = .Attack}}
	whole := make([]f32, int(0.8 * RATE), context.temp_allocator)
	e := envelope()
	adsr_run(&e, whole, int(0.4 * RATE))
	testing.expect(t, abs(whole[int(0.005 * RATE)] - 0.5) < 0.01) // halfway up the attack
	testing.expect(t, whole[int(0.05 * RATE)] < 0.75 && whole[int(0.05 * RATE)] > 0.5) // decaying, not linearly
	testing.expect(t, abs(whole[int(0.21 * RATE) + 1] - 0.5) < 1e-4)
	testing.expect(t, abs(whole[int(0.39 * RATE)] - 0.5) < 1e-6)
	testing.expect(t, whole[int(0.45 * RATE)] < 0.5 && whole[int(0.45 * RATE)] > 0.05)
	testing.expect(t, whole[int(0.69 * RATE)] > 0)
	testing.expect_value(t, whole[int(0.7 * RATE) + 1], 0)
	testing.expect(t, e.stage == .Idle)
	// cut into runs of 1, 7 and 300 samples
	for step in ([]int{1, 7, 300}) {
		cut := make([]f32, len(whole), context.temp_allocator)
		x := envelope()
		for at := 0; at < len(cut); at += step {
			end := min(at + step, len(cut))
			rel := int(0.4 * RATE) - at
			adsr_run(&x, cut[at:end], rel >= 0 && rel < end - at ? rel : -1)
		}
		same := true
		for v, i in whole {
			same &&= v == cut[i]
		}
		testing.expectf(t, same, "cut into runs of %d it differs", step)
	}
}

// adsr_run's spans give the samples of stepping every one (adsr_step), bit
// for bit: every stage, each kind of attack, the gate closing in each stage,
// however the run is cut.
@(test)
test_envelope_spans :: proc(t: ^testing.T) {
	shapes := []Adsr {
		{attack = 0.01, decay = 0.2, sustain = 0.5, release = 0.3},
		{attack = 0.3, decay = 0, sustain = 1, release = 0.05},
		{attack = 1.8, decay = 1, sustain = 0.8, release = 3.5},
		{attack = 0.02, decay = 0.1, sustain = 0.3, release = 0.2, exponential_attack = true},
		{attack = 0.01, decay = 0.05, sustain = 0.2, release = 0.1, delay = 0.03, hold = 0.02, start = 0.25},
		{attack = 0, decay = 0, sustain = 0.7, release = 0},
		{attack = 1 / f32(RATE), decay = 3 / f32(RATE), sustain = 0.4, release = 2 / f32(RATE), hold = 1 / f32(RATE)},
	}
	length := int(1.2 * RATE)
	for shape, k in shapes {
		for gate in ([]int{0, 100, 500, int(0.02 * RATE), int(0.15 * RATE), int(0.6 * RATE), length + 10}) {
			start :: proc(shape: Adsr) -> Adsr {
				e := shape
				e.stage, e.from = e.delay > 0 ? .Delay : .Attack, e.start
				return e
			}
			want := make([]f32, length, context.temp_allocator)
			x := start(shape)
			adsr_begin(&x)
			for i in 0 ..< length {
				if i == gate {
					adsr_release(&x)
				}
				want[i] = adsr_step(&x)
			}
			for step in ([]int{1, 7, 256, 300, length}) {
				got := make([]f32, length, context.temp_allocator)
				e := start(shape)
				for at := 0; at < length; at += step {
					end := min(at + step, length)
					rel := gate - at
					adsr_run(&e, got[at:end], rel >= 0 && rel < end - at ? rel : -1)
				}
				first := -1
				for v, i in want {
					if transmute(u32)v != transmute(u32)got[i] {
						first = i
						break
					}
				}
				testing.expectf(t, first < 0, "shape %d, gate at %d, runs of %d: differs from sample %d", k, gate, step, first)
			}
		}
	}
}
