package odawg_device

import base "../base"

// The samples a Sampler plays, as tables: sets (an instrument or a kit: its
// name and its zones), zones (which keys and velocities a sample answers, its
// root, its round-robin place), samples (a run of frames in a chunk), and the
// chunks: blocks of audio that never move once made, recordings as 16-bit
// PCM in their own channel count (a mono piano note stays mono: a quarter of
// float stereo), clips as float stereo. A load is one chunk sized exactly; a
// host's own audio is lent as a chunk (bank_borrow), not copied; another
// bank's rows can be viewed over the same chunks (bank_view). All at RATE. The assets layer fills it from the
// register (downloading a set the first time a song uses it); dsp only
// reads it. A `.Asset` param holds a set's index here.

Bank :: struct {
	sets:    [dynamic]Sample_Set,
	zones:   [dynamic]Zone, // declared with their sets; a zone's sample is -1 until loaded
	zone_file: [dynamic]i32, // parallel to zones: the loader's id of the file a zone plays
	samples: [dynamic]Sample,
	f32s:    [dynamic][]f32, // chunks of float samples, interleaved by their channels
	i16s:    [dynamic][]i16, // chunks of 16-bit samples, full scale 32768
	owned:   [dynamic]Chunk, // the chunks this bank made (and frees); the rest are lent or viewed
}

Sample_Format :: enum u8 {
	F32,
	I16,
}

Chunk :: struct {
	format: Sample_Format,
	index:  i32,
}

Sample_Set :: struct {
	name:  string, // "vcsl/upright_piano"
	zones: base.Span, // into zones
}

// Which keys of a set a song plays (the zones answering them are loaded).
Sample_Need :: struct {
	set:  i32,
	keys: bit_set[0 ..< 128;u128],
}

// A sample's place in its set: the keys and velocities it answers (MIDI,
// inclusive), the key it was recorded at, and its round-robin group and
// place (zones answering the same key and velocity alternate by `sequence`).
Zone :: struct {
	sample:      i32, // into samples
	lo_key:      u8,
	hi_key:      u8,
	root:        f32, // MIDI, fractional for a tuned recording
	lo_velocity: u8, // 0..127
	hi_velocity: u8,
	group:       u16, // round robin: zones of one group share keys and velocities
	sequence:    u16, // 0-based place in its group
	gain:        f32, // linear
	pan:         f32, // -1..1
	one_shot:    bool, // plays to its end whatever the gate (drums)
	loop_from:   i32, // frames into the sample; loop_to <= loop_from: no loop
	loop_to:     i32,
}

Sample :: struct {
	chunk:    i32, // into f32s or i16s, by format
	at:       i64, // its first value in the chunk
	frames:   i64,
	channels: u8, // 1 or 2
	format:   Sample_Format,
}

// A sample's values (interleaved by its channels).
sample_f32 :: proc(b: ^Bank, s: Sample) -> []f32 {return b.f32s[s.chunk][s.at:][:s.frames * i64(s.channels)]}

sample_i16 :: proc(b: ^Bank, s: Sample) -> []i16 {return b.i16s[s.chunk][s.at:][:s.frames * i64(s.channels)]}

// A new chunk of `n` 16-bit values the bank owns.
bank_chunk_i16 :: proc(b: ^Bank, n: int) -> (i32, []i16) {
	c := make([]i16, n, b.sets.allocator)
	append(&b.i16s, c)
	append(&b.owned, Chunk{.I16, i32(len(b.i16s) - 1)})
	return i32(len(b.i16s) - 1), c
}

bank_destroy :: proc(b: ^Bank) {
	for c in b.owned {
		switch c.format {
		case .F32:
			delete(b.f32s[c.index], b.sets.allocator)
		case .I16:
			delete(b.i16s[c.index], b.sets.allocator)
		}
	}
	delete(b.sets)
	delete(b.zones)
	delete(b.zone_file)
	delete(b.samples)
	delete(b.f32s)
	delete(b.i16s)
	delete(b.owned)
	b^ = {}
}

// Adds a set of one sample (a clip: stereo interleaved frames at RATE) lent
// by the host, not copied: its frames must outlive the bank's use. Returns
// the set's index.
bank_borrow :: proc(b: ^Bank, name: string, frames: []f32) -> i32 {
	append(&b.f32s, frames)
	append(&b.samples, Sample{chunk = i32(len(b.f32s) - 1), frames = i64(len(frames) / 2), channels = 2, format = .F32})
	append(&b.zones, Zone{sample = i32(len(b.samples) - 1), lo_key = 0, hi_key = 127, root = 60, lo_velocity = 0, hi_velocity = 127, gain = 1, one_shot = true})
	append(&b.zone_file, -1)
	append(&b.sets, Sample_Set{name = name, zones = {i32(len(b.zones) - 1), 1}})
	return i32(len(b.sets) - 1)
}

// Appends `src`'s sets to `dst` over the same chunks (its rows copied, its
// audio not): what one bank needs of another that outlives it. Returns the
// index `src`'s first set has in `dst`.
bank_view :: proc(dst, src: ^Bank) -> i32 {
	f0, i0 := i32(len(dst.f32s)), i32(len(dst.i16s))
	append(&dst.f32s, ..src.f32s[:])
	append(&dst.i16s, ..src.i16s[:])
	s0, z0, set0 := i32(len(dst.samples)), i32(len(dst.zones)), i32(len(dst.sets))
	for sm in src.samples {
		x := sm
		x.chunk += sm.format == .F32 ? f0 : i0
		append(&dst.samples, x)
	}
	for z, i in src.zones {
		x := z
		if x.sample >= 0 {
			x.sample += s0
		}
		append(&dst.zones, x)
		append(&dst.zone_file, src.zone_file[i])
	}
	for set in src.sets {
		append(&dst.sets, Sample_Set{set.name, {set.zones.first + z0, set.zones.count}})
	}
	return set0
}

bank_set_from_name :: proc(b: ^Bank, name: string) -> (i32, bool) {
	if b == nil {
		return -1, false
	}
	for s, i in b.sets {
		if s.name == name {
			return i32(i), true
		}
	}
	return -1, false
}
