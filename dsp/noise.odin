package odawg_dsp

import base "../base"

// Noise from a seeded generator, in Tone's colours: white; pink through Paul
// Kellet's refined filter, scaled by 0.11 as Tone's pink buffer is; brown as
// Tone makes it (a leaky integral of white, times 3.5).

Noise :: struct {
	type:  Noise_Type,
	rng:   base.Rng,
	pink:  [7]f32,
	brown: f32,
}

noise_init :: proc "contextless" (type: Noise_Type, seed: u64) -> Noise {
	return {type = type, rng = base.rng_init(seed)}
}

// White noise, -1..1, from a generator.
white_run :: proc "contextless" (rng: ^base.Rng, out: []f32) {
	for i in 0 ..< len(out) {
		out[i] = base.rng_noise(rng)
	}
}

// Fills `out` with the next samples of the noise.
noise_run :: proc "contextless" (n: ^Noise, out: []f32) {
	white_run(&n.rng, out)
	switch n.type {
	case .White:
	case .Pink:
		b := n.pink
		for i in 0 ..< len(out) {
			w := out[i]
			b[0] = 0.99886 * b[0] + w * 0.0555179
			b[1] = 0.99332 * b[1] + w * 0.0750759
			b[2] = 0.96900 * b[2] + w * 0.1538520
			b[3] = 0.86650 * b[3] + w * 0.3104856
			b[4] = 0.55000 * b[4] + w * 0.5329522
			b[5] = -0.7616 * b[5] - w * 0.0168980
			v := b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + w * 0.5362
			b[6] = w * 0.115926
			out[i] = v * 0.11
		}
		n.pink = b
	case .Brown:
		last := n.brown
		for i in 0 ..< len(out) {
			last = (last + 0.02 * out[i]) / 1.02
			out[i] = last * 3.5
		}
		n.brown = last
	}
}

// The colours of noise.
Noise_Type :: enum u8 {
	White,
	Pink,
	Brown,
}
