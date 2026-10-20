package odawg_spec

import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import base "../base"
import device "../device"

// An SFZ instrument compiled at its CCs' values, written out: each layer's
// conditions, gain and program (its nodes, their values and modulators, its
// tables), then the findings.
@(private = "file")
sfz_compiled :: proc(text: string) -> string {
	s: Sfz
	sfz_read(&s, "t.sfz", text, nil)
	findings := make(base.Findings)
	desc := sfz_program_desc(&s, 0, s.cc, "t.sfz", &findings)
	b := strings.builder_make()
	for l in desc.layers {
		fmt.sbprintf(&b, "layer %v gain %g\n", l.region, l.gain)
		for n in l.program.nodes {
			fmt.sbprintf(&b, "%s/%s:", n.name, device.node_row(n.kind).name)
			for v in n.values {
				fmt.sbprintf(&b, " %g", v)
			}
			for m in n.mods {
				fmt.sbprintf(&b, " [%d %s %v %g]", m.slot, m.source, m.kind, m.amount)
			}
			strings.write_byte(&b, '\n')
		}
		for x in l.program.tables {
			fmt.sbprintf(&b, "table %s:", x.node)
			for p in x.points {
				fmt.sbprintf(&b, " %.4g", p)
			}
			strings.write_byte(&b, '\n')
		}
	}
	for f in findings {
		fmt.sbprintf(&b, "%s %v %s\n", f.code, f.severity, f.message)
	}
	return strings.to_string(b)
}

// A region's LFOs and flex EG move what their opcodes name, in their
// order: every node of the region's program, its values and its modulators,
// as SFZ v2 says (held to how the region compiled when these rows were
// written out one by one).
@(test)
test_sfz_modulation :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	got := sfz_compiled(`<region> sample=a.wav fil_type=lpf_2p cutoff=800
lfo1_freq=5 lfo1_pitch=30 lfo1_volume=2 lfo1_amplitude=50 lfo1_pan=20 lfo1_cutoff=600 lfo1_wave=2
lfo2_freq=0.5 lfo2_cutoff=-300
eg1_time1=0.1 eg1_level1=1 eg1_time2=0.4 eg1_level2=0.2 eg1_sustain=2 eg1_amplitude=80 eg1_volume=3 eg1_pitch=-100 eg1_cutoff=1200 eg1_pan=-40
`)
	testing.expectf(t, got == SFZ_MODULATION, "the region compiles to\n%s", got)
}

// What a region reads by a number in an opcode's name: its CC conditions
// (loccN, hiccN), crossfades (xfin_loccN, xfout_hiccN), velocity curve
// (amp_velcurve_N), a CC's curve (cutoff_curveccN) and what a CC moves, in
// SFZ v2's spelling or v1's (lfo1_freq_oncc1, cutoff_cc1: the reference
// lists the forms as rows of their own); what it doesn't read, a finding
// each (bitred, and its CC's form; the smoothing of a CC at one value is
// nothing).
@(test)
test_sfz_numbered :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	got := sfz_compiled(`<control> set_cc1=100 set_cc64=127 set_cc2=40 label_cc1=Mod
<curve> curve_index=7 v000=0 v064=0.2 v127=1
<global> amp_velcurve_1=0.1 amp_velcurve_127=1
<group> locc64=64 hicc64=127 xfin_locc1=0 xfin_hicc1=127
<region> sample=a.wav cutoff=500 cutoff_oncc1=1200 cutoff_curvecc1=7 lfo1_freq=3 lfo1_freq_oncc1=2 lfo5_pitch=10 lfo5_freq=1 xfout_locc2=10 xfout_hicc2=x
<region> sample=b.wav locc64=0 hicc64=10 key=62
<region> sample=c.wav cutoff=700 cutoff_cc1=600 bitred=5 bitred_oncc1=10 loop_mode=loop_continuous volume_cc7=3 pitch_smoothcc1=10 fil_veltrack=100 eq1_freq=200 eq1_gain=3 group_label=g foo_bar=1 xfin_locc300=1
`)
	testing.expectf(t, got == SFZ_NUMBERED, "the instrument compiles to\n%s", got)
}

