package odawg_device

import base "../base"
import "core:math"

// Tone's Sampler over a set of the Bank: a note picks the zone answering its
// key and velocity (the nearest when none does; one of a round-robin group by
// the note's seed), plays its sample shifted from the zone's root through a
// Kaiser-windowed sinc (wider, and lower, when shifting up, so nothing
// aliases), and shapes it with its attack (a linear fade in) and release
// (Tone's exponential approach to silence after the gate). A one-shot zone
// (a drum) plays to its end whatever the gate. A note answers the key it is
// given (a pad's, or its pitch) and plays at its pitch.
//
// Every output sample is computed from its index alone (the read position,
// the envelope), so a note renders the same whatever blocks it is split into.
//
// The level is the zone's gain times the MIDI velocity over the top of the
// zone's velocity range: a sampled layer is already as loud as it was
// played, and softer notes inside it are scaled down linearly.

// Taps on each side of the read position at unity (32 in all), the window's
// Kaiser beta (about 70 dB of stopband), and the table's steps per tap.
SINC_HALF :: 16
SINC_BETA :: 7.0
SINC_STEPS :: 512
// The widest a kernel gets, shifting up: two octaves (beyond, it aliases).
SINC_MAX_STRETCH :: 4

// Seconds a drum note may ring before its samples are loaded (then, their
// own length).
SAMPLER_ONE_SHOT_TAIL :: 8.0

// The shortest release, so a cut never clicks: 3 ms.
@(private = "file")
SAMPLER_DECLICK :: 3.0 / 1000

// One side of the kernel at SINC_STEPS points per tap (symmetric), zero for
// two taps past its edge, so a tap at the edge reads it without a check.
@(private = "file")
sinc_table: [(SINC_HALF + 2) * SINC_STEPS + 2]f32

@(private = "file")
bessel_i0 :: proc "contextless" (x: f64) -> f64 {
	sum, term := 1.0, 1.0
	for k in 1 ..< 64 {
		term *= (x / (2 * f64(k))) * (x / (2 * f64(k)))
		sum += term
		if term < sum * 1e-17 {
			break
		}
	}
	return sum
}

// sinc(x) under a Kaiser window `half` taps wide on each side (0 beyond):
// the kernel the sampler reads with, and the assets layer resamples with.
kaiser_sinc :: proc "contextless" (x, half, beta: f64) -> f64 {
	if abs(x) >= half {
		return 0
	}
	s := x == 0 ? 1.0 : math.sin(math.PI * x) / (math.PI * x)
	r := x / half
	return s * bessel_i0(beta * math.sqrt(1 - r * r)) / bessel_i0(beta)
}

@(init, private = "file")
sinc_init :: proc "contextless" () {
	for i in 0 ..< len(sinc_table) {
		sinc_table[i] = f32(kaiser_sinc(f64(i) / SINC_STEPS, SINC_HALF, SINC_BETA))
	}
}

@(private = "file")
kernel :: #force_inline proc "contextless" (x: f64) -> f32 {
	t := abs(x) * SINC_STEPS
	i := int(t)
	if i >= SINC_HALF * SINC_STEPS {
		return 0
	}
	f := f32(t - f64(i))
	return sinc_table[i] + (sinc_table[i + 1] - sinc_table[i]) * f
}

Sampler_State :: struct {
	zone:      i32, // into the bank's zones (-1: nothing to play)
	length:    i64, // its frames
	loop_from: i64,
	loop_to:   i64, // <= loop_from: no loop
	offset:    i64, // the frame a note starts at
	step:      f64, // sample frames per output sample
	cutoff:    f64, // the kernel's, relative to the sample's Nyquist
	taps:      int, // on each side
	gain_l:    f32,
	gain_r:    f32,
	attack:    f64, // samples
	release:   f64, // seconds
	release_tc: f64, // the release's time constant (dsp.approach's), once a note
	gate:      i64, // the sample the release starts at (-1: a one-shot)
}

#assert(size_of(Sampler_State) <= VOICE_STATE_SIZE)

// MIDI velocity 1..127 from a note's 0..1.
velocity_midi :: proc "contextless" (v: f32) -> int {
	return clamp(int(math.round(v * 127)), 1, 127)
}

@(private = "file")
range_distance :: #force_inline proc "contextless" (x, lo, hi: int) -> int {
	return x < lo ? lo - x : (x > hi ? x - hi : 0)
}

// Whether zone `z` is one a note at `key` and `velocity` can play, given
// how near the nearest come (zone_nearest).
zone_is_nearest :: proc(z: ^Zone, key, velocity, best_key, best_vel: int) -> bool {
	return range_distance(key, int(z.lo_key), int(z.hi_key)) == best_key && range_distance(velocity, int(z.lo_velocity), int(z.hi_velocity)) == best_vel
}

