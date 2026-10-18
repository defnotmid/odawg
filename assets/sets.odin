package odawg_assets

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import base "../base"
import device "../device"
import spec "../spec"

// Sample sets from wherever a song's are: the register's (pinned, fetched
// on first use), a set the song brings (`sets = { my_kit = { pads = ... } }`)
// and an SFZ file (`set = "instruments/piano.sfz"`), all one shape in the
// bank: a set, its zones, each zone a file row. Which kind a name is, and
// how its zones are read, is a row of SET_SOURCES. Files a song brings are
// read through the host (Bank_Host): onimite from its media, the CLI from
// the spec's folder.

// What a host gives the loader. `root`: where a song's own paths are (a
// relative path is from it). `read`: a file's samples, decoded by the host
// (any format it reads) and lent, at the file's own rate: it may be called
// from any of the loader's threads, and what it returns must outlive the
// banks that borrow it; .Declined leaves the file to the loader (its own
// WAV and FLAC, loops included). Without it, the loader reads every file
// from root itself. `text`: a file's text (an SFZ), and `stamp`: its content's
// identity (a changed file declares its set again); without them, from
// root, by its size and time. `pinning`: fetch a source's files its pins
// don't list yet, trusting what comes (odawg pin; the bank's files then
// carry their pins to write). `fetched`: where fetched files go (""
// the data directory).
Bank_Host :: struct {
	data:    rawptr,
	root:    string,
	read:    proc(data: rawptr, path: string) -> (samples: Host_Samples, result: Host_Read),
	text:    proc(data: rawptr, path: string) -> (text: string, ok: bool),
	stamp:   proc(data: rawptr, path: string) -> u64,
	pinning: bool,
	fetched: string,
}

Host_Read :: enum u8 {
	Read, // the samples are the host's, lent
	Declined, // not the host's to decode: the loader reads it
	Failed, // it can't be read (a finding)
}

Host_Samples :: struct {
	samples:            []f32, // interleaved by channels
	channels, rate:     int,
	loop_from, loop_to: i64, // frames (loop_to <= loop_from: none)
}

// Where the loader reads a song's own path.
host_path :: proc(host: ^Bank_Host, path: string, allocator := context.temp_allocator) -> string {
	if host == nil || host.root == "" || filepath.is_abs(path) {
		return path
	}
	p, _ := filepath.join({host.root, path}, allocator)
	return p
}

@(private)
host_text :: proc(host: ^Bank_Host, path: string) -> (string, bool) {
	if host != nil && host.text != nil {
		return host.text(host.data, path)
	}
	data, err := os.read_entire_file(host_path(host, path), context.temp_allocator)
	return string(data), err == nil
}

// A file's content identity, as the loader keys sets by it: the host's
// stamp, else the file's size and modification time under root (0: no
// file). A host keying songs by their files uses this too, so the two
// agree.
file_stamp :: proc(host: ^Bank_Host, path: string) -> u64 {
	if host != nil && host.stamp != nil {
		return host.stamp(host.data, path)
	}
	info, err := os.stat(host_path(host, path), context.temp_allocator)
	if err != nil {
		return 0
	}
	return base.hash_combine(u64(info.size), u64(info.modification_time._nsec))
}

// The register's file `register` as a file of the bank (one row each).
bank_file_register :: proc(bank: ^device.Bank, register: i32) -> i32 {
	if register < 0 {
		return -1
	}
	for f, i in bank.files {
		if f.register == register {
			return i32(i)
		}
	}
	append(&bank.files, device.Bank_File{register = register})
	return i32(len(bank.files) - 1)
}

// `s` cloned into the bank's text (freed with it).
@(private)
bank_text :: proc(bank: ^device.Bank, s: string) -> string {
	if bank.text.allocator.procedure == nil {
		bank.text.allocator = bank.sets.allocator
	}
	c := strings.clone(s, bank.sets.allocator)
	append(&bank.text, c)
	return c
}

// A path of the host's as a file of the bank: one row per path and content.
bank_file_path :: proc(bank: ^device.Bank, path: string, stamp: u64) -> i32 {
	init_tables(bank)
	for f, i in bank.files {
		if f.register < 0 && f.path == path && f.stamp == stamp {
			return i32(i)
		}
	}
	append(&bank.files, device.Bank_File{register = -1, path = bank_text(bank, path), stamp = stamp})
	return i32(len(bank.files) - 1)
}

// ---- the sources ---------------------------------------------------------------------

