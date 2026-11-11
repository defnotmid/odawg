package odawg_device

import "base:intrinsics"
import base "../base"
import dsp "../dsp"
import "core:math"
import "core:simd"

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
@(private = "file")
MAX_TAPS :: 2 * SINC_HALF * SINC_MAX_STRETCH

// Seconds a drum note may ring before its samples are loaded (then, their
// own length).
SAMPLER_ONE_SHOT_TAIL :: 8.0

// The shortest release, so a cut never clicks: 3 ms.
@(private = "file")
SAMPLER_DECLICK :: f64(dsp.DECLICK) / RATE

// One side of the kernel at SINC_STEPS points per tap (symmetric), zero for
// two taps past its edge, so a tap at the edge reads it without a check.
@(private = "package")
sinc_table: [(SINC_HALF + 2) * SINC_STEPS + 2]f32

// The unity kernel transposed by phase (SINC_STEPS + 1 rows of 32 contiguous
// taps) so cutoff 1 lerps four-wide vectors straight from two adjacent rows.
@(private = "file")
poly_sinc: [SINC_STEPS + 1][2 * SINC_HALF]f32

@(private = "file")
F32x4 :: #simd[4]f32
@(private = "file")
F32x8 :: #simd[8]f32
@(private = "file")
I32x4 :: #simd[4]i32

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
	for p in 0 ..= SINC_STEPS {
		for j in 0 ..< 2 * SINC_HALF {
			d := j - SINC_HALF + 1
			poly_sinc[p][j] = sinc_table[abs(p - d * SINC_STEPS)]
		}
	}
}

@(private = "file")
load4_f32 :: #force_inline proc "contextless" (ptr: ^$T) -> F32x4 {
	when T == f32 {
		return intrinsics.unaligned_load((^F32x4)(ptr))
	} else when T == i16 {
		return F32x4(intrinsics.unaligned_load((^#simd[4]i16)(ptr)))
	}
}

@(private = "file")
load8_f32 :: #force_inline proc "contextless" (ptr: ^$T) -> F32x8 {
	when T == f32 {
		return intrinsics.unaligned_load((^F32x8)(ptr))
	} else when T == i16 {
		return F32x8(intrinsics.unaligned_load((^#simd[8]i16)(ptr)))
	}
}

@(private = "file")
sinc_weights4 :: #force_inline proc "contextless" (xv: F32x4) -> F32x4 #no_bounds_check {
	ti := I32x4(xv)
	tf := xv - F32x4(ti)
	i0, i1 := simd.extract(ti, 0), simd.extract(ti, 1)
	i2, i3 := simd.extract(ti, 2), simd.extract(ti, 3)
	a := F32x4{sinc_table[i0], sinc_table[i1], sinc_table[i2], sinc_table[i3]}
	b := F32x4{sinc_table[i0 + 1], sinc_table[i1 + 1], sinc_table[i2 + 1], sinc_table[i3 + 1]}
	return a + (b - a) * tf
}

@(private = "file")
tail_weights4 :: #force_inline proc "contextless" (xv: F32x4, rem: int) -> F32x4 {
	w := sinc_weights4(simd.clamp(xv, F32x4(0), F32x4(SINC_HALF * SINC_STEPS)))
	return F32x4{simd.extract(w, 0), rem > 1 ? simd.extract(w, 1) : 0, rem > 2 ? simd.extract(w, 2) : 0, 0}
}

// Four taps of `samples` (`CH` 1 or 2) into `acc0` (mono) or `acc0` + `acc1` (stereo).
@(private = "file")
mac4 :: #force_inline proc "contextless" (samples: [^]$T, j: int, $CH: int, w: F32x4, acc0, acc1: ^F32x4) #no_bounds_check {
	when CH == 1 {
		acc0^ += load4_f32(&samples[j]) * w
	} else {
		s8 := load8_f32(&samples[2 * j])
		acc0^ += simd.swizzle(s8, 0, 1, 2, 3) * simd.swizzle(w, 0, 0, 1, 1)
		acc1^ += simd.swizzle(s8, 4, 5, 6, 7) * simd.swizzle(w, 2, 2, 3, 3)
	}
}

@(private = "file")
sum_taps :: #force_inline proc "contextless" (samples: [^]$T, $CH: int, f, cutoff: f32, t: int, gain: f32) -> (sl, sr: f32) #no_bounds_check {
	acc0, acc1: F32x4 = 0, 0
	if t == SINC_HALF && cutoff == 1 {
		s := f * SINC_STEPS
		p := min(int(s), SINC_STEPS - 1) // f rounds up to 1 within 2^-25 of it: row 512 at alpha 1
		alpha: F32x4 = s - f32(p)
		r0, r1 := &poly_sinc[p], &poly_sinc[p + 1]
		#unroll for k in 0 ..< (2 * SINC_HALF) / 4 {
			j := 4 * k
			w := intrinsics.unaligned_load((^F32x4)(&r0[j]))
			w += (intrinsics.unaligned_load((^F32x4)(&r1[j])) - w) * alpha
			mac4(samples, j, CH, w, &acc0, &acc1)
		}
	} else {
		f_v: F32x4 = f
		step_v: F32x4 = cutoff * SINC_STEPS
		four: F32x4 = 4
		rem := t & 3
		dv := F32x4{f32(1 - t), f32(2 - t), f32(3 - t), f32(4 - t)}
		for j := 0; j + 4 <= t; j += 4 {
			mac4(samples, j, CH, sinc_weights4((f_v - dv) * step_v), &acc0, &acc1)
			dv += four
		}
		if rem != 0 {
			mac4(samples, t - rem, CH, tail_weights4((f_v - dv) * step_v, rem), &acc0, &acc1)
		}
		dv = F32x4{1, 2, 3, 4}
		for j := t; j + 4 <= 2 * t; j += 4 {
			mac4(samples, j, CH, sinc_weights4((dv - f_v) * step_v), &acc0, &acc1)
			dv += four
		}
		if rem != 0 {
			mac4(samples, 2 * t - rem, CH, tail_weights4((dv - f_v) * step_v, rem), &acc0, &acc1)
		}
	}
	when CH == 1 {
		s := simd.reduce_add_bisect(acc0) * gain
		return s, s
	} else {
		s4 := acc0 + acc1
		return (simd.extract(s4, 0) + simd.extract(s4, 2)) * gain, (simd.extract(s4, 1) + simd.extract(s4, 3)) * gain
	}
}