// The zone of `set` a note at `key` and `velocity` (MIDI) plays: those
// answering both, else the nearest key, then the nearest velocity; among
// several (a round-robin group), the one `seed` picks. -1: the set has none.
zone_for :: proc(bank: ^Bank, set: int, key, velocity: int, seed: u64) -> i32 {
	if bank == nil || set < 0 || set >= len(bank.sets) {
		return -1
	}
	span := bank.sets[set].zones
	best_key, best_vel, count := zone_nearest(bank, set, key, velocity)
	if count == 0 {
		return -1
	}
	pick := int(base.hash64(seed ~ 0x5a3b1e) % u64(count))
	for i in span.first ..< base.span_end(span) {
		z := &bank.zones[i]
		if range_distance(key, int(z.lo_key), int(z.hi_key)) == best_key && range_distance(velocity, int(z.lo_velocity), int(z.hi_velocity)) == best_vel {
			if pick == 0 {
				return i
			}
			pick -= 1
		}
	}
	return -1
}

// How near the zones of `set` nearest a note come (keys, then velocities
// away), and how many are that near: the ones zone_for picks among.
zone_nearest :: proc(bank: ^Bank, set: int, key, velocity: int) -> (best_key, best_vel, count: int) {
	best_key, best_vel = max(int), max(int)
	span := bank.sets[set].zones
	for i in span.first ..< base.span_end(span) {
		z := &bank.zones[i]
		dk := range_distance(key, int(z.lo_key), int(z.hi_key))
		dv := range_distance(velocity, int(z.lo_velocity), int(z.hi_velocity))
		switch {
		case dk < best_key || (dk == best_key && dv < best_vel):
			best_key, best_vel, count = dk, dv, 1
		case dk == best_key && dv == best_vel:
			count += 1
		}
	}
	return
}

// A note of set `set` answering `key` at the note's pitch.
sampler_start :: proc(st: ^Sampler_State, set: i32, attack, release: f32, key: f32, n: Note, seed: u64, env: ^Voice_Env) {
	st.zone = -1
	if env == nil || env.bank == nil {
		return
	}
	bank := env.bank
	pitch := n.pitch > 0 ? n.pitch : key
	velocity := velocity_midi(n.velocity)
	zi := zone_for(bank, int(set), int(math.round(key)), velocity, seed)
	if zi < 0 {
		return
	}
	z := &bank.zones[zi]
	if z.sample < 0 || int(z.sample) >= len(bank.samples) {
		return
	}
	st.zone = zi
	st.length = bank.samples[z.sample].frames
	st.loop_from, st.loop_to = i64(z.loop_from), i64(z.loop_to)
	st.offset = i64(max(z.offset, 0))
	if st.loop_to > st.length || st.loop_to - st.loop_from < 2 {
		st.loop_to = st.loop_from // not a usable loop
	}
	// the pitch shift, and the recording's rate to RATE
	st.step = math.pow(2, f64(pitch - z.root) / 12) * device_rate_ratio(bank.samples[z.sample])
	st.cutoff = clamp(1 / st.step, 1.0 / SINC_MAX_STRETCH, 1)
	st.taps = int(math.ceil(SINC_HALF / st.cutoff))
	amp := z.gain * min(f32(velocity) / f32(max(z.hi_velocity, 1)), 1)
	st.gain_l = amp * (z.pan > 0 ? 1 - z.pan : 1)
	st.gain_r = amp * (z.pan < 0 ? 1 + z.pan : 1)
	st.attack = max(f64(attack), 0) * RATE
	st.release = max(z.release > 0 ? f64(z.release) : f64(release), SAMPLER_DECLICK)
	st.release_tc = math.ln(st.release + 1) / math.ln(f64(200))
	st.gate = z.one_shot ? -1 : i64(math.round(max(n.duration, 0) * RATE))
}

// Sample frames per output sample at the root pitch (1: recorded at RATE).
@(private = "file")
device_rate_ratio :: proc "contextless" (s: Sample) -> f64 {return sample_rate(s) / RATE}

// The envelope at output sample k (done: silent from here on).
@(private = "file")
sampler_level :: #force_inline proc "contextless" (st: ^Sampler_State, k: i64) -> (level: f32, done: bool) {
	attack := proc "contextless" (st: ^Sampler_State, k: i64) -> f32 {
		return st.attack > 0 && f64(k) < st.attack ? f32(f64(k) / st.attack) : 1
	}
	if st.gate < 0 || k < st.gate {
		return attack(st, k), false
	}
	// dsp.approach toward silence, its time constant computed once a note
	from := attack(st, st.gate)
	t := f64(k - st.gate) / RATE
	switch {
	case t >= st.release:
		return 0, true
	case t < 0.9 * st.release:
		return from * f32(math.exp(-t / st.release_tc)), false
	}
	v90 := f64(from) * math.exp(-0.9 * st.release / st.release_tc)
	return f32(v90 - v90 * (t - 0.9 * st.release) / (0.1 * st.release)), false
}

// The note's next len(l) samples, added into l and r; false once it is over.
sampler_play :: proc(st: ^Sampler_State, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	if st.zone < 0 || env == nil || env.bank == nil {
		return false
	}
	sm := env.bank.samples[env.bank.zones[st.zone].sample]
	switch sm.format {
	case .F32:
		return sampler_run(st, sample_f32(env.bank, sm), int(sm.channels), 1, at, l, r)
	case .I16:
		return sampler_run(st, sample_i16(env.bank, sm), int(sm.channels), 1.0 / 32768, at, l, r)
	}
	return false
}

