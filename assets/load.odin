package odawg_assets

import base "../base"
import device "../device"
import "core:encoding/endian"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:strings"

// Loading: a set's files decoded (WAV here, FLAC by odecs: a row per
// extension), made
// stereo, resampled to device.RATE through a Kaiser-windowed sinc and appended
// to a device.Bank (frames to its slab, a sample row each, a zone row per
// register zone, the set's row naming them).

// A decoded file: interleaved samples, its rate, and its loop (frames;
// loop_to <= loop_from: none).
Decoded :: struct {
	samples:   []f32,
	channels:  int,
	rate:      int,
	loop_from: i64,
	loop_to:   i64,
}

Decode_Proc :: #type proc(data: []u8, allocator := context.allocator) -> (Decoded, Error)
// What a file holds, from its header alone: to size the bank before decoding.
Info_Proc :: #type proc(data: []u8) -> (frames, channels, rate: int, ok: bool)

// The decoder for a file, by its extension: a row each.
Format_Row :: struct {
	extension: string,
	decode:    Decode_Proc,
	info:      Info_Proc,
}

FORMAT_TABLE := []Format_Row{{".wav", wav_decode, wav_info}, {".flac", flac_decode, flac_info}}

format_from_path :: proc(path: string) -> (^Format_Row, bool) {
	for &f in FORMAT_TABLE {
		if strings.has_suffix(strings.to_lower(path, context.temp_allocator), f.extension) {
			return &f, true
		}
	}
	return nil, false
}

wav_info :: proc(data: []u8) -> (frames, channels, rate: int, ok: bool) {
	if len(data) < 12 || string(data[:4]) != "RIFF" || string(data[8:12]) != "WAVE" {
		return
	}
	align, size := 0, -1
	for pos := 12; pos + 8 <= len(data); {
		id := string(data[pos:pos + 4])
		n := int(endian.unchecked_get_u32le(data[pos + 4:]))
		chunk := data[pos + 8:min(pos + 8 + n, len(data))]
		switch id {
		case "fmt ":
			if len(chunk) >= 16 {
				channels = int(endian.unchecked_get_u16le(chunk[2:]))
				rate = int(endian.unchecked_get_u32le(chunk[4:]))
				align = max(int(endian.unchecked_get_u16le(chunk[12:])), int(endian.unchecked_get_u16le(chunk[14:])) / 8 * channels)
			}
		case "data":
			size = len(chunk)
		}
		pos += 8 + n + (n & 1)
	}
	if channels == 0 || rate == 0 || align == 0 || size < 0 {
		return
	}
	return size / align, channels, rate, true
}

decode :: proc(path: string, data: []u8, allocator := context.allocator) -> (Decoded, Error) {
	if f, ok := format_from_path(path); ok {
		return f.decode(data, allocator)
	}
	return {}, fmt.tprintf("%s: no decoder for its extension", path)
}

// ---- WAV ---------------------------------------------------------------------------

@(private)
WAV_PCM :: 1
@(private)
WAV_FLOAT :: 3
@(private)
WAV_EXTENSIBLE :: 0xfffe

