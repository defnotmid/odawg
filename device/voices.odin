package odawg_device

import "core:math"

// The voices' shared steps. A voice streams: each
// call plays the note's next len(l) samples, with everything that carries
// from sample to sample (phases, envelope stages, filter memories, the noise
// generator) in its state, so the samples are the same however the note is
// split into calls. The gate closes at sample round(n.duration * RATE).

// The sample the gate closes at.
gate_sample :: proc "contextless" (n: Note) -> i64 {return i64(math.round(max(n.duration, 0) * RATE))}
