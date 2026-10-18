package odawg_device

import "core:math"

// Tone's Player: a clip played as recorded, from `.Offset` seconds in, for
// the note's duration (its gate is where it stops), with fades in and out
// (each at least DECLICK, so nothing clicks) of `.Curve`'s shape, and
// `.Mono` folding the sides together. The clip is the first sample of the
// bank set `.Sample_Set`; velocity is its gain. This is onimite's track,
// sample for sample: its envelope is onimite's track_envelope.

// The shortest fade a clip starts and ends with: 3 ms.
DECLICK :: RATE * 3 / 1000

@(private = "file")
Player_State :: struct {
	sample: i32, // into env.bank.samples (-1: none)
	first:  i64, // the clip frame its first sample plays
	length: i64, // samples it plays (its gate)
}

#assert(size_of(Player_State) <= VOICE_STATE_SIZE)

// What a Player's slot takes (its row's `state`).
PLAYER_STATE_BYTES :: size_of(Player_State)

voice_player :: proc(s: ^Voice_State, p: ^Params, n: Note, seed: u64, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	st := (^Player_State)(&s.bytes)
	if at == 0 {
		st.sample = -1
		st.first = i64(math.round(f64(p[.Offset]) * RATE))
		st.length = i64(math.round(n.duration * RATE))
		set := int(p[.Sample_Set])
		if env != nil && env.bank != nil && set >= 0 && set < len(env.bank.sets) {
			zs := env.bank.sets[set].zones
			if zs.count > 0 {
				st.sample = env.bank.zones[zs.first].sample
			}
		}
	}
	if st.sample < 0 || at >= st.length {
		return false
	}
	sm := env.bank.samples[st.sample]
	count := min(i64(len(l)), st.length - at)
	switch sm.format {
	case .F32:
		player_run(st, p, n, sample_f32(env.bank, sm), int(sm.channels), 1, at, l[:count], r[:count])
	case .I16:
		player_run(st, p, n, sample_i16(env.bank, sm), int(sm.channels), 1.0 / 32768, at, l[:count], r[:count])
	}
	return at + count < st.length
}

// The clip's frames into l and r: one typed loop per sample format.
@(private = "file")
player_run :: proc(st: ^Player_State, p: ^Params, n: Note, data: []$T, channels: int, scale: f32, at: i64, l, r: []f32) {
	frames := i64(len(data) / channels)
	fade_in := max(i64(math.round(f64(p[.Fade_In]) * RATE)), DECLICK)
	fade_out := max(i64(math.round(f64(p[.Fade_Out]) * RATE)), DECLICK)
	curve := Curve(clamp(int(p[.Curve]), 0, len(Curve) - 1))
	mono := p[.Mono] > 0.5
	right := channels > 1 ? 1 : 0
	for i in 0 ..< i64(len(l)) {
		k := at + i
		src := st.first + k
		if src < 0 || src >= frames {
			continue
		}
		g := n.velocity * fade_gain(k, fade_in, curve) * fade_gain(st.length - 1 - k, fade_out, curve)
		a := f32(data[src * i64(channels)]) * scale
		b := f32(data[src * i64(channels) + i64(right)]) * scale
		if mono {
			a = a * 0.70710678 + b * 0.70710678
			b = a
		}
		l[i] += a * g
		r[i] += b * g
	}
}

tail_player :: proc(p: ^Params, n: Note, env: ^Voice_Env) -> f64 {return n.duration}

// Gain 0..1 `k` samples into a fade of `length` samples.
@(private = "file")
fade_gain :: #force_inline proc "contextless" (k, length: i64, curve: Curve) -> f32 {
	if length <= 0 || k >= length {
		return 1
	}
	t := f32(max(k, 0)) / f32(length)
	return curve == .Equal_Power ? math.sin(t * math.PI / 2) : t
}