@(private = "file")
read_frame_edge :: proc "contextless" (data: []$T, $CH: int, length, loop_from, loop_to, first: i64, span: int, f, cutoff: f32, t: int, gain: f32) -> (sl, sr: f32) {
	buf: [CH * MAX_TAPS]T = ---
	looped := loop_to > loop_from
	n := 2 * t
	#no_bounds_check for j in 0 ..< span {
		fi := first + i64(j)
		if looped && fi >= loop_to {
			fi = loop_from + (fi - loop_from) % (loop_to - loop_from)
		}
		if j < n && fi >= 0 && fi < length {
			buf[CH * j] = data[i64(CH) * fi]
			when CH == 2 {
				buf[2 * j + 1] = data[2 * fi + 1]
			}
		} else {
			buf[CH * j] = 0
			when CH == 2 {
				buf[2 * j + 1] = 0
			}
		}
	}
	return sum_taps(&buf[0], CH, f, cutoff, t, gain)
}

@(private = "file")
read_frame_ch :: #force_inline proc "contextless" (data: []$T, $CH: int, length, loop_from, loop_to: i64, pos: f64, cutoff: f32, taps: i64, gain: f32, exact: bool) -> (sl, sr: f32) {
	centre := i64(pos) // pos >= 0: truncation floors it
	frac := pos - f64(centre)
	if exact && frac == 0 && centre < length {
		s0 := f32(data[i64(CH) * centre]) * gain
		when CH == 1 {
			return s0, s0
		} else {
			return s0, f32(data[2 * centre + 1]) * gain
		}
	}
	t := int(taps)
	rem := t & 3
	span := rem == 0 ? 2 * t : 2 * t + 4 - rem
	first := centre - taps + 1
	limit := loop_to > loop_from ? loop_to : length
	if first >= 0 && first + i64(span) <= limit {
		return sum_taps(raw_data(data)[i64(CH) * first:], CH, f32(frac), cutoff, t, gain)
	}
	return read_frame_edge(data, CH, length, loop_from, loop_to, first, span, f32(frac), cutoff, t, gain)
}

