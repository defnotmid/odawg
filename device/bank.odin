package odawg_device

import "core:slice"
import "core:sync"
import base "../base"

// The samples a Sampler plays, as tables: sets (an instrument or a kit: its
// name and its zones), zones (which keys and velocities a sample answers, its
// root, its round-robin place), samples (a run of frames in a chunk), and the
// chunks: blocks of audio that never move once made, recordings as 16-bit
// PCM in their own channel count (a mono piano note stays mono: a quarter of
// float stereo) at the rate they were recorded (a Sampler reads them at
// RATE), clips as float stereo at RATE. A file loaded is a chunk sized
// exactly; a host's own audio is lent as a chunk (bank_borrow), not copied;
// another bank's rows can be viewed over the same chunks (bank_view). The assets layer fills it from the
// register (downloading a set the first time a song uses it); dsp only
// reads it. A node's `.Asset` field holds a set's id.

// A set, whatever row it is at, in its bank and any bank viewing it. An id is
// never used twice in a process, so what outlives its set finds nothing, not
// another set's samples. 0: no set. Rows stay in id order (bank_set_row).
Set_Id :: distinct u32

// Ids sit in programs' values, which are f32s: exact to here. That is 16
// million sets declared or lent in one run.
@(private = "file")
SET_ID_END :: 1 << 24

@(private = "file")
set_id_last: u32

@(private = "file")
set_id_next :: proc() -> Set_Id {
	id := sync.atomic_add(&set_id_last, 1) + 1
	assert(id < SET_ID_END, "odawg: sample set ids ran out")
	return Set_Id(id)
}

// The row of set `id` in `b`: -1 where `b` doesn't have it.
bank_set_row :: proc "contextless" (b: ^Bank, id: Set_Id) -> int {
	if b == nil || id == 0 {
		return -1
	}
	lo, hi := 0, len(b.sets)
	for lo < hi {
		mid := (lo + hi) / 2
		if b.sets[mid].id < id {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo < len(b.sets) && b.sets[lo].id == id ? lo : -1
}

// A new set over zones already appended: its row, at a new id.
bank_set_append :: proc(b: ^Bank, name: string, zones: base.Span, stamp: u64 = 0) -> Set_Id {
	id := set_id_next()
	append(&b.sets, Sample_Set{id = id, name = name, zones = zones, stamp = stamp})
	return id
}

Bank :: struct {
	sets:    [dynamic]Sample_Set,
	zones:   [dynamic]Zone, // declared with their sets; a zone's sample is -1 until loaded
	zone_file: [dynamic]i32, // parallel to zones: the file a zone plays, into files (-1: none, a lent sample)
	files:   [dynamic]Bank_File, // the files its zones play, once each
	samples: [dynamic]Sample,
	f32s:    [dynamic][]f32, // chunks of float samples, interleaved by their channels
	i16s:    [dynamic][]i16, // chunks of 16-bit samples, full scale 32768
	owned:   [dynamic]Chunk, // the chunks this bank made (and frees); the rest are lent or viewed
	text:    [dynamic]string, // the names and paths it cloned (a register set's name is the register's)
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
	id:    Set_Id,
	name:  string, // "vcsl/upright_piano", an inline set's "my_kit#9f3c…", an SFZ's path
	zones: base.Span, // into zones
	stamp: u64, // its files' contents when declared (a changed file declares it again)
}

// A file a set plays: one of the register's (pinned, fetched on first use),
// one of a song's sources' (fetched from `url` into the data directory at
// `path`, pinned by `sha256` and `size`), or a host's own, by its path as
// the spec wrote it (relative to the host's root), with what its content
// was when declared.
Bank_File :: struct {
	register: i32, // into the register's files (-1: a source's or the host's)
	path:     string,
	stamp:    u64,
	url:      string, // a source's file: where it is fetched from ("": the host's)
	sha256:   string, // its pin ("": not pinned yet, fetched only by odawg pin)
	size:     i64,
}

// Which keys of a set a song plays, and at which velocities (MIDI) each:
// the zones a Sampler would pick for them are loaded (a key without
// velocities: at any).
Sample_Need :: struct {
	set:        Set_Id,
	keys:       bit_set[0 ..< 128;u128],
	velocities: [128]bit_set[0 ..< 128;u128], // by key
	zones:      [dynamic]i32, // zones (of the set's, by index) played as such (an SFZ region's Region)
}

// A zone's loop_to before loading: take the file's loop (a WAV's smpl).
LOOP_FROM_FILE :: -2

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
	loop_to:     i32, // declared: LOOP_FROM_FILE (the loader takes the file's), else as given
	offset:      i32, // frames into the sample a note starts at
	release:     f32, // seconds its notes take to fade (0: the Sampler's .Release)
}

Sample :: struct {
	chunk:    i32, // into f32s or i16s, by format
	at:       i64, // its first value in the chunk
	frames:   i64,
	channels: u8, // 1 or 2
	format:   Sample_Format,
	rate:     i32, // its recording's frames per second (0: RATE); its own frames are at RATE, resampled as it was loaded
}

// A position given in a sample's recording's frames (an SFZ region's offset,
// end and loop points), in its own frames at RATE.
sample_frames :: #force_inline proc "contextless" (s: Sample, recorded: f64) -> f64 {
	return s.rate > 0 && s.rate != RATE ? recorded * RATE / f64(s.rate) : recorded
}

