package odawg_device

import "core:mem/virtual"
import "core:testing"
import base "../base"

// A layered instrument's regions of one shape share its program; each
// region's tables (two Curves here) are its own, wherever compiling placed
// them: a region whose table another already placed reads that one.
@(test)
test_layer_tables :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	ramp :: proc(scale: f32) -> []f32 {
		points := make([]f32, CURVE_POINTS, context.temp_allocator)
		for &p, i in points {
			p = scale * f32(i) / (CURVE_POINTS - 1)
		}
		return points
	}
	a, b, c := ramp(1), ramp(0.5), ramp(0.25)
	shape :: proc(vel, key: []f32) -> ^Program_Desc {
		d := new(Program_Desc, context.temp_allocator)
		d.out = "out"
		nodes := make([]Node_Desc, 3, context.temp_allocator)
		nodes[0] = {name = "vel", kind = NODE_CURVE, values = node_defaults(NODE_CURVE), inputs = {"velocity"}}
		nodes[1] = {name = "key_fade", kind = NODE_CURVE, values = node_defaults(NODE_CURVE), inputs = {"velocity"}}
		nodes[2] = {name = "out", kind = NODE_MIX, values = node_defaults(NODE_MIX), inputs = {"vel", "key_fade"}}
		d.nodes = nodes
		tables := make([]Table_Desc, 2, context.temp_allocator)
		tables[0], tables[1] = {"vel", vel}, {"key_fade", key}
		d.tables = tables
		return d
	}
	want := [][2][]f32{{a, b}, {c, a}, {b, c}}
	layers := make([]Layer_Desc, len(want), context.temp_allocator)
	for w, i in want {
		layers[i] = {program = shape(w[0], w[1]), region = {hi_key = 127, hi_vel = 127, hi_rand = 1, seq_length = 1, seq_position = 1}}
	}
	desc := Program_Desc{layers = layers, out = "out"}
	progs: Programs
	findings := make(base.Findings, context.temp_allocator)
	index := compile_program(&progs, &desc, &findings)
	testing.expect(t, index >= 0, "compiled")
	prog := progs.programs[index]
	testing.expect_value(t, int(prog.layers.count), len(want))
	for w, i in want {
		layer := prog.layers.first + i32(i)
		play := progs.layers[layer].program
		for name, k in ([2]string{"vel", "key_fade"}) {
			id := base.name_id(name)
			pp := progs.programs[play]
			for g, j in progs.nodes[pp.nodes.first:base.span_end(pp.nodes)] {
				if g.name != id {
					continue
				}
				at := int(layer_value(&progs, layer, play, j, node_table_slot(g.kind))) * CURVE_POINTS
				same := at >= 0 && at + CURVE_POINTS <= len(progs.tables)
				for p, q in w[k] {
					same &&= same && progs.tables[at + q] == p
				}
				testing.expectf(t, same, "region %d's %s reads another table", i, name)
			}
		}
	}
}
