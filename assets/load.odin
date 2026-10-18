package odawg_assets

import "base:runtime"
import base "../base"
import device "../device"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:thread"

// Loading: a set's files decoded (WAV and FLAC by odecs: a row per
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
// A file straight to the bank's 16 bits, at most `keep` of its channels
// (interleaved), with no floats between.
Decode_I16_Proc :: #type proc(data: []u8, keep: int, allocator := context.allocator) -> (pcm: []i16, d: Decoded, err: Error)
// What a file holds, from its header alone: to size the bank before decoding.
Info_Proc :: #type proc(data: []u8) -> (frames, channels, rate: int, ok: bool)

// The decoder for a file, by its extension: a row each.
Format_Row :: struct {
	extension: string,
	decode:     Decode_Proc,
	decode_i16: Decode_I16_Proc,
	info:       Info_Proc,
}

FORMAT_TABLE := []Format_Row{{".wav", wav_decode, wav_decode_i16, wav_info}, {".flac", flac_decode, flac_decode_i16, flac_info}}

format_from_path :: proc(path: string) -> (^Format_Row, bool) {
	for &f in FORMAT_TABLE {
		if strings.has_suffix(strings.to_lower(path, context.temp_allocator), f.extension) {
			return &f, true
		}
	}
	return nil, false
}