// Both sides of interleaved `data` (`channels` 1 or 2; `length` frames) at
// frame `pos` (fractional, >= 0) through the kernel at `cutoff` (relative to
// the sample's Nyquist; `taps` on each side), times `gain` (cutoff times the
// scale): its own frame where `exact` (a whole pos read at its own rate),
// else every tap; a loop's taps past its end wrapped (loop_to > loop_from),
// taps outside the sample silent. The Sampler's, a Region's and a clip at a
// rate read so.
@(private = "package")
read_frame :: #force_inline proc "contextless" (data: []$T, channels: int, length, loop_from, loop_to: i64, pos: f64, cutoff: f32, taps: i64, gain: f32, exact: bool) -> (sl, sr: f32) {
	if pos < 0 {
		return
	}
	if channels == 1 {
		return read_frame_ch(data, 1, length, loop_from, loop_to, pos, cutoff, taps, gain, exact)
	}
	return read_frame_ch(data, 2, length, loop_from, loop_to, pos, cutoff, taps, gain, exact)
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
	env:       dsp.Adsr, // its level: Tone's envelope, its attack, held at 1, its release
	gate:      i64, // the sample the release starts at (-1: a one-shot)
	over:      i64, // the sample from which it is silent for good (-1: its sample's end)
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
zone_for :: proc(bank: ^Bank, set: Set_Id, key, velocity: int, seed: u64) -> i32 {
	row := bank_set_row(bank, set)
	if row < 0 {
		return -1
	}
	span := bank.sets[row].zones
	best_key, best_vel, count := zone_nearest(bank, row, key, velocity)
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

// How near the zones of the set at `row` nearest a note come (keys, then
// velocities away), and how many are that near: the ones zone_for picks among.
zone_nearest :: proc(bank: ^Bank, row: int, key, velocity: int) -> (best_key, best_vel, count: int) {
	best_key, best_vel = max(int), max(int)
	span := bank.sets[row].zones
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
sampler_start :: proc(st: ^Sampler_State, set: Set_Id, attack, release: f32, key: f32, n: Note, seed: u64, env: ^Voice_Env) {
	st.zone = -1
	if env == nil || env.bank == nil {
		return
	}
	bank := env.bank
	pitch := n.pitch > 0 ? f32(n.pitch) : key
	velocity := velocity_midi(n.velocity)
	zi := zone_for(bank, set, int(math.round(key)), velocity, seed)
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
	// the pitch shift (its frames are at RATE)
	st.step = math.pow(2, f64(pitch - z.root) / 12)
	st.cutoff = clamp(1 / st.step, 1.0 / SINC_MAX_STRETCH, 1)
	st.taps = int(math.ceil(SINC_HALF / st.cutoff))
	amp := z.gain * min(f32(velocity) / f32(max(z.hi_velocity, 1)), 1)
	st.gain_l = amp * (z.pan > 0 ? 1 - z.pan : 1)
	st.gain_r = amp * (z.pan < 0 ? 1 + z.pan : 1)
	rel := max(z.release > 0 ? f64(z.release) : f64(release), SAMPLER_DECLICK)
	st.env = {attack = max(attack, 0), sustain = 1, release = f32(rel)}
	dsp.adsr_init(&st.env)
	st.gate = z.one_shot ? -1 : gate_sample(n)
	st.over = st.gate >= 0 ? st.gate + i64(math.ceil(rel * RATE)) : -1
}

// The note's next len(l) samples, written into l and r (silence where it is
// over); false once it is over.
sampler_play :: proc(st: ^Sampler_State, at: i64, env: ^Voice_Env, l, r: []f32) -> bool {
	if st.zone < 0 || env == nil || env.bank == nil {
		slice_zero(l)
		slice_zero(r)
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
// sums in f32 (read_frame). Where it reads is a function of the output
// sample's index alone; its level is its envelope's, run in order (a seek
// chases a Sampler's notes from their start).
@(private = "file")
sampler_run :: proc(st: ^Sampler_State, data: []$T, channels: int, scale: f32, at: i64, l, r: []f32) -> bool {
	looped := st.loop_to > st.loop_from
	loop_len := st.loop_to - st.loop_from
	m := min(len(l), len(r))
	cutoff := f32(st.cutoff) * scale
	taps := i64(st.taps)
	c := f32(st.cutoff)
	levels: [NODE_CHUNK]f32 = ---
	for i in 0 ..< m {
		k := at + i64(i)
		if st.over >= 0 && k >= st.over {
			slice_zero(l[i:m])
			slice_zero(r[i:m])
			return false
		}
		// its levels a chunk at a time, the gate closing where it falls
		if i % NODE_CHUNK == 0 {
			n := min(NODE_CHUNK, m - i)
			release_at := st.gate >= k && st.gate < k + i64(n) ? int(st.gate - k) : -1
			dsp.adsr_run(&st.env, levels[:n], release_at)
		}
		level := levels[i % NODE_CHUNK]
		pos := f64(st.offset) + f64(k) * st.step
		if looped && pos >= f64(st.loop_to) {
			pos = f64(st.loop_from) + math.mod(pos - f64(st.loop_from), f64(loop_len))
		}
		if !looped && pos >= f64(st.length) + f64(st.taps) {
			slice_zero(l[i:m])
			slice_zero(r[i:m])
			return false
		}
		sl, sr := read_frame(data, channels, st.length, st.loop_from, st.loop_to, pos, c, taps, cutoff, st.step == 1)
		l[i] = sl * st.gain_l * level
		r[i] = sr * st.gain_r * level
	}
	return true
}

// What the zones the note can play make of it (of a round robin, the
// longest): a one-shot to its sample's end, a held note its gate and
// release, cut short by its sample's end unless it loops. Before the
// samples are loaded: a drum note SAMPLER_ONE_SHOT_TAIL, a held one its
// gate and release.
tail_sampler :: proc(set: Set_Id, release: f32, key: f32, n: Note, env: ^Voice_Env) -> base.Seconds {
	held := f64(max(n.duration, 0)) + max(f64(release), SAMPLER_DECLICK)
	guess := n.pad != 0 ? SAMPLER_ONE_SHOT_TAIL : held
	if env == nil || env.bank == nil {
		return base.Seconds(guess)
	}
	row := bank_set_row(env.bank, set)
	if row < 0 {
		return base.Seconds(guess)
	}
	bank := env.bank
	pitch := n.pitch > 0 ? f32(n.pitch) : key
	k, velocity := int(math.round(key)), velocity_midi(n.velocity)
	best_key, best_vel, _ := zone_nearest(bank, row, k, velocity)
	span := bank.sets[row].zones
	tail := 0.0
	for i in span.first ..< base.span_end(span) {
		z := &bank.zones[i]
		if range_distance(k, int(z.lo_key), int(z.hi_key)) != best_key || range_distance(velocity, int(z.lo_velocity), int(z.hi_velocity)) != best_vel {
			continue
		}
		if z.sample < 0 || int(z.sample) >= len(bank.samples) {
			return base.Seconds(guess)
		}
		sm := bank.samples[z.sample]
		step := math.pow(2, f64(pitch - z.root) / 12)
		held := z.release > 0 ? f64(max(n.duration, 0)) + max(f64(z.release), SAMPLER_DECLICK) : held
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
	return base.Seconds(tail)
}

// ---- Region: one zone of a set, as an SFZ region plays it --------------------------

// A zone (one of its set's, by index) played from `offset` (plus up to
// `offset_random` frames, by the note's seed) at the note's key: shifted
// from `keycenter` by `keytrack` cents a key and `tune` cents, and by `rate`
// (what moves the pitch: a pitch envelope, an LFO, a factor); it plays to
// `end` (0: the sample's), loops as `loop_mode` says (default: the zone's
// own loop, if it has one), starts after `delay`, and spreads its two sides
// by `width` (percent: 100 as recorded, 0 mono). Read through the same
// Kaiser-windowed sinc as the Sampler. While nothing moves its rate, every
// sample is a function of its index alone (a seek may start it anywhere).

REGION_SET :: 3
REGION_ZONE :: 4
REGION_KEYCENTER :: 5
REGION_KEYTRACK :: 6
REGION_TUNE :: 7
REGION_RATE :: 8
REGION_OFFSET :: 9
REGION_OFFSET_RANDOM :: 10
REGION_END :: 11
REGION_LOOP_MODE :: 12
REGION_LOOP_START :: 13
REGION_LOOP_END :: 14
REGION_DELAY :: 15
REGION_WIDTH :: 16

// SFZ's loop modes as rows: whether a region takes its zone's loop (the
// file's), whether its own loop_start and loop_end apply, whether it loops
// only while the note is held.
Loop_Mode :: enum u8 {
	Default,
	No_Loop,
	One_Shot,
	Continuous,
	Sustain,
}

Loop_Mode_Row :: struct {
	name:      string,
	zone_loop: bool,
	points:    bool,
	sustain:   bool,
}

LOOP_MODES := [Loop_Mode]Loop_Mode_Row {
	.Default    = {"default", true, false, false},
	.No_Loop    = {"no_loop", false, false, false},
	.One_Shot   = {"one_shot", false, false, false},
	.Continuous = {"loop_continuous", true, true, false},
	.Sustain    = {"loop_sustain", true, true, true},
}

REGION_LOOP_MODES := []string{LOOP_MODES[.Default].name, LOOP_MODES[.No_Loop].name, LOOP_MODES[.One_Shot].name, LOOP_MODES[.Continuous].name, LOOP_MODES[.Sustain].name}

// A loop mode by its SFZ name.
loop_mode_from_name :: proc(name: string) -> (Loop_Mode, bool) {
	for row, m in LOOP_MODES {
		if row.name == name {
			return m, true
		}
	}
	return .Default, false
}

Region_State :: struct {
	zone:      i32, // into the bank's zones (-1: nothing to play)
	length:    i64, // frames it plays to
	loop_from: i64,
	loop_to:   i64, // <= loop_from: no loop
	sustain:   bool, // it loops only while its note is held
	start:     f64, // the frame it starts at
	pos:       f64, // where it is (a moving rate: the sum of its steps)
	step:      f64, // frames per output sample at rate 1
	cutoff:    f64,
	taps:      int,
	delay:     i64, // samples
	width:     f32,
	over:      bool,
}

#assert(size_of(Region_State) <= VOICE_STATE_SIZE)

@(private = "package")
region_start :: proc(c: ^Node_Call, lane: ^Lane, st: ^Region_State) {
	st^ = {zone = -1}
	v := node_values(c, lane)
	env := c.env
	if env == nil || env.bank == nil {
		return
	}
	bank := env.bank
	row := bank_set_row(bank, Set_Id(v[REGION_SET]))
	if row < 0 {
		return
	}
	zs := bank.sets[row].zones
	zi := zs.first + i32(v[REGION_ZONE])
	if v[REGION_ZONE] < 0 || zi >= base.span_end(zs) {
		return
	}
	z := &bank.zones[zi]
	if z.sample < 0 || int(z.sample) >= len(bank.samples) {
		return
	}
	sm := bank.samples[z.sample]
	st.zone = zi
	st.length = sm.frames
	// its frames as SFZ gives them: the recording's, in the sample's at RATE
	frames :: proc(sm: Sample, x: f32) -> i64 {return i64(math.round(sample_frames(sm, f64(x))))}
	if v[REGION_END] > 0 {
		st.length = min(st.length, frames(sm, v[REGION_END] + 1))
	}
	mode := LOOP_MODES[Loop_Mode(clamp(int(v[REGION_LOOP_MODE]), 0, len(Loop_Mode) - 1))]
	if mode.zone_loop {
		st.loop_from, st.loop_to = i64(z.loop_from), i64(z.loop_to)
	}
	st.sustain = mode.sustain
	if mode.points && v[REGION_LOOP_START] >= 0 {
		st.loop_from = frames(sm, v[REGION_LOOP_START])
	}
	if mode.points && v[REGION_LOOP_END] > 0 {
		st.loop_to = frames(sm, v[REGION_LOOP_END] + 1)
	}
	if st.loop_to > st.length || st.loop_to - st.loop_from < 2 {
		st.loop_to = st.loop_from
	}
	random := len(lane.bufs) == 0 ? min(f64(v[REGION_OFFSET_RANDOM]), 0) : f64(v[REGION_OFFSET_RANDOM]) * base.hash_unit(lane.seed ~ 0x0ff5e7)
	st.start = max(sample_frames(sm, f64(node_value(c, lane, REGION_OFFSET)) + math.floor(random)), 0)
	st.pos = st.start
	cents := (f64(lane.key) - f64(v[REGION_KEYCENTER])) * f64(v[REGION_KEYTRACK]) + f64(node_value(c, lane, REGION_TUNE))
	st.step = math.pow(2, cents / 1200)
	st.cutoff = clamp(1 / st.step, 1.0 / SINC_MAX_STRETCH, 1)
	st.taps = int(math.ceil(SINC_HALF / st.cutoff))
	st.delay = i64(math.round(f64(max(node_value(c, lane, REGION_DELAY), 0)) * RATE))
	st.width = v[REGION_WIDTH] / 100
}

// A note starting: its region's zone and read head.
@(private = "package")
start_region :: proc(c: ^Node_Call, lane: ^Lane) {
	region_start(c, lane, node_state(c, lane, Region_State))
}

@(private = "package")
process_region :: proc(c: ^Node_Call) {
	n := c.frames
	for &lane in c.lanes {
		st := node_state(c, &lane, Region_State)
		l, r := node_out(c, &lane)
		slice_zero(l)
		slice_zero(r)
		if st.zone < 0 || st.over || c.env == nil || c.env.bank == nil {
			continue
		}
		rate: [NODE_CHUNK]f32
		varies, factor := node_curve(c, &lane, REGION_RATE, node_values(c, &lane)[REGION_RATE], rate[:n])
		bank := c.env.bank
		sm := bank.samples[bank.zones[st.zone].sample]
		switch sm.format {
		case .F32:
			region_run(st, &lane, sample_f32(bank, sm), int(sm.channels), 1, varies, factor, rate[:n], l, r)
		case .I16:
			region_run(st, &lane, sample_i16(bank, sm), int(sm.channels), 1.0 / 32768, varies, factor, rate[:n], l, r)
		}
	}
}

@(private = "file")
region_run :: proc(st: ^Region_State, lane: ^Lane, data: []$T, channels: int, scale: f32, varies: bool, factor: f32, rate: []f32, l, r: []f32) {
	taps := i64(st.taps)
	c := f32(st.cutoff)
	cutoff := f32(st.cutoff) * scale
	width := dsp.mid_side(1, st.width)
	for i in 0 ..< len(l) {
		k := lane.at + i64(i) - st.delay
		if k < 0 {
			continue
		}
		looped := st.loop_to > st.loop_from && (!st.sustain || lane.at + i64(i) < lane.gate)
		pos: f64
		if varies {
			pos = st.pos
		} else if !looped && st.sustain && st.loop_to > st.loop_from {
			k_gate := max(lane.gate - st.delay, 0)
			pos = st.start + f64(k_gate) * st.step * f64(factor)
			if pos >= f64(st.loop_to) {
				pos = f64(st.loop_from) + math.mod(pos - f64(st.loop_from), f64(st.loop_to - st.loop_from))
			}
			pos += f64(k - k_gate) * st.step * f64(factor)
		} else {
			pos = st.start + f64(k) * st.step * f64(factor)
		}
		if looped && pos >= f64(st.loop_to) {
			pos = f64(st.loop_from) + math.mod(pos - f64(st.loop_from), f64(st.loop_to - st.loop_from))
		}
		if varies {
			st.pos = pos + st.step * f64(rate[i])
		}
		if pos < -f64(taps) || pos >= f64(st.length) + f64(taps) {
			st.over = true
			return
		}
		loop_to := looped ? st.loop_to : st.loop_from // its loop only while it loops
		sl, sr := read_frame(data, channels, st.length, st.loop_from, loop_to, pos, c, taps, cutoff, st.step * f64(varies ? rate[i] : factor) == 1)
		if st.width != 1 {
			v := width * [2]f32{sl, sr}
			sl, sr = v[0], v[1]
		}
		l[i], r[i] = sl, sr
	}
}

// Seconds it sounds from the note's start: to its sample's end at its
// pitch (INF: it loops, so its note's envelope ends it).
@(private = "package")
tail_region :: proc(c: ^Node_Call, lane: ^Lane) -> base.Seconds {
	st: Region_State
	region_start(c, lane, &st)
	if st.zone < 0 {
		return 0
	}
	if st.loop_to > st.loop_from {
		return base.Seconds(math.INF_F64)
	}
	return base.Seconds((f64(st.length) - st.start) / st.step / RATE + f64(st.delay) / RATE)
}