// RIFF WAVE: PCM 8/16/24/32-bit, float 32/64-bit (plain or extensible), any
// channel count; the first loop of a smpl chunk.
wav_decode :: proc(data: []u8, allocator := context.allocator) -> (d: Decoded, err: Error) {
	if len(data) < 12 || string(data[:4]) != "RIFF" || string(data[8:12]) != "WAVE" {
		return d, fmt.tprintf("wav: not a RIFF WAVE file")
	}
	format, bits, align := 0, 0, 0
	body: []u8
	for pos := 12; pos + 8 <= len(data); {
		id := string(data[pos:pos + 4])
		size := int(endian.unchecked_get_u32le(data[pos + 4:]))
		start := pos + 8
		end := min(start + size, len(data))
		chunk := data[start:end]
		switch id {
		case "fmt ":
			if len(chunk) < 16 {
				return d, fmt.tprintf("wav: short fmt chunk")
			}
			format = int(endian.unchecked_get_u16le(chunk[0:]))
			d.channels = int(endian.unchecked_get_u16le(chunk[2:]))
			d.rate = int(endian.unchecked_get_u32le(chunk[4:]))
			align = int(endian.unchecked_get_u16le(chunk[12:]))
			bits = int(endian.unchecked_get_u16le(chunk[14:]))
			if format == WAV_EXTENSIBLE && len(chunk) >= 26 {
				format = int(endian.unchecked_get_u16le(chunk[24:])) // the subformat GUID's first field
			}
		case "data":
			body = chunk
		case "smpl":
			if len(chunk) >= 36 + 24 && endian.unchecked_get_u32le(chunk[28:]) > 0 {
				loop := chunk[36:]
				d.loop_from = i64(endian.unchecked_get_u32le(loop[8:]))
				d.loop_to = i64(endian.unchecked_get_u32le(loop[12:])) + 1 // its end is inclusive
			}
		}
		pos = start + size + (size & 1)
	}
	if d.channels == 0 || d.rate == 0 || body == nil {
		return d, fmt.tprintf("wav: no fmt or data chunk")
	}
	width := bits / 8
	if align < width * d.channels {
		align = width * d.channels
	}
	frames := len(body) / align
	d.samples = make([]f32, frames * d.channels, allocator)
	switch {
	case format == WAV_PCM && bits == 8:
		for f in 0 ..< frames {
			for c in 0 ..< d.channels {
				d.samples[f * d.channels + c] = (f32(body[f * align + c]) - 128) / 128
			}
		}
	case format == WAV_PCM && (bits == 16 || bits == 24 || bits == 32):
		scale := 1 / f32(i64(1) << uint(bits - 1))
		for f in 0 ..< frames {
			for c in 0 ..< d.channels {
				at := f * align + c * width
				v: i32
				for k in 0 ..< width {
					v |= i32(body[at + k]) << uint(8 * (4 - width + k))
				}
				d.samples[f * d.channels + c] = f32(v >> uint(32 - bits)) * scale
			}
		}
	case format == WAV_FLOAT && bits == 32:
		for f in 0 ..< frames {
			for c in 0 ..< d.channels {
				d.samples[f * d.channels + c] = transmute(f32)endian.unchecked_get_u32le(body[f * align + c * 4:])
			}
		}
	case format == WAV_FLOAT && bits == 64:
		for f in 0 ..< frames {
			for c in 0 ..< d.channels {
				d.samples[f * d.channels + c] = f32(transmute(f64)endian.unchecked_get_u64le(body[f * align + c * 8:]))
			}
		}
	case:
		return d, fmt.tprintf("wav: format %d with %d bits", format, bits)
	}
	if d.loop_to > i64(frames) || d.loop_to - d.loop_from < 2 {
		d.loop_from, d.loop_to = 0, 0
	}
	return d, nil
}

// ---- resampling --------------------------------------------------------------------

// Taps on each side at unity and the window's Kaiser beta (about 100 dB):
// a load happens once, so it can afford a long kernel.
RESAMPLE_HALF :: 32
RESAMPLE_BETA :: 10.0
// Downsampling's cutoff, as a fraction of the new Nyquist: the kernel's
// transition band (about 8% each side at RESAMPLE_HALF) then ends at it.
RESAMPLE_DOWN_CUTOFF :: 0.92
// Phases of the polyphase table; a ratio needing more (an odd rate) reads
// the nearest of these.
RESAMPLE_PHASES :: 4096

@(private)
gcd :: proc(a, b: int) -> int {
	a, b := a, b
	for b != 0 {
		a, b = b, a % b
	}
	return a
}

// The decoded file at device.RATE as 16-bit PCM in its own channels (more
// than two: the first two), its loop moved with it.
pcm_at_rate :: proc(d: Decoded, allocator := context.allocator) -> (pcm: []i16, channels: int, loop_from, loop_to: i64) {
	channels = clamp(d.channels, 1, 2)
	n := len(d.samples) / max(d.channels, 1)
	src := make([]f32, channels * n, context.temp_allocator)
	for i in 0 ..< n {
		for c in 0 ..< channels {
			src[channels * i + c] = d.samples[i * d.channels + c]
		}
	}
	at_rate := src
	loop_from, loop_to = d.loop_from, d.loop_to
	if d.rate != device.RATE {
		at_rate = resample(src, channels, d.rate, context.temp_allocator)
		loop_from = i64(math.round(f64(d.loop_from) * device.RATE / f64(d.rate)))
		loop_to = i64(math.round(f64(d.loop_to) * device.RATE / f64(d.rate)))
	}
	pcm = make([]i16, len(at_rate), allocator)
	for v, i in at_rate {
		pcm[i] = i16(clamp(math.round(f64(v) * 32768), -32768, 32767))
	}
	return
}