// How a set is named, as rows: the song's own (it defines the name), an
// SFZ file (a path ending .sfz), the register's.
Set_Source :: enum u8 {
	Inline,
	Sfz,
	Register,
}

Set_Source_Row :: struct {
	is:      proc(ref: spec.Asset_Ref) -> bool,
	declare: proc(bank: ^device.Bank, ref: spec.Asset_Ref, d: ^Declaring) -> bool,
}

SET_SOURCES := [Set_Source]Set_Source_Row {
	.Inline = {
		is = proc(ref: spec.Asset_Ref) -> bool {return ref.owner != nil},
		declare = declare_inline,
	},
	.Sfz = {
		is = proc(ref: spec.Asset_Ref) -> bool {return strings.has_suffix(strings.to_lower(ref.name, context.temp_allocator), ".sfz")},
		declare = declare_sfz,
	},
	.Register = {
		is = proc(ref: spec.Asset_Ref) -> bool {return true},
		declare = proc(bank: ^device.Bank, ref: spec.Asset_Ref, d: ^Declaring) -> bool {
			if _, declared := device.bank_set_from_name(bank, ref.name); declared {
				return true
			}
			s, found := set_row_from_name(ref.name)
			if !found {
				base.report(d.findings, "unknown_asset", .Error, ref.name, "no sample set %q: a set of the song's own (sets = {{ ... }}), an .sfz file, or one of the register's: %s", ref.name, set_names_joined())
				return false
			}
			if err := declare_set(bank, s); err != nil {
				base.report(d.findings, "asset_unavailable", .Error, ref.name, "%s: %s", ref.name, err.?)
				return false
			}
			return true
		},
	},
}

// Declares every set the song's Samplers name (its own styles' too), each
// by its source's rule: zones and file rows, nothing loaded (bank_load
// loads what the notes reach, fetching a source's files then). `files`
// gets every file of the song's own the sets read (an SFZ, its samples, a
// set's samples, a source's pins): what a host watches and keys the song
// by. True when every set is declared.
bank_declare_spec :: proc(bank: ^device.Bank, s: ^spec.Spec, findings: ^base.Findings, host: ^Bank_Host = nil, files: ^[dynamic]string = nil) -> bool {
	init_tables(bank)
	refs := make([dynamic]spec.Asset_Ref, context.temp_allocator)
	spec.asset_refs(s, &refs)
	d := Declaring{findings = findings, host = host, files = files, sources = make([dynamic]Source_Read, context.temp_allocator)}
	d.root = host != nil ? host.fetched : ""
	if d.root == "" {
		d.root, _ = data_dir(context.temp_allocator)
	}
	ok := true
	for ref in refs {
		for row in SET_SOURCES {
			if row.is(ref) {
				if !row.declare(bank, ref, &d) {
					ok = false // the rest are still declared (every finding at once)
				}
				break
			}
		}
	}
	return ok
}

// A file the song reads, noted once.
@(private)
note_file :: proc(files: ^[dynamic]string, path: string) {
	if files == nil {
		return
	}
	for f in files {
		if f == path {
			return
		}
	}
	append(files, strings.clone(path, files.allocator))
}

// The zones a set declares, before they are rows of the bank.
@(private)
Zone_Draft :: struct {
	file:        i32,
	lo, hi:      int,
	root:        f32,
	lo_velocity: int,
	hi_velocity: int,
	gain_db:     f32,
	one_shot:    bool,
	offset:      i32,
	sequence:    int, // an SFZ's seq_position (0: in order)
	release:     f32, // seconds (0: the Sampler's)
	// the loop: the file's (loop_to LOOP_FROM_FILE), none (-1), or these frames
	loop_from:   i32,
	loop_to:     i32,
}

