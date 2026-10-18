package odawg_assets

import "core:path/filepath"
import "core:strings"
import base "../base"
import device "../device"
import spec "../spec"

// An SFZ instrument's samples: its file (and what it #includes, read the
// same way, round by round) read with spec's SFZ reader, every region with
// a sample a zone of one set, in the order the regions come (the zone a
// region's Region node plays), its file the region's sample (from the SFZ's
// folder, after default_path). The texts go to the spec that named it, so
// compiling the instrument reads what was declared.

// The most rounds of includes read (a file including another, ...).
SFZ_INCLUDE_ROUNDS :: 16

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
	stamp := base.hash_combine(0x5f2, song_file_stamp(d, f))
	texts := make(map[string]string, context.temp_allocator)
	texts[key] = text
	s: spec.Sfz
	for _ in 0 ..< SFZ_INCLUDE_ROUNDS {
		spec.sfz_read(&s, key, text, texts, context.temp_allocator)
		read := false
		for m in s.missing {
			if m in texts {
				continue
			}
			g, has := song_file(d, ref.from, m)
			t: string
			readable := false
			if has {
				t, readable = song_file_text(bank, d, g, m)
			}
			texts[m] = readable ? t : ""
			if readable {
				if g.url == "" {
					note_file(d.files, m)
				}
				stamp = base.hash_combine(stamp, song_file_stamp(d, g))
			} else {
				base.report(d.findings, "missing_file", .Error, key, "%s includes %s, which can't be read", key, m)
			}
			read = true
		}
		if !read {
			break
		}
	}
	if ref.from != nil {
		for path, t in texts {
			spec.spec_add_sfz_text(ref.from, path, t)
		}
	}
	folder := filepath.dir(key)
	// a source's SFZ plays that source's files only
	inside := ""
	if f.url != "" {
		inside = key[:strings.index_byte(key, '/') + 1]
	}
	files := make([dynamic]Song_File, context.temp_allocator)
	regions := make([dynamic]int, context.temp_allocator)
	for r in 0 ..< len(s.regions) {
		sample, has := spec.sfz_value(&s, r, "sample")
		if !has || strings.has_prefix(sample, "*") {
			continue
		}
		sample, _ = strings.replace_all(sample, "\\", "/", context.temp_allocator)
		p, _ := filepath.join({folder, s.default_path, sample}, context.temp_allocator)
		if inside != "" && !strings.has_prefix(p, inside) {
			base.report(d.findings, "bad_value", .Error, key, "%s: sample %s is outside its source; not fetched", key, sample)
			return false
		}
		g, ok := song_file(d, ref.from, p)
		if !ok {
			return false
		}
		if g.url == "" {
			note_file(d.files, p)
		}
		append(&files, g)
		append(&regions, r)
		stamp = base.hash_combine(stamp, song_file_stamp(d, g))
	}
	if declared_at(bank, key, stamp) {
		return true
	}
	drafts := make([dynamic]Zone_Draft, context.temp_allocator)
	for r, i in regions {
		lo := sfz_region_key(&s, r, "lokey", 0)
		hi := sfz_region_key(&s, r, "hikey", 127)
		if v, has := spec.sfz_value(&s, r, "key"); has {
			k := spec.sfz_key(&s, v, 60)
			lo, hi = k, k
		}
		root := lo
		if v, has := spec.sfz_value(&s, r, "pitch_keycenter"); has {
			root = spec.sfz_key(&s, v, root)
		}
		append(&drafts, Zone_Draft{
			file = bank_file_song(bank, d, files[i]),
			lo = clamp(lo, 0, 127),
			hi = clamp(hi, 0, 127),
			root = f32(root),
			lo_velocity = int(spec.sfz_number(&s, r, "lovel", 0)),
			hi_velocity = int(spec.sfz_number(&s, r, "hivel", 127)),
			loop_to = device.LOOP_FROM_FILE, // the file's own loop, if it has one (a Region chooses)
		})
	}
	if len(s.regions) == 0 {
		base.report(d.findings, "bad_zone", .Error, key, "%s: no regions", key)
		return false
	}
	append_set(bank, key, stamp, drafts[:]) // none: its regions are generators (*sine)
	return true
}

@(private = "file")
sfz_region_key :: proc(s: ^spec.Sfz, r: int, name: string, fallback: int) -> int {
	v, has := spec.sfz_value(s, r, name)
	return has ? spec.sfz_key(s, v, fallback) : fallback
}