// Frames of `channels` interleaved values at `rate` to device.RATE: output
// frame j reads the input at j * rate / RATE through a windowed sinc
// low-passed below the lower of the two Nyquists, one precomputed filter per
// phase.
resample :: proc(src: []f32, channels: int, rate: int, allocator := context.allocator) -> []f32 {
	ch := channels
	n := len(src) / ch
	g := gcd(rate, device.RATE)
	up, down := device.RATE / g, rate / g // output j sits at input j * down / up
	phases := min(up, RESAMPLE_PHASES)
	// Down, the kernel's transition band ends at the new Nyquist (nothing
	// above it folds back); up, there's nothing above the old one to fold.
	cutoff := rate > device.RATE ? RESAMPLE_DOWN_CUTOFF * f64(device.RATE) / f64(rate) : 1
	taps := int(math.ceil(RESAMPLE_HALF / cutoff))
	width := 2 * taps
	table := make([]f32, phases * width, context.temp_allocator)
	for p in 0 ..< phases {
		frac := f64(p) / f64(phases)
		for k in 0 ..< width {
			x := frac - f64(k - taps + 1) // the input frame is centre + k - taps + 1
			table[p * width + k] = f32(cutoff * device.kaiser_sinc(x * cutoff, RESAMPLE_HALF, RESAMPLE_BETA))
		}
	}
	count := int((i64(n) * i64(up) + i64(down) - 1) / i64(down))
	out := make([]f32, ch * count, allocator)
	for j in 0 ..< count {
		t := i64(j) * i64(down)
		centre := int(t / i64(up))
		p := int(t % i64(up)) * phases / up
		h := table[p * width:][:width]
		first := centre - taps + 1
		for c in 0 ..< ch {
			sum: f32
			if first >= 0 && first + width <= n {
				for k in 0 ..< width {
					sum += src[ch * (first + k) + c] * h[k]
				}
			} else {
				for k in 0 ..< width {
					i := first + k
					if i >= 0 && i < n {
						sum += src[ch * i + c] * h[k]
					}
				}
			}
			out[ch * j + c] = sum
		}
	}
	return out
}

// ---- the bank ----------------------------------------------------------------------

// Declares a set in the bank: its row and its zones (from the register),
// each zone's file noted, nothing read or fetched. Round robins: zones
// answering the same keys and velocities are a group, in order.
declare_set :: proc(bank: ^device.Bank, s: ^Set_Row) -> Error {
	zones := set_zones(s)
	first_zone := i32(len(bank.zones))
	for &z in zones {
		file, ok := file_index_from_path(s.source, z.path)
		if !ok {
			resize(&bank.zones, int(first_zone))
			resize(&bank.zone_file, int(first_zone))
			return fmt.tprintf("%s: %s is not pinned", s.name, z.path)
		}
		group, sequence := u16(len(bank.zones)) - u16(first_zone), u16(0)
		for &prior, i in bank.zones[first_zone:] {
			if prior.lo_key == z.lo_key && prior.hi_key == z.hi_key && prior.lo_velocity == z.lo_velocity && prior.hi_velocity == z.hi_velocity {
				if sequence == 0 {
					group = u16(i)
				}
				sequence += 1
			}
		}
		append(&bank.zones, device.Zone {
			sample = -1,
			lo_key = z.lo_key,
			hi_key = z.hi_key,
			root = z.root,
			lo_velocity = z.lo_velocity,
			hi_velocity = z.hi_velocity,
			group = group,
			sequence = sequence,
			gain = f32(base.db_to_gain(f64(z.gain_db + s.gain_db + s.level_db))),
			one_shot = z.one_shot,
		})
		append(&bank.zone_file, file)
	}
	append(&bank.sets, device.Sample_Set{name = s.name, zones = {first_zone, i32(len(bank.zones)) - first_zone}})
	return nil
}

// Declares the named sets not in the bank yet (their zones, nothing loaded).
// A name the register lacks is a finding. True when every name is declared.
bank_declare :: proc(bank: ^device.Bank, names: []string, findings: ^base.Findings) -> bool {
	init_tables(bank)
	ok := true
	for name in names {
		if _, declared := device.bank_set_from_name(bank, name); declared {
			continue
		}
		s, found := set_row_from_name(name)
		if !found {
			base.report(findings, "unknown_asset", .Error, name, "no sample set %q; the sets: %s", name, set_names_joined())
			ok = false
			continue
		}
		if err := declare_set(bank, s); err != nil {
			base.report(findings, "asset_unavailable", .Error, name, "%s: %s", name, err.?)
			ok = false
		}
	}
	return ok
}