// The voice over its sample's frames: one typed loop per sample format and
// channel count (a mono recording plays to both sides). At the root pitch
// a sample is its own frames (the kernel is 1 at 0 and 0 at every other
// whole tap); away from the sample's edges and its loop's end the kernel
// sums in f32 without a check per tap. Every output sample is a function
// of its index alone.
@(private = "file")
sampler_run :: proc(st: ^Sampler_State, data: []$T, channels: int, scale: f32, at: i64, l, r: []f32) -> bool {
	looped := st.loop_to > st.loop_from
	loop_len := st.loop_to - st.loop_from
	m := min(len(l), len(r))
	cutoff := f32(st.cutoff) * scale
	right := i64(channels > 1 ? 1 : 0)
	ch := i64(channels)
	taps := i64(st.taps)
	// the frames a kernel may read without wrapping or leaving the sample
	safe_to := looped ? st.loop_to : st.length
	c := f32(st.cutoff)
	for i in 0 ..< m {
		k := at + i64(i)
		level, done := sampler_level(st, k)
		if done {
			return false
		}
		pos := f64(st.offset) + f64(k) * st.step
		if looped && pos >= f64(st.loop_to) {
			pos = f64(st.loop_from) + math.mod(pos - f64(st.loop_from), f64(loop_len))
		}
		if !looped && pos >= f64(st.length) + f64(st.taps) {
			return false
		}
		centre := i64(pos) // pos >= 0: truncation floors it
		frac := pos - f64(centre)
		sl, sr: f32
		switch {
		case frac == 0 && st.step == 1 && centre < st.length:
			sl, sr = f32(data[ch * centre]) * cutoff, f32(data[ch * centre + right]) * cutoff
		case centre - taps + 1 >= 0 && centre + taps < safe_to:
			f := f32(frac)
			for d in 1 - taps ..= taps {
				x := abs((f - f32(d)) * c) * SINC_STEPS
				ti := int(x)
				w := (sinc_table[ti] + (sinc_table[ti + 1] - sinc_table[ti]) * (x - f32(ti))) * cutoff
				fi := centre + d
				sl += f32(data[ch * fi]) * w
				sr += f32(data[ch * fi + right]) * w
			}
		case:
			for j in centre - taps + 1 ..= centre + taps {
				f := j
				if looped && f >= st.loop_to {
					f = st.loop_from + (f - st.loop_from) % loop_len
				}
				if f < 0 || f >= st.length {
					continue
				}
				w := kernel((frac - f64(j - centre)) * st.cutoff) * cutoff
				sl += f32(data[ch * f]) * w
				sr += f32(data[ch * f + right]) * w
			}
		}
		l[i] += sl * st.gain_l * level
		r[i] += sr * st.gain_r * level
	}
	return true
}

// What the zones the note can play make of it (of a round robin, the
// longest): a one-shot to its sample's end, a held note its gate and
// release, cut short by its sample's end unless it loops. Before the
// samples are loaded: a drum note SAMPLER_ONE_SHOT_TAIL, a held one its
// gate and release.
tail_sampler :: proc(set_index: i32, release: f32, key: f32, n: Note, env: ^Voice_Env) -> f64 {
	held := max(n.duration, 0) + max(f64(release), SAMPLER_DECLICK)
	guess := n.pad != 0 ? SAMPLER_ONE_SHOT_TAIL : held
	if env == nil || env.bank == nil {
		return guess
	}
	set := int(set_index)
	if set < 0 || set >= len(env.bank.sets) {
		return guess
	}
	bank := env.bank
	pitch := n.pitch > 0 ? n.pitch : key
	k, velocity := int(math.round(key)), velocity_midi(n.velocity)
	best_key, best_vel, _ := zone_nearest(bank, set, k, velocity)
	span := bank.sets[set].zones
	tail := 0.0
	for i in span.first ..< base.span_end(span) {
		z := &bank.zones[i]
		if range_distance(k, int(z.lo_key), int(z.hi_key)) != best_key || range_distance(velocity, int(z.lo_velocity), int(z.hi_velocity)) != best_vel {
			continue
		}
		if z.sample < 0 || int(z.sample) >= len(bank.samples) {
			return guess
		}
		sm := bank.samples[z.sample]
		step := math.pow(2, f64(pitch - z.root) / 12) * device_rate_ratio(sm)
		held := z.release > 0 ? max(n.duration, 0) + max(f64(z.release), SAMPLER_DECLICK) : held
		// to its last frame, and the kernel's reach past it
		left := (f64(sm.frames - i64(max(z.offset, 0))) / step + f64(SINC_HALF * SINC_MAX_STRETCH)) / RATE
		loops := z.loop_to - z.loop_from >= 2 && i64(z.loop_to) <= sm.frames
		switch {
		case z.one_shot && loops:
			tail = max(tail, 30) // rings until the song ends
		case z.one_shot:
			tail = max(tail, left)
		case loops:
			tail = max(tail, held)
		case:
			tail = max(tail, min(held, left))
		}
	}
	return tail
}