// A sample's values (interleaved by its channels).
sample_f32 :: proc(b: ^Bank, s: Sample) -> []f32 {return b.f32s[s.chunk][s.at:][:s.frames * i64(s.channels)]}

sample_i16 :: proc(b: ^Bank, s: Sample) -> []i16 {return b.i16s[s.chunk][s.at:][:s.frames * i64(s.channels)]}

// `values` as a chunk the bank owns: made with its allocator (b.sets's), and
// freed with it.
bank_chunk_i16 :: proc(b: ^Bank, values: []i16) -> i32 {
	append(&b.i16s, values)
	append(&b.owned, Chunk{.I16, i32(len(b.i16s) - 1)})
	return i32(len(b.i16s) - 1)
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
	delete(b.files)
	for s in b.text {
		delete(s, b.sets.allocator)
	}
	delete(b.text)
	delete(b.samples)
	delete(b.f32s)
	delete(b.i16s)
	delete(b.owned)
	b^ = {}
}

// Adds a set of one sample (a clip: stereo interleaved frames at RATE) lent
// by the host, not copied: its frames must outlive the bank's use. Float
// frames, or 16-bit ones as they are (a host's render of a song, full scale
// 32768). Returns the set.
bank_borrow :: proc(b: ^Bank, name: string, frames: []$T) -> Set_Id where T == f32 || T == i16 {
	when T == f32 {
		append(&b.f32s, frames)
		chunk, format := len(b.f32s) - 1, Sample_Format.F32
	} else {
		append(&b.i16s, frames)
		chunk, format := len(b.i16s) - 1, Sample_Format.I16
	}
	return borrowed_set(b, name, Sample{chunk = i32(chunk), frames = i64(len(frames) / 2), channels = 2, format = format})
}

// A lent sample's rows: the sample, one zone over every key, its set.
@(private = "file")
borrowed_set :: proc(b: ^Bank, name: string, sm: Sample) -> Set_Id {
	append(&b.samples, sm)
	append(&b.zones, Zone{sample = i32(len(b.samples) - 1), lo_key = 0, hi_key = 127, root = 60, lo_velocity = 0, hi_velocity = 127, gain = 1, one_shot = true})
	append(&b.zone_file, -1)
	return bank_set_append(b, name, {i32(len(b.zones) - 1), 1})
}

// Appends `src`'s sets to `dst` over the same chunks (its rows copied, its
// audio not): what one bank needs of another that outlives it. They keep
// their ids, so what names them plays them from either bank.
bank_view :: proc(dst, src: ^Bank) {
	f0, i0 := i32(len(dst.f32s)), i32(len(dst.i16s))
	append(&dst.f32s, ..src.f32s[:])
	append(&dst.i16s, ..src.i16s[:])
	s0, z0, file0 := i32(len(dst.samples)), i32(len(dst.zones)), i32(len(dst.files))
	append(&dst.files, ..src.files[:])
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
		f := src.zone_file[i]
		append(&dst.zone_file, f >= 0 ? f + file0 : f)
	}
	for set in src.sets {
		append(&dst.sets, Sample_Set{set.id, set.name, {set.zones.first + z0, set.zones.count}, set.stamp})
	}
	slice.stable_sort_by(dst.sets[:], proc(a, b: Sample_Set) -> bool {return a.id < b.id})
}

// The set named `name`, its newest declaration (a set declared again when
// its files changed: earlier songs keep the one they were composed with).
bank_set_from_name :: proc(b: ^Bank, name: string) -> (Set_Id, bool) {
	if b == nil {
		return 0, false
	}
	#reverse for s in b.sets {
		if s.name == name {
			return s.id, true
		}
	}
	return 0, false
}