decode :: proc(path: string, data: []u8, allocator := context.allocator) -> (Decoded, Error) {
	if f, ok := format_from_path(path); ok {
		return f.decode(data, allocator)
	}
	return {}, fmt.tprintf("%s: no decoder for its extension", path)
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
		register, ok := file_index_from_path(s.source, z.path)
		file := bank_file_register(bank, register)
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
			loop_to = device.LOOP_FROM_FILE,
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
// if it isn't on disk yet (on first use, only these files), then read once
// and decoded, the files side by side on every core, as 16-bit PCM in its
// own channels at its own rate (a Sampler reads it at RATE). A file that
// can't be had is a finding; the rest load. True when every needed zone is
// loaded.
bank_load :: proc(bank: ^device.Bank, needs: []device.Sample_Need, findings: ^base.Findings, progress: Progress = progress_stderr, host: ^Bank_Host = nil) -> bool {
	if host != nil && host.fetched != "" {
		return bank_load_at(bank, host.fetched, needs, findings, progress, host = host)
	}
	root, rerr := data_dir(context.temp_allocator)
	if rerr != nil {
		base.report(findings, "asset_unavailable", .Error, "", "no data folder for sample sets: %s", rerr.?)
		return false
	}
	return bank_load_at(bank, root, needs, findings, progress, host = host)
}

// bank_load with the files under `root`; trust_disk: use the files there as
// they are, unverified and never fetched (a test's own stand-ins).
bank_load_at :: proc(bank: ^device.Bank, root: string, needs: []device.Sample_Need, findings: ^base.Findings, progress: Progress = progress_stderr, trust_disk := false, host: ^Bank_Host = nil) -> bool {
	init_tables(bank)
	// the files the needs reach, once each (a finding names the set)
	Wanted :: struct {
		file: i32,
		set:  i32,
	}
	wanted := make([dynamic]Wanted, context.temp_allocator)
	for need in needs {
		if need.set < 0 || int(need.set) >= len(bank.sets) {
			continue
		}
		// the zones a Sampler would pick for each key and velocity played (of
		// a round robin, all of them)
		zs := bank.sets[need.set].zones
		reached := make([]bool, zs.count, context.temp_allocator)
		for key in need.keys {
			velocities := need.velocities[key]
			if velocities == {} {
				velocities = ~bit_set[0 ..< 128;u128]{}
			}
			for v in velocities {
				best_key, best_vel, _ := device.zone_nearest(bank, int(need.set), key, v)
				for zi in zs.first ..< base.span_end(zs) {
					reached[zi - zs.first] ||= device.zone_is_nearest(&bank.zones[zi], key, v, best_key, best_vel)
				}
			}
		}
		for z in need.zones {
			if z >= 0 && z < zs.count {
				reached[z] = true
			}
		}
		for zi in zs.first ..< base.span_end(zs) {
			z := bank.zones[zi]
			if !reached[zi - zs.first] || z.sample >= 0 || bank.zone_file[zi] < 0 {
				continue
			}
			found := false
			for w in wanted {
				found ||= w.file == bank.zone_file[zi]
			}
			if !found {
				append(&wanted, Wanted{file = bank.zone_file[zi], set = need.set})
			}
		}
	}
	if len(wanted) == 0 {
		return true
	}
	ok := true
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
	// the register's fetched first where they aren't on disk (on first use)
	for &w in wanted {
		bf := bank.files[w.file]
		if bf.register < 0 {
			continue
		}
		if err := trust_disk ? nil : ensure_file(root, &FILE_TABLE[bf.register]); err != nil {
			miss(&missing, w.set, err.?)
			w.file, ok = -1, false
		}
	}
	// a song's sources' the same way, verified against their pins (odawg pin
	// fetches the unpinned and keeps what it got for the pins it writes)
	for &w in wanted {
		if w.file < 0 || trust_disk {
			continue
		}
		bf := &bank.files[w.file]
		if bf.url == "" {
			continue
		}
		if bf.sha256 == "" && !pinning(host) {
			miss(&missing, w.set, fmt.tprintf("%s is not in its source's pins; odawg pin SPEC fetches and pins what the song plays", bf.url))
			w.file, ok = -1, false
			continue
		}
		got, size, err := ensure_pinned(bf.path, bf.url, bf.sha256, bf.size)
		if err != nil {
			miss(&missing, w.set, err.?)
			w.file, ok = -1, false
			continue
		}
		if bf.sha256 == "" {
			bf.sha256, bf.size = bank_text(bank, got), size
		}
	}
	// each file read once and decoded, side by side, into PCM of its own
	// (at its own rate: a Sampler reads it at RATE), then each a chunk of the
	// bank, in order
	jobs := make([]Decode_Job, len(wanted), context.temp_allocator)
	for w, k in wanted {
		jobs[k] = {file = -1, host = host}
		if w.file < 0 {
			continue
		}
		bf := bank.files[w.file]
		jobs[k].file = w.file
		if bf.register >= 0 {
			f := &FILE_TABLE[bf.register]
			jobs[k].path, jobs[k].name = file_path(root, f), f.path
		} else {
			// a source's file is ours, in the data directory; the rest the host's
			jobs[k].path, jobs[k].name, jobs[k].hosted = host_path(host, bf.path), bf.url != "" ? bf.url : bf.path, bf.url == "" && host != nil && host.read != nil
		}
	}
	decode_all(jobs)
	for &j, k in jobs {
		w := wanted[k]
		if w.file < 0 {
			continue
		}
		if j.err != "" {
			miss(&missing, w.set, j.err)
			ok = false
			continue
		}
		sample := i32(len(bank.samples))
		if j.hosted {
			// the host's own decode, lent: not copied, not ours to free
			append(&bank.f32s, j.lent)
			append(&bank.samples, device.Sample{chunk = i32(len(bank.f32s) - 1), frames = i64(len(j.lent) / j.channels), channels = u8(min(j.channels, 255)), format = .F32, rate = i32(j.rate)})
		} else {
			chunk, values := device.bank_chunk_i16(bank, len(j.pcm))
			copy(values, j.pcm)
			delete(j.pcm, runtime.heap_allocator())
			append(&bank.samples, device.Sample{chunk = chunk, frames = i64(len(values) / j.channels), channels = u8(j.channels), format = .I16, rate = i32(j.rate)})
		}
		// every zone playing the file has it (one an earlier load didn't reach too)
		for zi in 0 ..< len(bank.zones) {
			if bank.zone_file[zi] != w.file || bank.zones[zi].sample >= 0 {
				continue
			}
			z := &bank.zones[zi]
			z.sample = sample
			if z.loop_to == device.LOOP_FROM_FILE {
				z.loop_from, z.loop_to = i32(j.loop_from), i32(j.loop_to)
			}
		}
	}
	return ok
}

// One file to decode: what it is, and what came of it (16-bit PCM in at
// most two channels on the heap, at its own rate, its loop; or why not).
@(private = "file")
Decode_Job :: struct {
	file:                i32, // into the bank's files (-1: not to decode)
	path:                string, // where to read it
	name:                string, // what a finding calls it
	host:                ^Bank_Host,
	hosted:              bool, // the host decodes it (lent)
	pcm:                 []i16,
	lent:                []f32,
	channels, rate:      int,
	loop_from, loop_to:  i64,
	err:                 string,
}

// Decodes the jobs on every core (a scratch arena each for the file).
@(private = "file")
decode_all :: proc(jobs: []Decode_Job) {
	run :: proc(j: ^Decode_Job) {
		if j.file < 0 {
			return
		}
		scratch: virtual.Arena
		if virtual.arena_init_growing(&scratch) != nil {
			j.err = "out of memory"
			return
		}
		defer virtual.arena_destroy(&scratch)
		context.allocator = virtual.arena_allocator(&scratch)
		context.temp_allocator = virtual.arena_allocator(&scratch)
		if j.hosted {
			got, result := j.host.read(j.host.data, j.name)
			switch {
			case result == .Declined:
				j.hosted = false // the loader's own, below
			case result != .Read || got.channels <= 0 || len(got.samples) == 0:
				j.err = fmt.aprintf("%s can't be read", j.name, allocator = runtime.heap_allocator())
				return
			case:
				j.lent, j.channels, j.rate = got.samples, got.channels, got.rate > 0 ? got.rate : device.RATE
				j.loop_from, j.loop_to = got.loop_from, got.loop_to
				return
			}
		}
		data, rerr := os.read_entire_file(j.path, context.allocator)
		if rerr != nil {
			j.err = fmt.aprintf("%s can't be read", j.name, allocator = runtime.heap_allocator())
			return
		}
		format, known := format_from_path(j.path)
		if !known {
			j.err = fmt.aprintf("%s can't be decoded", j.name, allocator = runtime.heap_allocator())
			return
		}
		// straight to 16 bits, in the bank's memory
		pcm, d, derr := format.decode_i16(data, 2, runtime.heap_allocator())
		if derr != nil {
			j.err = fmt.aprintf("%s can't be decoded", j.name, allocator = runtime.heap_allocator())
			return
		}
		j.pcm, j.channels = pcm, clamp(d.channels, 1, 2)
		j.rate = d.rate > 0 ? d.rate : device.RATE
		j.loop_from, j.loop_to = d.loop_from, d.loop_to
	}
	workers := min(len(jobs), max(1, os.get_processor_core_count()))
	if workers <= 1 {
		for &j in jobs {
			run(&j)
		}
		return
	}
	heap := runtime.heap_allocator()
	pool: thread.Pool
	thread.pool_init(&pool, heap, workers)
	for &j in jobs {
		thread.pool_add_task(&pool, heap, proc(t: thread.Task) {run((^Decode_Job)(t.data))}, &j)
	}
	thread.pool_start(&pool)
	thread.pool_finish(&pool)
	thread.pool_destroy(&pool)
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
@(private)
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
	if bank.files.allocator.procedure == nil {
		bank.files.allocator = context.allocator
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