// Loads what a song plays: the zones of each need's set answering its keys
// (every velocity layer and round robin of them), each file downloaded first
// if it isn't on disk yet (on first use, only these files), its header read
// to size the bank's slab once, then decoded into it at RATE in its own
// channels as 16-bit PCM. A file that can't be had is a finding; the rest
// load. True when every needed zone is loaded.
bank_load :: proc(bank: ^device.Bank, needs: []device.Sample_Need, findings: ^base.Findings, progress: Progress = progress_stderr) -> bool {
	root, rerr := data_dir(context.temp_allocator)
	if rerr != nil {
		base.report(findings, "asset_unavailable", .Error, "", "no data folder for sample sets: %s", rerr.?)
		return false
	}
	return bank_load_at(bank, root, needs, findings, progress)
}

// bank_load with the files under `root`; trust_disk: use the files there as
// they are, unverified and never fetched (a test's own stand-ins).
bank_load_at :: proc(bank: ^device.Bank, root: string, needs: []device.Sample_Need, findings: ^base.Findings, progress: Progress = progress_stderr, trust_disk := false) -> bool {
	init_tables(bank)
	// the files the needs reach, once each, with the zones that play them
	Wanted :: struct {
		file:  i32,
		set:   i32,
		zones: [dynamic]i32,
	}
	wanted := make([dynamic]Wanted, context.temp_allocator)
	for need in needs {
		if need.set < 0 || int(need.set) >= len(bank.sets) {
			continue
		}
		zs := bank.sets[need.set].zones
		for zi in zs.first ..< base.span_end(zs) {
			z := bank.zones[zi]
			if z.sample >= 0 || bank.zone_file[zi] < 0 {
				continue
			}
			hit := false
			for k in int(z.lo_key) ..= int(z.hi_key) {
				hit ||= k in need.keys
			}
			if !hit {
				continue
			}
			found := false
			for &w in wanted {
				if w.file == bank.zone_file[zi] {
					append(&w.zones, zi)
					found = true
				}
			}
			if !found {
				w := Wanted{file = bank.zone_file[zi], set = need.set, zones = make([dynamic]i32, context.temp_allocator)}
				append(&w.zones, zi)
				append(&wanted, w)
			}
		}
	}
	if len(wanted) == 0 {
		return true
	}
	// fetch what isn't on disk, then size the slab from the headers (each
	// file read in a scratch arena of its own)
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil {
		return false
	}
	defer virtual.arena_destroy(&scratch)
	ok := true
	total := 0
	// what can't be had is one finding per set: how many of its files, and why
	Missing :: struct {
		set:   i32,
		count: int,
		why:   string,
	}
	missing := make([dynamic]Missing, context.temp_allocator)
	miss :: proc(missing: ^[dynamic]Missing, set: i32, why: string) {
		for &m in missing {
			if m.set == set {
				m.count += 1
				return
			}
		}
		append(missing, Missing{set, 1, why})
	}
	defer for m in missing {
		name := bank.sets[m.set].name
		base.report(findings, "asset_unavailable", .Error, name, "%s: %d of its files can't be had (%s); they play once they can be", name, m.count, m.why)
	}
	for &w in wanted {
		f := &FILE_TABLE[w.file]
		if err := trust_disk ? nil : ensure_file(root, f); err != nil {
			miss(&missing, w.set, err.?)
			w.file, ok = -1, false
			continue
		}
		frames, channels, rate, read := 0, 0, 0, false
		{
			context.temp_allocator = virtual.arena_allocator(&scratch)
			defer virtual.arena_free_all(&scratch)
			data, err := os.read_entire_file(file_path(root, f, context.temp_allocator), context.temp_allocator)
			if row, has := format_from_path(f.path); err == nil && has {
				frames, channels, rate, read = row.info(data)
			}
		}
		if !read {
			miss(&missing, w.set, fmt.tprintf("%s can't be read", f.path))
			w.file, ok = -1, false
			continue
		}
		total += clamp(channels, 1, 2) * frames_at_rate(frames, rate)
	}
	chunk, slab := device.bank_chunk_i16(bank, total)
	used := 0
	for w in wanted {
		if w.file < 0 {
			continue
		}
		f := &FILE_TABLE[w.file]
		context.allocator = virtual.arena_allocator(&scratch)
		context.temp_allocator = virtual.arena_allocator(&scratch)
		defer virtual.arena_free_all(&scratch)
		data, rerr := os.read_entire_file(file_path(root, f, context.allocator), context.allocator)
		d: Decoded
		derr: Error
		if rerr == nil {
			d, derr = decode(f.path, data)
		}
		if rerr != nil || derr != nil {
			miss(&missing, w.set, fmt.tprintf("%s can't be decoded", f.path))
			ok = false
			continue
		}
		pcm, channels, loop_from, loop_to := pcm_at_rate(d)
		if used + len(pcm) > len(slab) {
			miss(&missing, w.set, fmt.tprintf("%s decodes longer than its header says", f.path))
			ok = false
			continue
		}
		copy(slab[used:], pcm)
		sample := i32(len(bank.samples))
		append(&bank.samples, device.Sample{chunk = chunk, at = i64(used), frames = i64(len(pcm) / channels), channels = u8(channels), format = .I16})
		used += len(pcm)
		for zi in w.zones {
			z := &bank.zones[zi]
			z.sample, z.loop_from, z.loop_to = sample, i32(loop_from), i32(loop_to)
		}
	}
	return ok
}