@(private = "file")
SFZ_MODULATION :: `layer Layer_Region{lo_key = 0, hi_key = 127, lo_vel = 0, hi_vel = 127, lo_rand = 0, hi_rand = 1.01, seq_length = 1, seq_position = 1, trigger = "Attack", sw_last_lo = 0, sw_last_hi = 0, group = 0, off_by = 0, off_mode = "Fast", off_time = 0.006, polyphony = 0, note_polyphony = 0, rt_decay = 0} gain 0
src/Region: 1 0 1 0 0 60 100 0 1 0 0 0 0 -1 0 0 100 0 0 0 0 0 0 0 [8 lfo1 Octaves 0.025] [8 eg1 Octaves -0.083333336]
fil/Filter: 1 0 1 0 800 0.7071 -12 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 [4 lfo1 Octaves 0.5] [4 lfo2 Octaves -0.25] [4 eg1 Octaves 1]
ampeg/Env: 1 0 1 0 0 1 0.001 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
out/Mix: 1 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 [2 ampeg Depth 1] [2 vel Depth 1] [2 lfo1 Octaves 0.3321928] [2 lfo1 Amount 0.5] [1 lfo1 Amount 0.2] [2 eg1 Depth 0.8] [2 eg1 Octaves 0.4982892] [1 eg1 Amount -0.4]
vel/Curve: 1 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
lfo1/Lfo: 1 0 1 3 5 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
lfo2/Lfo: 1 0 1 0 0.5 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
eg1/Segments: 1 0 1 0 0.1 0.4 0 0 0 0 0 0 1 0.2 0 0 0 0 0 2 3 0 0 0
table vel: 0 6.2e-05 0.000248 0.000558 0.000992 0.00155 0.002232 0.003038 0.003968 0.005022 0.0062 0.007502 0.008928 0.01048 0.01215 0.01395 0.01587 0.01792 0.02009 0.02238 0.0248 0.02734 0.03001 0.0328 0.03571 0.03875 0.04191 0.0452 0.04861 0.05214 0.0558 0.05958 0.06349 0.06752 0.07167 0.07595 0.08035 0.08488 0.08953 0.0943 0.0992 0.1042 0.1094 0.1146 0.12 0.1256 0.1312 0.137 0.1428 0.1489 0.155 0.1613 0.1676 0.1742 0.1808 0.1876 0.1944 0.2014 0.2086 0.2158 0.2232 0.2307 0.2383 0.2461 0.254 0.262 0.2701 0.2783 0.2867 0.2952 0.3038 0.3125 0.3214 0.3304 0.3395 0.3488 0.3581 0.3676 0.3772 0.3869 0.3968 0.4068 0.4169 0.4271 0.4375 0.448 0.4586 0.4693 0.4801 0.4911 0.5022 0.5134 0.5248 0.5362 0.5478 0.5596 0.5714 0.5834 0.5954 0.6077 0.62 0.6325 0.645 0.6578 0.6706 0.6836 0.6966 0.7098 0.7232 0.7366 0.7502 0.7639 0.7777 0.7917 0.8058 0.82 0.8343 0.8487 0.8633 0.878 0.8928 0.9077 0.9228 0.938 0.9533 0.9688 0.9843 1
`

