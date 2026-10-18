package odawg_assets

import "core:math"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import base "../base"
import device "../device"
import spec "../spec"
import theory "../theory"

// SFZ, the format free sample libraries ship in: headers (<control>,
// <global>, <master>, <group>, <region>) and opcodes (name=value), each
// region a zone inheriting what the headers above it set. odawg reads the
// opcodes that place and play a sample, as rows of SFZ_OPCODES; any other
// is a finding (unsupported_opcode, once each per file), not an error.
// Paths are the file's own: relative to its folder, after default_path.

@(private = "file")
Sfz_Region :: struct {
	sample:          string,
	lo, hi:          int,
	root:            f32, // pitch_keycenter (a key= sets lo, hi and it)
	lo_velocity:     int,
	hi_velocity:     int,
	volume_db:       f32,
	tune_cents:      f32,
	offset:          i32,
	loop_mode:       string,
	loop_from:       i32,
	loop_to:         i32,
	sequence:        int,
	release_trigger: bool, // trigger=release: played on note off, which odawg doesn't
}

@(private = "file")
SFZ_DEFAULT :: Sfz_Region{lo = 0, hi = 127, root = 60, lo_velocity = 0, hi_velocity = 127, loop_to = -1}

// An opcode and what it sets in a region (value as written).
@(private = "file")
SFZ_OPCODES := [?]struct {
	name: string,
	set:  proc(r: ^Sfz_Region, v: string),
} {
	{"sample", proc(r: ^Sfz_Region, v: string) {r.sample = v}},
	{"lokey", proc(r: ^Sfz_Region, v: string) {r.lo = sfz_key(v, r.lo)}},
	{"hikey", proc(r: ^Sfz_Region, v: string) {r.hi = sfz_key(v, r.hi)}},
	{"key", proc(r: ^Sfz_Region, v: string) {
		k := sfz_key(v, 60)
		r.lo, r.hi, r.root = k, k, f32(k)
	}},
	{"pitch_keycenter", proc(r: ^Sfz_Region, v: string) {r.root = f32(sfz_key(v, int(r.root)))}},
	{"lovel", proc(r: ^Sfz_Region, v: string) {r.lo_velocity = sfz_int(v, r.lo_velocity)}},
	{"hivel", proc(r: ^Sfz_Region, v: string) {r.hi_velocity = sfz_int(v, r.hi_velocity)}},
	{"volume", proc(r: ^Sfz_Region, v: string) {r.volume_db = f32(sfz_f64(v, 0))}},
	{"tune", proc(r: ^Sfz_Region, v: string) {r.tune_cents = f32(sfz_f64(v, 0))}},
	{"offset", proc(r: ^Sfz_Region, v: string) {r.offset = i32(sfz_int(v, 0))}},
	{"loop_mode", proc(r: ^Sfz_Region, v: string) {r.loop_mode = v}},
	{"loopmode", proc(r: ^Sfz_Region, v: string) {r.loop_mode = v}},
	{"loop_start", proc(r: ^Sfz_Region, v: string) {r.loop_from = i32(sfz_int(v, 0))}},
	{"loopstart", proc(r: ^Sfz_Region, v: string) {r.loop_from = i32(sfz_int(v, 0))}},
	{"loop_end", proc(r: ^Sfz_Region, v: string) {r.loop_to = i32(sfz_int(v, -1)) + 1}},
	{"loopend", proc(r: ^Sfz_Region, v: string) {r.loop_to = i32(sfz_int(v, -1)) + 1}},
	{"seq_position", proc(r: ^Sfz_Region, v: string) {r.sequence = sfz_int(v, 0)}},
	{"seq_length", proc(r: ^Sfz_Region, v: string) {}}, // round robins are the zones sharing keys and velocities
	{"trigger", proc(r: ^Sfz_Region, v: string) {r.release_trigger = v == "release"}},
}

@(private = "file")
sfz_int :: proc(v: string, fallback: int) -> int {
	n, ok := strconv.parse_int(v)
	return ok ? n : fallback
}

@(private = "file")
sfz_f64 :: proc(v: string, fallback: f64) -> f64 {
	n, ok := strconv.parse_f64(v)
	return ok ? n : fallback
}

// A key as a number or a note name (c4 is 60, as SFZ has it).
@(private = "file")
sfz_key :: proc(v: string, fallback: int) -> int {
	if n, ok := strconv.parse_int(v); ok {
		return n
	}
	if len(v) > 0 {
		name := strings.concatenate({strings.to_upper(v[:1], context.temp_allocator), v[1:]}, context.temp_allocator)
		if p, ok := theory.pitch_from_string(name); ok {
			return int(math.round(p))
		}
	}
	return fallback
}

