// base: what every odawg layer shares: the rate, units, hashing and the
// seeded generator every random choice comes from, and findings (what the
// reader and the checks report). Nothing here knows music.
package odawg_base


import "core:math"

// Bumped whenever the samples for the same spec change: a host's render
// cache keys on it (like ottis's pocket.VERSION).
VERSION :: 2

// The rate everything renders at (onimite's mix rate).
RATE :: 48000

TAU :: 2 * math.PI

db_to_gain :: proc "contextless" (db: f64) -> f64 {return math.pow(10, db / 20)}

gain_to_db :: proc "contextless" (g: f64) -> f64 {
	return g > 0 ? 20 * math.log10(g) : -math.INF_F64
}

// Hz for a MIDI note number (fractional numbers are between semitones).
midi_to_hz :: proc "contextless" (n: f64) -> f64 {return 440 * math.pow(2, (n - 69) / 12)}

// A 64-bit mix (splitmix64's finalizer): every random choice comes from
// hashing what it is about, so nothing depends on the order things render in.
hash64 :: proc "contextless" (x: u64) -> u64 {
	z := x + 0x9e3779b97f4a7c15
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

hash_combine :: proc "contextless" (a, b: u64) -> u64 {return hash64(a ~ (b * 0x9e3779b97f4a7c15))}

hash_string :: proc "contextless" (s: string) -> u64 {
	h: u64 = 0xcbf29ce484222325 // FNV-1a
	for i in 0 ..< len(s) {
		h = (h ~ u64(s[i])) * 0x100000001b3
	}
	return h
}

// A name's id: its hash (0: none), the same in every song (a pad's, a
// node's, a control's).
name_id :: proc "contextless" (name: string) -> u32 {
	if name == "" {
		return 0
	}
	h := u32(hash_string(name))
	return h == 0 ? 1 : h
}

// 0..1 from a hash.
hash_unit :: proc "contextless" (x: u64) -> f64 {return f64(hash64(x) >> 11) / f64(u64(1) << 53)}

// A seeded generator for noise inside one note (xorshift64*): seed it from
// the note's hash, draw as many values as the note needs.
Rng :: struct {
	state: u64,
}

rng_init :: proc "contextless" (seed: u64) -> Rng {
	s := hash64(seed)
	return {s == 0 ? 0x2545f4914f6cdd1d : s}
}

rng_next :: proc "contextless" (r: ^Rng) -> u64 {
	x := r.state
	x ~= x >> 12
	x ~= x << 25
	x ~= x >> 27
	r.state = x
	return x * 0x2545f4914f6cdd1d
}

// Uniform in -1..1 (white noise).
rng_noise :: proc "contextless" (r: ^Rng) -> f32 {
	return f32(f64(rng_next(r) >> 11) / f64(u64(1) << 52) - 1)
}

// Uniform in 0..1.
rng_unit :: proc "contextless" (r: ^Rng) -> f64 {return f64(rng_next(r) >> 11) / f64(u64(1) << 53)}

// A run of rows in another table: a record names its children by where they
// start and how many there are, never by pointer.
Span :: struct {
	first, count: i32,
}

span_end :: proc "contextless" (s: Span) -> i32 {return s.first + s.count}

// An optional number left out: NaN (math.is_nan tells).
UNSET :: f64(0h7ff8000000000000)
