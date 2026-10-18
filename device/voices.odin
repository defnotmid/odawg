package odawg_device

import dsp "../dsp"
import base "../base"
import "core:math"

// The voices' shared steps. A voice streams: each
// call plays the note's next len(l) samples, with everything that carries
// from sample to sample (phases, envelope stages, filter memories, the noise
// generator) in its state, so the samples are the same however the note is
// split into calls. The gate closes at sample round(n.duration * RATE).

// The samples a voice works on at a time, on the stack.
CHUNK :: 256

// A kind's state struct over a voice's bytes.
voice_state :: #force_inline proc "contextless" (s: ^Voice_State, $T: typeid) -> ^T {
	return (^T)(&s.bytes[0])
}

// The sample the gate closes at.
gate_sample :: proc "contextless" (n: Note) -> i64 {return i64(math.round(max(n.duration, 0) * RATE))}

// How many of this call's samples the note still sounds for.
voice_span :: proc "contextless" (at, total: i64, l, r: []f32) -> int {
	return int(clamp(total - at, 0, i64(min(len(l), len(r)))))
}

// The note's pitch in Hz (60 when it has none).
note_hz :: proc(n: Note) -> f64 {
	return base.midi_to_hz(f64(n.pitch > 0 ? n.pitch : 60))
}