// Frames a file of `frames` at `rate` has at device.RATE (resample's count).
@(private = "file")
frames_at_rate :: proc(frames, rate: int) -> int {
	if rate == device.RATE || rate <= 0 {
		return frames
	}
	g := gcd(rate, device.RATE)
	up, down := device.RATE / g, rate / g
	return int((i64(frames) * i64(up) + i64(down) - 1) / i64(down))
}

// Declares the named sets and loads all of them (every key): for listening
// to a whole set, and the tests.
bank_from_names :: proc(bank: ^device.Bank, names: []string, findings: ^base.Findings, progress: Progress = progress_stderr) -> bool {
	ok := bank_declare(bank, names, findings)
	needs := make([dynamic]device.Sample_Need, context.temp_allocator)
	for name in names {
		if set, declared := device.bank_set_from_name(bank, name); declared {
			append(&needs, device.Sample_Need{set = set, keys = ~bit_set[0 ..< 128;u128]{}})
		}
	}
	return bank_load(bank, needs[:], findings, progress) && ok
}

// The bank's tables keep the caller's allocator; decoding happens in scratch.
@(private = "file")
init_tables :: proc(bank: ^device.Bank) {
	if bank.f32s.allocator.procedure == nil {
		bank.f32s.allocator = context.allocator
	}
	if bank.i16s.allocator.procedure == nil {
		bank.i16s.allocator = context.allocator
	}
	if bank.owned.allocator.procedure == nil {
		bank.owned.allocator = context.allocator
	}
	if bank.samples.allocator.procedure == nil {
		bank.samples.allocator = context.allocator
	}
	if bank.zones.allocator.procedure == nil {
		bank.zones.allocator = context.allocator
	}
	if bank.zone_file.allocator.procedure == nil {
		bank.zone_file.allocator = context.allocator
	}
	if bank.sets.allocator.procedure == nil {
		bank.sets.allocator = context.allocator
	}
}

@(private)
set_names_joined :: proc() -> string {
	names := make([dynamic]string, context.temp_allocator)
	for s in SET_TABLE {
		append(&names, s.name)
	}
	return strings.join(names[:], ", ", context.temp_allocator)
}

// One line per named set for a song's credits: the set, its source, its
// licence and the credit line (required for CC-BY, given for CC0 too).
credits_from_names :: proc(names: []string, allocator := context.allocator) -> []string {
	lines := make([dynamic]string, allocator)
	for name in names {
		s, found := set_row_from_name(name)
		if !found {
			continue
		}
		src := &SOURCE_TABLE[s.source]
		lic := &LICENCE_TABLE[src.licence]
		append(&lines, fmt.aprintf("%s: %s (%s, %s; %s)%s", s.name, src.credit, lic.spdx, lic.url, src.page, lic.credit_required ? "; credit required" : "", allocator = allocator))
	}
	return lines[:]
}
