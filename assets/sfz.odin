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
	release:         f32, // ampeg_release, seconds (0: the Sampler's)
	alternates:      bool, // a round robin's (lorand, hirand or seq_position): SFZ plays one, not all
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
	{"seq_position", proc(r: ^Sfz_Region, v: string) {r.sequence, r.alternates = sfz_int(v, 0), true}},
	// lorand/hirand split a round robin by chance: the zones sharing keys and
	// velocities are one, and a note's seed picks among them
	{"lorand", proc(r: ^Sfz_Region, v: string) {r.alternates = true}},
	{"hirand", proc(r: ^Sfz_Region, v: string) {r.alternates = true}},
	{"ampeg_release", proc(r: ^Sfz_Region, v: string) {r.release = f32(sfz_f64(v, 0))}},
	// amp_velcurve_N: a velocity's level; odawg's is linear to the zone's
	// top velocity, which is what layered sets write (amp_velcurve_<hivel>=1)
	{"amp_velcurve_", proc(r: ^Sfz_Region, v: string) {}},
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
declare_sfz :: proc(bank: ^device.Bank, ref: spec.Asset_Ref, d: ^Declaring) -> bool {
	key := spec.asset_key(ref.from, ref.name) // its path, in the folder of the spec naming it
	f, found := song_file(d, ref.from, key)
	if !found {
		return false
	}
	text, ok := song_file_text(bank, d, f, key)
	if !ok {
		base.report(d.findings, "missing_file", .Error, key, "%s can't be read", key)
		return false
	}
	if f.url == "" {
		note_file(d.files, key)
	}
	regions, default_path, unsupported := sfz_regions(text)
	for name in unsupported {
		base.report(d.findings, "unsupported_opcode", .Info, key, "%s: %s is not read (its regions play without it)", key, name)
	}
	folder := filepath.dir(key)
	// a source's SFZ plays that source's files only
	inside := ""
	if f.url != "" {
		inside = key[:strings.index_byte(key, '/') + 1]
	}
	files := make([]Song_File, len(regions), context.temp_allocator)
	stamp := base.hash_combine(0x5f2, song_file_stamp(d, f))
	for r, i in regions {
		sample, _ := strings.replace_all(r.sample, "\\", "/", context.temp_allocator)
		p, _ := filepath.join({folder, default_path, sample}, context.temp_allocator)
		if inside != "" && !strings.has_prefix(p, inside) {
			base.report(d.findings, "bad_value", .Error, key, "%s: sample %s is outside its source; not fetched", key, r.sample)
			return false
		}
		g, has := song_file(d, ref.from, p)
		if !has {
			return false
		}
		if g.url == "" {
			note_file(d.files, p)
		}
		files[i] = g
		stamp = base.hash_combine(stamp, song_file_stamp(d, g))
	}
	if declared_at(bank, key, stamp) {
		return true
	}
	drafts := make([dynamic]Zone_Draft, context.temp_allocator)
	skipped := 0
	for r, i in regions {
		if r.release_trigger || r.sample == "" {
			skipped += 1
			continue
		}
		z := Zone_Draft {
			file = bank_file_song(bank, d, files[i]),
			lo = r.lo,
			hi = r.hi,
			root = r.root - r.tune_cents / 100, // tuned up plays as if recorded lower
			lo_velocity = r.lo_velocity,
			hi_velocity = r.hi_velocity,
			gain_db = r.volume_db,
			one_shot = r.loop_mode == "one_shot",
			offset = r.offset,
			sequence = r.sequence,
			release = r.release,
		}
		switch {
		case r.loop_mode == "loop_continuous" || r.loop_mode == "loop_sustain":
			if r.loop_to > r.loop_from {
				z.loop_from, z.loop_to = r.loop_from, r.loop_to
			} else {
				z.loop_to = device.LOOP_FROM_FILE
			}
		case r.loop_mode == "":
			z.loop_to = device.LOOP_FROM_FILE // SFZ's default: the file's own loop, if it has one
		case:
			z.loop_to = -1
		}
		append(&drafts, z)
	}
	if skipped > 0 {
		base.report(d.findings, "unsupported_opcode", .Info, key, "%s: %d release-triggered regions are not played", key, skipped)
	}
	// regions answering the same notes with nothing to alternate them by are
	// layers in SFZ (all sound); a zone plays alone here
	layered := 0
	for r, i in regions {
		if r.alternates || r.release_trigger || r.sample == "" {
			continue
		}
		for o, j in regions {
			if j != i && !o.release_trigger && o.sample != "" && o.lo == r.lo && o.hi == r.hi && o.lo_velocity == r.lo_velocity && o.hi_velocity == r.hi_velocity {
				layered += 1
				break
			}
		}
	}
	if layered > 0 {
		base.report(d.findings, "unsupported_opcode", .Info, key, "%s: %d regions are layers (all sound in SFZ); odawg plays one of them per note", key, layered)
	}
	if len(drafts) == 0 {
		base.report(d.findings, "bad_zone", .Error, key, "%s: no region with a sample", key)
		return false
	}
	append_set(bank, key, stamp, drafts[:])
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
			// a name ending _ is a family (amp_velcurve_40)
			if op.name == key || (strings.has_suffix(op.name, "_") && strings.has_prefix(key, op.name)) {
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
