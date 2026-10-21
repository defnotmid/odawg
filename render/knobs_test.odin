package odawg_render

import "core:math"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import analyze "../analyze"
import base "../base"
import song "../song"
import spec "../spec"

// A hit's level (dB, RMS over the render) and brightness (spectral
// centroid, Hz, of the summed 512-bin spectra).
@(private = "file")
hit_measure :: proc(out: Output) -> (db, centroid: f32) {
	sum_sq: f64
	for v, i in out.left {
		x := f64(v + out.right[i]) * 0.5
		sum_sq += x * x
	}
	db = f32(10 * math.log10(max(sum_sq / f64(max(out.frames, 1)), 1e-20)))
	bins, total: [256]f32
	for at := 0; at + 512 <= out.frames; at += 512 {
		analyze.spectrum_from_samples(out.left, out.right, at, .Hann, bins[:])
		for b, k in bins {
			total[k] += b * b
		}
	}
	num, den: f32
	for p, k in total {
		num += p * f32(k) * RATE / 512
		den += p
	}
	centroid = den > 0 ? num / den : 0
	return
}

// v0.0.7's DrumMachine, a hit of every pad without knobs and with the
// styles' (booty_house: the 808 at decay 0.9, tone 0.6, and as the sub at
// decay 0.7; chicago_house: the 909 at tone 0.55): its level (dB) and
// brightness (centroid, Hz), hit_measure of v0.0.7's own render.
@(private = "file")
Knob_Ref :: struct {
	machine, pad:          string,
	db0, centroid0:        f32, // without knobs
	db, centroid:          f32, // with them
}

@(private = "file")
KNOB_REFS := []Knob_Ref {
	{"808", "kick", -19.29, 40, -19.74, 40},
	{"808", "snare", -30.06, 5704, -30.20, 6399},
	{"808", "clap", -36.73, 2026, -35.75, 2269},
	{"808", "rim", -37.98, 671, -38.76, 687},
	{"808", "hat", -43.92, 8361, -45.36, 9358},
	{"808", "open_hat", -38.49, 8030, -39.94, 8939},
	{"808", "crash", -34.93, 5353, -35.75, 5972},
	{"808", "ride", -36.92, 6105, -37.74, 6851},
	{"808", "tom_low", -27.62, 78, -28.08, 79},
	{"808", "tom_mid", -27.49, 142, -27.94, 144},
	{"808", "tom_high", -27.11, 198, -27.57, 199},
	{"808", "shaker", -42.46, 9193, -42.09, 9949},
	{"808", "cowbell", -37.66, 927, -39.09, 1015},
	{"808", "conga_low", -29.59, 191, -30.05, 191},
	{"808", "conga_mid", -29.46, 284, -29.91, 284},
	{"808", "conga_high", -29.54, 382, -29.99, 383},
	{"808", "clave", -38.58, 2495, -39.03, 2495},
	{"808", "maracas", -44.56, 15112, -44.53, 15551},
	{"909", "kick", -18.73, 46, -18.73, 46},
	{"909", "snare", -26.64, 8945, -26.43, 9270},
	{"909", "clap", -36.75, 2722, -36.05, 2860},
	{"909", "rim", -39.26, 960, -39.46, 1016},
	{"909", "hat", -45.37, 11901, -45.32, 12690},
	{"909", "open_hat", -38.76, 12372, -38.66, 12859},
	{"909", "crash", -32.70, 12204, -32.57, 12604},
	{"909", "ride", -35.66, 6044, -35.90, 6548},
	{"909", "tom_low", -25.18, 103, -25.18, 103},
	{"909", "tom_mid", -25.05, 169, -25.05, 169},
	{"909", "tom_high", -24.66, 227, -24.66, 228},
	{"909", "shaker", -42.46, 9193, -41.92, 9560},
	{"909", "cowbell", -37.66, 927, -38.12, 967},
	{"909", "conga_low", -29.59, 191, -29.59, 191},
	{"909", "conga_mid", -29.46, 284, -29.46, 284},
	{"909", "conga_high", -29.54, 382, -29.54, 382},
	{"909", "clave", -38.58, 2495, -38.58, 2495},
	{"909", "maracas", -44.56, 15112, -44.25, 15325},
	{"808_bass", "A1", -15.04, 41, -15.68, 42},
}

@(private = "file")
knob_hit :: proc(t: ^testing.T, ref: Knob_Ref, knobs: bool) -> (db, centroid: f32) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	part: string
	switch ref.machine {
	case "808":
		part = strings.concatenate({`instrument: { name: "machines/808.json"`, knobs ? `, decay: 0.9, tone: 0.6` : "", ` }, play: [ { name: "a", steps: { `, ref.pad, `: "x..." } } ]`})
	case "909":
		part = strings.concatenate({`instrument: { name: "machines/909.json"`, knobs ? `, tone: 0.55` : "", ` }, play: [ { name: "a", steps: { `, ref.pad, `: "x..." } } ]`})
	case:
		part = strings.concatenate({`octave: 1, instrument: { name: "instruments/808_bass.json"`, knobs ? `, decay: 0.7` : "", ` }, play: [ { name: "a", notes: "A1 . . ." } ]`})
	}
	text := strings.concatenate({`{ bpm: 120, gain_db: 0, seed: 1, sections: [ { name: "a", duration: "1m" } ], parts: { d: { gain_db: 0, `, part, ` } } }`})
	sp := new(spec.Spec)
	findings := make(base.Findings)
	testing.expect(t, spec.spec_from_json(text, sp, &findings))
	add_examples(sp, &findings)
	s := new(song.Song)
	testing.expect(t, song.song_from_spec(sp, s))
	for f in s.findings {
		testing.expectf(t, f.severity != .Error, "%s %s: %s", ref.machine, ref.pad, f.message)
	}
	out := output_from_song(s, {})
	return hit_measure(out)
}

// The example machines' knobs do what v0.0.7's DrumMachine's did: on
// every pad, the knobs the styles set move its level as they did there
// (within 0.3 dB) and its brightness (within 3%). Each pad without knobs
// is within the machines' parity of v0.0.7's (1 dB, 12%: the pads are
// written out from the circuits, not the same code).
@(test)
test_machine_knobs :: proc(t: ^testing.T) {
	for ref in KNOB_REFS {
		db0, c0 := knob_hit(t, ref, false)
		db, c := knob_hit(t, ref, true)
		testing.expectf(t, abs((db - db0) - (ref.db - ref.db0)) <= 0.3, "%s %s: the knobs move it %+.2f dB, v0.0.7's %+.2f", ref.machine, ref.pad, db - db0, ref.db - ref.db0)
		testing.expectf(t, abs((c / c0) / (ref.centroid / ref.centroid0) - 1) <= 0.03, "%s %s: the knobs move its centroid x%.3f, v0.0.7's x%.3f", ref.machine, ref.pad, c / c0, ref.centroid / ref.centroid0)
		testing.expectf(t, abs(db0 - ref.db0) <= 1 && abs(c0 / ref.centroid0 - 1) <= 0.12, "%s %s: %.2f dB, %.0f Hz; v0.0.7 %.2f dB, %.0f Hz", ref.machine, ref.pad, db0, c0, ref.db0, ref.centroid0)
	}
}
