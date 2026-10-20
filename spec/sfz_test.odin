package odawg_spec

import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import base "../base"
import device "../device"

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
	text := `<region> sample=a.wav fil_type=lpf_2p cutoff=800
lfo1_freq=5 lfo1_pitch=30 lfo1_volume=2 lfo1_amplitude=50 lfo1_pan=20 lfo1_cutoff=600 lfo1_wave=2
lfo2_freq=0.5 lfo2_cutoff=-300
eg1_time1=0.1 eg1_level1=1 eg1_time2=0.4 eg1_level2=0.2 eg1_sustain=2 eg1_amplitude=80 eg1_volume=3 eg1_pitch=-100 eg1_cutoff=1200 eg1_pan=-40
`
	s: Sfz
	sfz_read(&s, "t.sfz", text, nil)
	findings := make(base.Findings)
	cc: [128]f32
	desc := sfz_program_desc(&s, 0, cc, "t.sfz", &findings)
	testing.expect(t, desc != nil && len(desc.layers) == 1)
	if desc == nil || len(desc.layers) == 0 || desc.layers[0].program == nil {
		return
	}
	b := strings.builder_make()
	for n in desc.layers[0].program.nodes {
		fmt.sbprintf(&b, "%s/%s:", n.name, device.node_row(n.kind).name)
		for v in n.values {
			fmt.sbprintf(&b, " %g", v)
		}
		for m in n.mods {
			fmt.sbprintf(&b, " [%d %s %v %g]", m.slot, m.source, m.kind, m.amount)
		}
		strings.write_byte(&b, '\n')
	}
	got := strings.to_string(b)
	testing.expectf(t, got == SFZ_MODULATION, "the region compiles to\n%s", got)
}

@(private = "file")
SFZ_MODULATION :: `src/Region: 1 0 1 0 0 60 100 0 1 0 0 0 0 -1 0 0 100 0 0 0 0 0 0 0 [8 lfo1 Octaves 0.025] [8 eg1 Octaves -0.083333336]
fil/Filter: 1 0 1 0 800 0.7071 -12 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 [4 lfo1 Octaves 0.5] [4 lfo2 Octaves -0.25] [4 eg1 Octaves 1]
ampeg/Env: 1 0 1 0 0 1 0.001 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
out/Mix: 1 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 [2 ampeg Depth 1] [2 vel Depth 1] [2 lfo1 Octaves 0.3321928] [2 lfo1 Amount 0.5] [1 lfo1 Amount 0.2] [2 eg1 Depth 0.8] [2 eg1 Octaves 0.4982892] [1 eg1 Amount -0.4]
vel/Curve: 1 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
lfo1/Lfo: 1 0 1 3 5 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
lfo2/Lfo: 1 0 1 0 0.5 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
eg1/Segments: 1 0 1 0 0.1 0.4 0 0 0 0 0 0 1 0.2 0 0 0 0 0 2 3 0 0 0
`