// Appends a set of `drafts` named `name` at `stamp`, round robins grouped
// (zones answering the same keys and velocities alternate).
@(private)
append_set :: proc(bank: ^device.Bank, name: string, stamp: u64, drafts: []Zone_Draft) {
	init_tables(bank)
	first := i32(len(bank.zones))
	same :: proc(a, b: Zone_Draft) -> bool {return a.lo == b.lo && a.hi == b.hi && a.lo_velocity == b.lo_velocity && a.hi_velocity == b.hi_velocity}
	for z, zi in drafts {
		// a round robin: the zones answering the same keys and velocities, its
		// group the first of them, each one's place by seq_position (then order)
		group, sequence := u16(zi), u16(0)
		for o, oi in drafts {
			if oi == zi || !same(o, z) {
				continue
			}
			if oi < int(group) {
				group = u16(oi)
			}
			if o.sequence < z.sequence || (o.sequence == z.sequence && oi < zi) {
				sequence += 1
			}
		}
		append(&bank.zones, device.Zone {
			sample = -1,
			lo_key = u8(clamp(z.lo, 0, 127)),
			hi_key = u8(clamp(z.hi, 0, 127)),
			root = z.root,
			lo_velocity = u8(clamp(z.lo_velocity, 0, 127)),
			hi_velocity = u8(clamp(z.hi_velocity, 0, 127)),
			group = group,
			sequence = sequence,
			gain = f32(base.db_to_gain(f64(z.gain_db))),
			one_shot = z.one_shot,
			offset = z.offset,
			loop_from = z.loop_from,
			loop_to = z.loop_to,
			release = z.release,
		})
		append(&bank.zone_file, z.file)
	}
	append(&bank.sets, device.Sample_Set{name = bank_text(bank, name), zones = {first, i32(len(bank.zones)) - first}, stamp = stamp})
}

// Whether a set named `name` is in the bank at `stamp` already.
@(private)
declared_at :: proc(bank: ^device.Bank, name: string, stamp: u64) -> bool {
	set, found := device.bank_set_from_name(bank, name)
	return found && bank.sets[set].stamp == stamp
}

// Keys split between roots: each zone without a range answers from midway
// to the root below to midway to the root above (within its velocity range).
@(private = "file")
split_keys :: proc(drafts: []Zone_Draft, given: []bool) {
	for &z, i in drafts {
		if given[i] {
			continue
		}
		below, above := -1.0, 128.0
		for o, j in drafts {
			if j == i || given[j] || o.lo_velocity != z.lo_velocity || o.hi_velocity != z.hi_velocity {
				continue
			}
			r, mine := f64(o.root), f64(z.root)
			if r < mine && r > below {
				below = r
			}
			if r > mine && r < above {
				above = r
			}
		}
		z.lo = below < 0 ? 0 : int(math.floor((below + f64(z.root)) / 2)) + 1
		z.hi = above > 127 ? 127 : int(math.floor((f64(z.root) + above) / 2))
	}
}

// A set the song brings: pads at their General MIDI keys (one-shots), zones
// around their roots.
@(private = "file")
declare_inline :: proc(bank: ^device.Bank, ref: spec.Asset_Ref, d: ^Declaring) -> bool {
	s := ref.owner
	set, _ := spec.set_from_name(s, ref.name)
	zones := s.set_zones[set.zones.first:base.span_end(set.zones)]
	stamp: u64 = 0x5e75
	found := make([]Song_File, len(zones), context.temp_allocator)
	for z, i in zones {
		f, ok := song_file(d, s, spec.path_from(s, z.file))
		if !ok {
			return false
		}
		if f.url == "" {
			note_file(d.files, f.path)
		}
		found[i] = f
		stamp = base.hash_combine(stamp, song_file_stamp(d, f))
	}
	key := spec.asset_key(s, ref.name)
	if declared_at(bank, key, stamp) {
		return true
	}
	drafts := make([]Zone_Draft, len(zones), context.temp_allocator)
	given := make([]bool, len(zones), context.temp_allocator)
	for z, i in zones {
		x := &drafts[i]
		x.file = bank_file_song(bank, d, found[i])
		x.lo_velocity, x.hi_velocity = int(z.lo_velocity), int(z.hi_velocity)
		x.gain_db = f32(z.gain_db + set.gain_db)
		x.offset = i32(z.offset)
		x.loop_to = set.loop ? device.LOOP_FROM_FILE : -1
		switch {
		case z.pad != .None:
			key := int(device.note_from_pad(z.pad))
			x.lo, x.hi, x.root = key, key, f32(key)
			x.one_shot = math.is_nan(z.one_shot) || z.one_shot != 0
			given[i] = true
		case:
			x.root = math.is_nan(z.root) ? 60 : f32(z.root)
			x.one_shot = !math.is_nan(z.one_shot) && z.one_shot != 0
			if !math.is_nan(z.lo) || !math.is_nan(z.hi) {
				x.lo = math.is_nan(z.lo) ? 0 : int(z.lo)
				x.hi = math.is_nan(z.hi) ? 127 : int(z.hi)
				given[i] = true
			}
		}
	}
	split_keys(drafts, given)
	append_set(bank, key, stamp, drafts)
	return true
}