// Moves the rows marked in `to` down, in order; each mark becomes its new
// row + 1.
@(private = "file")
rows_compact :: proc(rows: ^[dynamic]$T, to: []i32) {
	kept := 0
	for x, i in rows^ {
		if to[i] != 0 {
			rows^[kept] = x
			kept += 1
			to[i] = i32(kept)
		}
	}
	resize(rows, kept)
}

// Drops every set `keep` doesn't name, and what only those played: zones,
// files, samples, text, and the chunks the bank owns (a chunk lent to it
// stays the host's). Rows move and ids don't. What a declared-again set's old
// songs named goes once no song names it (song.sets_of_song gathers what to
// keep). Call it where nothing reads the bank; a bank viewing this one reads
// these chunks, so what it plays must be kept too, or the view made again.
// Returns how many sets went.
bank_collect :: proc(b: ^Bank, keep: []Set_Id) -> (dropped: int) {
	sets := make([dynamic]Sample_Set, 0, len(b.sets), context.temp_allocator)
	zones := make([dynamic]Zone, 0, len(b.zones), context.temp_allocator)
	zone_file := make([dynamic]i32, 0, len(b.zones), context.temp_allocator)
	// what the kept zones reach: each old row's new one, 0 unreached and
	// row + 1 after
	sample_to := make([]i32, len(b.samples), context.temp_allocator)
	file_to := make([]i32, len(b.files), context.temp_allocator)
	for set in b.sets {
		if !slice.contains(keep, set.id) {
			dropped += 1
			continue
		}
		x := set
		x.zones.first = i32(len(zones))
		append(&sets, x)
		for zi in set.zones.first ..< base.span_end(set.zones) {
			append(&zones, b.zones[zi])
			append(&zone_file, b.zone_file[zi])
			if s := b.zones[zi].sample; s >= 0 {
				sample_to[s] = 1
			}
			if f := b.zone_file[zi]; f >= 0 {
				file_to[f] = 1
			}
		}
	}
	if dropped == 0 {
		return
	}
	// the chunks the kept samples read: the rest are freed where they are
	// the bank's, then every table's kept rows move down
	chunk_to := [Sample_Format][]i32 {
		.F32 = make([]i32, len(b.f32s), context.temp_allocator),
		.I16 = make([]i32, len(b.i16s), context.temp_allocator),
	}
	for sm, i in b.samples {
		if sample_to[i] != 0 {
			chunk_to[sm.format][sm.chunk] = 1
		}
	}
	#reverse for c, i in b.owned {
		if chunk_to[c.format][c.index] != 0 {
			continue
		}
		switch c.format {
		case .F32:
			delete(b.f32s[c.index], b.sets.allocator)
		case .I16:
			delete(b.i16s[c.index], b.sets.allocator)
		}
		unordered_remove(&b.owned, i)
	}
	rows_compact(&b.samples, sample_to)
	rows_compact(&b.f32s, chunk_to[.F32])
	rows_compact(&b.i16s, chunk_to[.I16])
	rows_compact(&b.files, file_to)
	for &sm in b.samples {
		sm.chunk = chunk_to[sm.format][sm.chunk] - 1
	}
	for &c in b.owned {
		c.index = chunk_to[c.format][c.index] - 1
	}
	for &z in zones {
		if z.sample >= 0 {
			z.sample = sample_to[z.sample] - 1
		}
	}
	for &f in zone_file {
		if f >= 0 {
			f = file_to[f] - 1
		}
	}
	resize(&b.sets, len(sets))
	copy(b.sets[:], sets[:])
	resize(&b.zones, len(zones))
	copy(b.zones[:], zones[:])
	resize(&b.zone_file, len(zone_file))
	copy(b.zone_file[:], zone_file[:])
	// the text no kept row names (a register set's name is the register's)
	named := make(map[rawptr]bool, 2 * (len(b.sets) + len(b.files)), context.temp_allocator)
	for set in b.sets {
		named[raw_data(set.name)] = true
	}
	for f in b.files {
		named[raw_data(f.path)], named[raw_data(f.url)], named[raw_data(f.sha256)] = true, true, true
	}
	#reverse for s, i in b.text {
		if !named[raw_data(s)] {
			delete(s, b.sets.allocator)
			unordered_remove(&b.text, i)
		}
	}
	return
}