@(private = "file")
SFZ_NUMBERED :: `layer Layer_Region{lo_key = 0, hi_key = 127, lo_vel = 0, hi_vel = 127, lo_rand = 0, hi_rand = 1.01, seq_length = 1, seq_position = 1, trigger = "Attack", sw_last_lo = 0, sw_last_hi = 0, group = 0, off_by = 0, off_mode = "Fast", off_time = 0.006, polyphony = 0, note_polyphony = 0, rt_decay = 0} gain 0
src/Region: 1 0 1 0 0 60 100 0 1 0 0 0 0 -1 0 0 100 0 0 0 0 0 0 0 [8 lfo5 Octaves 0.008333334]
fil/Filter: 1 0 1 0 1288.5714 0.7071 -12 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
ampeg/Env: 1 0 1 0 0 1 0.001 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
out/Mix: 0 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 [2 ampeg Depth 1] [2 vel Depth 1]
vel/Curve: 1 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
lfo1/Lfo: 1 0 1 0 4.5748034 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
lfo5/Lfo: 1 0 1 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
table vel: 0 0.1 0.1071 0.1143 0.1214 0.1286 0.1357 0.1429 0.15 0.1571 0.1643 0.1714 0.1786 0.1857 0.1929 0.2 0.2071 0.2143 0.2214 0.2286 0.2357 0.2429 0.25 0.2571 0.2643 0.2714 0.2786 0.2857 0.2929 0.3 0.3071 0.3143 0.3214 0.3286 0.3357 0.3429 0.35 0.3571 0.3643 0.3714 0.3786 0.3857 0.3929 0.4 0.4071 0.4143 0.4214 0.4286 0.4357 0.4429 0.45 0.4571 0.4643 0.4714 0.4786 0.4857 0.4929 0.5 0.5071 0.5143 0.5214 0.5286 0.5357 0.5429 0.55 0.5571 0.5643 0.5714 0.5786 0.5857 0.5929 0.6 0.6071 0.6143 0.6214 0.6286 0.6357 0.6429 0.65 0.6571 0.6643 0.6714 0.6786 0.6857 0.6929 0.7 0.7071 0.7143 0.7214 0.7286 0.7357 0.7429 0.75 0.7571 0.7643 0.7714 0.7786 0.7857 0.7929 0.8 0.8071 0.8143 0.8214 0.8286 0.8357 0.8429 0.85 0.8571 0.8643 0.8714 0.8786 0.8857 0.8929 0.9 0.9071 0.9143 0.9214 0.9286 0.9357 0.9429 0.95 0.9571 0.9643 0.9714 0.9786 0.9857 0.9929 1
layer Layer_Region{lo_key = 0, hi_key = 127, lo_vel = 0, hi_vel = 127, lo_rand = 0, hi_rand = 1.01, seq_length = 1, seq_position = 1, trigger = "Attack", sw_last_lo = 0, sw_last_hi = 0, group = 0, off_by = 0, off_mode = "Fast", off_time = 0.006, polyphony = 0, note_polyphony = 0, rt_decay = 0} gain 0
src/Region: 1 0 1 0 2 60 100 0 1 0 0 0 3 -1 0 0 100 0 0 0 0 0 0 0
fil/Filter: 1 0 1 0 1172.4409 0.7071 -12 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 [4 velocity Octaves 0.083333336]
eq1/Filter: 1 0 1 7 200 1.4142135 -12 3 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
ampeg/Env: 1 0 1 0 0 1 0.001 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
out/Mix: 1.1646848 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 [2 ampeg Depth 1] [2 vel Depth 1]
vel/Curve: 1 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
table vel: 0 0.1 0.1071 0.1143 0.1214 0.1286 0.1357 0.1429 0.15 0.1571 0.1643 0.1714 0.1786 0.1857 0.1929 0.2 0.2071 0.2143 0.2214 0.2286 0.2357 0.2429 0.25 0.2571 0.2643 0.2714 0.2786 0.2857 0.2929 0.3 0.3071 0.3143 0.3214 0.3286 0.3357 0.3429 0.35 0.3571 0.3643 0.3714 0.3786 0.3857 0.3929 0.4 0.4071 0.4143 0.4214 0.4286 0.4357 0.4429 0.45 0.4571 0.4643 0.4714 0.4786 0.4857 0.4929 0.5 0.5071 0.5143 0.5214 0.5286 0.5357 0.5429 0.55 0.5571 0.5643 0.5714 0.5786 0.5857 0.5929 0.6 0.6071 0.6143 0.6214 0.6286 0.6357 0.6429 0.65 0.6571 0.6643 0.6714 0.6786 0.6857 0.6929 0.7 0.7071 0.7143 0.7214 0.7286 0.7357 0.7429 0.75 0.7571 0.7643 0.7714 0.7786 0.7857 0.7929 0.8 0.8071 0.8143 0.8214 0.8286 0.8357 0.8429 0.85 0.8571 0.8643 0.8714 0.8786 0.8857 0.8929 0.9 0.9071 0.9143 0.9214 0.9286 0.9357 0.9429 0.95 0.9571 0.9643 0.9714 0.9786 0.9857 0.9929 1
unsupported_opcode Warning t.sfz: bitred isn't played (1 use, first at t.sfz:7); the sound differs from SFZ's there
unsupported_opcode Warning t.sfz: bitred (by a CC) isn't played (1 use, first at t.sfz:7); the sound differs from SFZ's there
unknown_opcode Warning t.sfz: foo_bar is not an SFZ opcode (1 use, first at t.sfz:7)
`
