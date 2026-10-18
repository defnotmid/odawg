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