// An SFZ file's regions as zones of the bank, each region's sample a file
// of the bank (relative to the SFZ's folder and its default_path).
@(private = "package")
declare_sfz :: proc(bank: ^device.Bank, ref: spec.Asset_Ref, findings: ^base.Findings, host: ^Bank_Host, files: ^[dynamic]string) -> bool {
	text, ok := host_text(host, ref.name)
	if !ok {
		base.report(findings, "missing_file", .Error, ref.name, "%s can't be read", ref.name)
		return false
	}
	note_file(files, ref.name)
	regions, default_path, unsupported := sfz_regions(text)
	for name in unsupported {
		base.report(findings, "unsupported_opcode", .Info, ref.name, "%s: %s is not read (its regions play without it)", ref.name, name)
	}
	folder := filepath.dir(ref.name)
	paths := make([]string, len(regions), context.temp_allocator)
	stamp := base.hash_combine(0x5f2, host_stamp(host, ref.name))
	for r, i in regions {
		sample, _ := strings.replace_all(r.sample, "\\", "/", context.temp_allocator)
		p, _ := filepath.join({folder, default_path, sample}, context.temp_allocator)
		paths[i] = p
		note_file(files, p)
		stamp = base.hash_combine(stamp, host_stamp(host, p))
	}
	if declared_at(bank, ref.name, stamp) {
		return true
	}
	drafts := make([dynamic]Zone_Draft, context.temp_allocator)
	skipped := 0
	for r, i in regions {
		if r.release_trigger || r.sample == "" {
			skipped += 1
			continue
		}
		d := Zone_Draft {
			file = bank_file_path(bank, paths[i], host_stamp(host, paths[i])),
			lo = r.lo,
			hi = r.hi,
			root = r.root - r.tune_cents / 100, // tuned up plays as if recorded lower
			lo_velocity = r.lo_velocity,
			hi_velocity = r.hi_velocity,
			gain_db = r.volume_db,
			one_shot = r.loop_mode == "one_shot",
			offset = r.offset,
			sequence = r.sequence,
		}
		switch {
		case r.loop_mode == "loop_continuous" || r.loop_mode == "loop_sustain":
			if r.loop_to > r.loop_from {
				d.loop_from, d.loop_to = r.loop_from, r.loop_to
			} else {
				d.loop_to = device.LOOP_FROM_FILE
			}
		case r.loop_mode == "":
			d.loop_to = device.LOOP_FROM_FILE // SFZ's default: the file's own loop, if it has one
		case:
			d.loop_to = -1
		}
		append(&drafts, d)
	}
	if skipped > 0 {
		base.report(findings, "unsupported_opcode", .Info, ref.name, "%s: %d release-triggered regions are not played", ref.name, skipped)
	}
	if len(drafts) == 0 {
		base.report(findings, "bad_zone", .Error, ref.name, "%s: no region with a sample", ref.name)
		return false
	}
	append_set(bank, ref.name, stamp, drafts[:])
	return true
}

// The regions of an SFZ text, each with what its <global>, <master> and
// <group> set before it, the <control> default_path, and the opcodes not
// read (once each).
@(private = "file")
sfz_regions :: proc(text: string) -> (regions: [dynamic]Sfz_Region, default_path: string, unsupported: [dynamic]string) {
	regions = make([dynamic]Sfz_Region, context.temp_allocator)
	unsupported = make([dynamic]string, context.temp_allocator)
	// comments out
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(text); {
		switch {
		case strings.has_prefix(text[i:], "//"):
			for i < len(text) && text[i] != '\n' {
				i += 1
			}
		case strings.has_prefix(text[i:], "/*"):
			end := strings.index(text[i + 2:], "*/")
			i = end < 0 ? len(text) : i + 2 + end + 2
		case:
			strings.write_byte(&b, text[i])
			i += 1
		}
	}
	src := strings.to_string(b)
	Level :: enum {
		Control,
		Global,
		Master,
		Group,
		Region,
	}
	levels: [Level]Sfz_Region
	for &l in levels {
		l = SFZ_DEFAULT
	}
	header := Level.Control
	region_open := false
	close_region :: proc(regions: ^[dynamic]Sfz_Region, levels: ^[Level]Sfz_Region, open: ^bool) {
		if open^ {
			append(regions, levels[.Region])
			open^ = false
		}
	}
	// opcodes: name=value, a value running to the next name= or header (a
	// sample's path may hold spaces)
	i := 0
	for i < len(src) {
		c := src[i]
		if c == '<' {
			end := strings.index_byte(src[i:], '>')
			if end < 0 {
				break
			}
			name := src[i + 1:i + end]
			close_region(&regions, &levels, &region_open)
			switch name {
			case "control":
				header = .Control
			case "global":
				header = .Global
				levels[.Global], levels[.Master], levels[.Group] = SFZ_DEFAULT, SFZ_DEFAULT, SFZ_DEFAULT
			case "master":
				header = .Master
				levels[.Master] = levels[.Global]
				levels[.Group] = levels[.Master]
			case "group":
				header = .Group
				levels[.Group] = levels[.Master]
			case "region":
				header = .Region
				levels[.Region] = levels[.Group]
				region_open = true
			case:
				header = .Control // a header odawg doesn't read: its opcodes are skipped
			}
			i += end + 1
			continue
		}
		eq := strings.index_byte(src[i:], '=')
		if eq < 0 {
			break
		}
		key := strings.trim_space(src[i:i + eq])
		// the key is the last word before the =
		if sp := strings.last_index_any(key, " \t\r\n"); sp >= 0 {
			key = key[sp + 1:]
		}
		rest := src[i + eq + 1:]
		// the value ends where the next name= or header starts
		stop := len(rest)
		if lt := strings.index_byte(rest, '<'); lt >= 0 {
			stop = lt
		}
		if next_eq := strings.index_byte(rest[:stop], '='); next_eq >= 0 {
			cut := strings.last_index_any(rest[:next_eq], " \t\r\n")
			stop = cut >= 0 ? cut : next_eq
		}
		value := strings.trim_space(rest[:stop])
		i += eq + 1 + stop
		if header == .Control {
			if key == "default_path" {
				default_path, _ = strings.replace_all(value, "\\", "/", context.temp_allocator)
			}
			continue
		}
		set := false
		for op in SFZ_OPCODES {
			if op.name == key {
				op.set(&levels[header], value)
				set = true
				break
			}
		}
		if !set {
			seen := false
			for u in unsupported {
				seen ||= u == key
			}
			if !seen {
				append(&unsupported, key)
			}
		}
	}
	close_region(&regions, &levels, &region_open)
	return
}
