package odawg_device

import base "../base"
import "core:math"

// Effect rows: an effect as a program of nodes, the way an instrument is
// one (graph.odin), played over the audio it is put on. A spec's `effects`
// table names rows, and a chain places one by its name as it places a
// built-in. Each placement plays its own program (its device's .Program) as
// one voice that never ends: its Input node writes the block the effect is
// put on, and its out takes the block's place.
//
// The voice has no note: a kind that plays from one (needs .Note) or a node
// reading the note's sources is refused where the row is placed
// (effect_reads_note). Its clock is the song's: an Lfo there takes its
// phase from the song sample, so a seek or a reset (a dormant node waking)
// puts it where a render from the start has it. So nothing moves an Lfo's
// rate in a row (a field's `pace`), and no lane moves a field read as the
// voice starts (`at_start`). What a row remembers of its input is the sum
// of what its nodes remember (program_memory): what a seek pre-rolls, and
// how long a dormant node stays awake after its input stops.

// A Row's state: its clock (the song sample its voice started at), then
// its program's voice.
Fx_Row :: struct #align (16) {
	clock: i64,
}

// Plays the row's program over a block, in place. No program (none placed,
// or no instruments given): the block as it came.
effect_row :: proc(state: []u8, p: ^Params, l, r: []f32, key_l, key_r: []f32, scratch: ^Fx_Scratch) {
	env := scratch.env
	program := graph_program(p, env)
	if program < 0 {
		return
	}
	f := fx_header(state, Fx_Row)
	voice := (^Voice_State)(raw_data(state[size_of(Fx_Row):]))
	h := (^Graph_Header)(voice)
	if !h.started {
		graph_start_effect(voice, program)
	}
	graph := scratch.graph[:graph_scratch(&env.programs.programs[program], 1)]
	n := min(len(l), len(r))
	for start := 0; start < n; start += FX_CHUNK {
		m := min(FX_CHUNK, n - start)
		cl, cr := l[start:][:m], r[start:][:m]
		copy(scratch.dry_l[:m], cl)
		copy(scratch.dry_r[:m], cr)
		slice_zero(cl)
		slice_zero(cr)
		v := [1]Graph_Voice{{state = voice, note = {velocity = 1, pitch = 60}, at = h.pos, out_l = cl, out_r = cr, gain = 1, in_l = scratch.dry_l[:m], in_r = scratch.dry_r[:m], clock = f.clock, tempo = scratch.tempo, seconds = base.seconds_from_samples(f.clock)}}
		graph_run(env.programs, env, program, v[:], m, graph)
	}
}

// A cutoff a modulator or an option moves is taken here for a row's memory:
// the lowest it is heard at, where it rings longest.
MEMORY_LOWEST_HZ :: 20

// Seconds a program's nodes remember of their input, summed (a bound for a
// chain of them): each kind's memory at its values, a cutoff that moves at
// MEMORY_LOWEST_HZ.
program_memory :: proc(progs: ^Programs, program: i32) -> f64 {
	prog := progs.programs[program]
	// the fields an option reaches, per node
	moved := make([]u64, prog.nodes.count, context.temp_allocator)
	for c in progs.controls[prog.controls.first:base.span_end(prog.controls)] {
		for t in progs.control_targets[c.targets.first:base.span_end(c.targets)] {
			if k := t.node - prog.nodes.first; t.mod < 0 && k >= 0 && k < prog.nodes.count {
				moved[k] |= u64(1) << u64(t.slot)
			}
		}
	}
	total: f64
	for g, k in progs.nodes[prog.nodes.first:base.span_end(prog.nodes)] {
		row := node_row(g.kind)
		if row.memory == nil {
			continue
		}
		values := g.values
		for slot in 0 ..< MAX_FIELDS {
			if (g.mod_slots | moved[k]) & (u64(1) << u64(slot)) == 0 {
				continue
			}
			if f := field_of_slot(g.kind, slot); f != nil && f.unit == .Hz {
				values[slot] = min(values[slot], MEMORY_LOWEST_HZ)
			}
		}
		total += row.memory(&values, row.slots)
	}
	return total
}

// ---- Input: what an effect row is put on ----------------------------------------------

@(private)
process_input :: proc(c: ^Node_Call) {
	for &lane in c.lanes {
		l, r := node_out(c, &lane)
		if lane.in_l == nil {
			slice_zero(l)
			slice_zero(r)
			continue
		}
		copy(l, lane.in_l[:len(l)])
		copy(r, lane.in_r[:len(r)])
	}
}

// ---- Follower: a level ------------------------------------------------------------------

@(private = "file")
FOLLOWER_ATTACK :: 3
@(private = "file")
FOLLOWER_RELEASE :: 4

@(private)
Follower_State :: struct {
	y: f32,
}

// The level of what it reads (two sides as one: the larger), rising with
// the `attack` time constant and falling with `release`: what drives an
// autowah's cutoff, or a duck built of nodes.
@(private)
process_follower :: proc(c: ^Node_Call) {
	for &lane in c.lanes {
		s := node_state(c, &lane, Follower_State)
		attack := 1 - f32(math.exp(-1 / (f64(max(node_value(c, &lane, FOLLOWER_ATTACK), 1e-6)) * RATE)))
		release := 1 - f32(math.exp(-1 / (f64(max(node_value(c, &lane, FOLLOWER_RELEASE), 1e-6)) * RATE)))
		il, ir := node_input(c, &lane, 0)
		l, _ := node_out(c, &lane)
		y := s.y
		for i in 0 ..< len(l) {
			x := max(abs(il[i]), abs(ir[i]))
			y += (x - y) * (x > y ? attack : release)
			l[i] = y
		}
		s.y = y
	}
}

@(private)
memory_follower :: proc(values: ^[MAX_FIELDS]f32, slots: []int) -> f64 {
	return FX_FORGET * f64(max(values[FOLLOWER_ATTACK], 0) + max(values[FOLLOWER_RELEASE], 0))
}
