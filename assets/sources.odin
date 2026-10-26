package odawg_assets

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import base "../base"
import device "../device"
import spec "../spec"

// A song's sources (spec.Source_Spec): files fetched from a pinned URL, as
// the register's are, but named by the song. A path whose first part names
// a source is its file: fetched into the data directory
// (sources/<name>-<url hash>/<path>) the first time a note reaches it, and
// verified against its line in the source's pins file. The pins are text,
// `sha256 size path` a line (`#` comments), written by odawg pin, read
// through the host like any of the song's files.

Pin_Row :: struct {
	sha256: string,
	size:   i64,
	path:   string,
}

// A pins file's rows (slices of its text).
pins_from_text :: proc(text: string, allocator := context.temp_allocator) -> []Pin_Row {
	rows := make([dynamic]Pin_Row, allocator)
	rest_of := text
	for line in strings.split_lines_iterator(&rest_of) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' {
			continue
		}
		sp := strings.index_any(l, " \t")
		if sp < 0 {
			continue
		}
		rest := strings.trim_left_space(l[sp:])
		sp2 := strings.index_any(rest, " \t")
		if sp2 < 0 {
			continue
		}
		size, ok := strconv.parse_i64(rest[:sp2])
		if !ok {
			continue
		}
		append(&rows, Pin_Row{sha256 = l[:sp], size = size, path = strings.trim_space(rest[sp2:])})
	}
	return rows[:]
}

// The pins as text, sorted by path.
pins_text :: proc(rows: []Pin_Row, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "# sha256 size path: written by odawg pin\n")
	for r in rows {
		fmt.sbprintf(&b, "%s %d %s\n", r.sha256, r.size, r.path)
	}
	return strings.to_string(b)
}

// Where a source's files live under the data directory.
source_dir :: proc(root: string, src: ^spec.Source_Spec, allocator := context.temp_allocator) -> string {
	p, _ := filepath.join({root, "sources", fmt.tprintf("%s-%08x", src.name, u32(base.hash_string(src.url)))}, allocator)
	return p
}

// What declaring the sets reads with: the host, its findings, the files of
// the song's own noted, each source's pins once.
@(private)
Declaring :: struct {
	findings: ^base.Findings,
	host:     ^Bank_Host,
	files:    ^[dynamic]string,
	root:     string, // the data directory
	sources:  [dynamic]Source_Read,
}

@(private)
Source_Read :: struct {
	src:  ^spec.Source_Spec,
	pins: []Pin_Row,
	ok:   bool, // its licence allows commercial use and its pins were read
}

// A path the song reads: a source's (fetched to `path`, from `url`) or the
// host's (`path` as written, `url` "").
@(private)
Song_File :: struct {
	path:   string,
	url:    string,
	sha256: string, // "": not pinned
	size:   i64,
}

// The file a path names, seen from spec `from` (its sources and its
// outer song's). False: a source's that can't be had (a finding).
@(private)
song_file :: proc(d: ^Declaring, from: ^spec.Spec, path: string) -> (f: Song_File, ok: bool) {
	slash := strings.index_byte(path, '/')
	if slash <= 0 {
		return {path = path}, true
	}
	src, owner := spec.source_from_name(from, path[:slash])
	if src == nil {
		return {path = path}, true
	}
	read := source_read(d, src, spec.path_from(owner, src.pins))
	if !read.ok {
		return {}, false
	}
	rest := path[slash + 1:]
	// what a source's file is called comes from shared data (a style's
	// zones, an SFZ, the pins): never a path out of its folder
	dir := source_dir(d.root, src)
	f = {url = url_join(src.url, rest)}
	f.path, _ = filepath.join({dir, rest}, context.temp_allocator)
	if !spec.plain_path(rest) || !strings.has_prefix(f.path, strings.concatenate({dir, "/"}, context.temp_allocator)) {
		base.report(d.findings, "bad_value", .Error, path, "%s: a source's file is a plain path inside it (no .., \\, drive or leading /); not fetched", path)
		return {}, false
	}
	for p in read.pins {
		if p.path == rest {
			f.sha256, f.size = p.sha256, p.size
		}
	}
	return f, true
}

@(private)
source_read :: proc(d: ^Declaring, src: ^spec.Source_Spec, pins: string) -> ^Source_Read {
	for &x in d.sources {
		if x.src == src {
			return &x
		}
	}
	append(&d.sources, Source_Read{src = src})
	x := &d.sources[len(d.sources) - 1]
	allowed := false
	for row in LICENCE_TABLE {
		allowed ||= row.spdx == src.licence
	}
	if !allowed {
		base.report(d.findings, "licence_not_allowed", .Error, src.name, "source %s: licence %q isn't one odawg allows (commercial use: %s)", src.name, src.licence, licences_joined())
		return x
	}
	if d.root == "" {
		base.report(d.findings, "asset_unavailable", .Error, src.name, "source %s: no data folder to fetch into", src.name)
		return x
	}
	note_file(d.files, pins)
	text, read := host_text(d.host, pins)
	if !read {
		if !pinning(d.host) {
			base.report(d.findings, "missing_file", .Error, pins, "source %s: its pins %s can't be read (odawg pin writes them)", src.name, pins)
			return x
		}
		text = ""
	}
	// a pins line naming a path out of the source is refused, not read
	rows := make([dynamic]Pin_Row, context.temp_allocator)
	for row in pins_from_text(text) {
		if !spec.plain_path(row.path) || len(row.sha256) != 64 || row.size < 0 {
			base.report(d.findings, "bad_value", .Error, pins, "%s: %q is not a pin odawg takes (64 hex digits, a size, a plain path inside the source)", pins, row.path)
			continue
		}
		append(&rows, row)
	}
	x.pins, x.ok = rows[:], true
	return x
}

@(private)
pinning :: proc(host: ^Bank_Host) -> bool {return host != nil && host.pinning}

@(private)
verifying :: proc(host: ^Bank_Host) -> bool {return host != nil && host.verify}

@(private = "file")
licences_joined :: proc() -> string {
	names := make([dynamic]string, context.temp_allocator)
	for row in LICENCE_TABLE {
		append(&names, row.spdx)
	}
	return strings.join(names[:], ", ", context.temp_allocator)
}

// A song file's identity for a set's stamp: a source's by its pin, the
// host's by its stamp.
@(private)
song_file_stamp :: proc(d: ^Declaring, f: Song_File) -> u64 {
	if f.url != "" {
		return base.hash_string(f.sha256 != "" ? f.sha256 : f.url)
	}
	return file_stamp(d.host, f.path)
}

// A song file as a file of the bank: one row per file.
@(private)
bank_file_song :: proc(bank: ^device.Bank, d: ^Declaring, f: Song_File) -> i32 {
	if f.url == "" {
		return bank_file_path(bank, f.path, file_stamp(d.host, f.path))
	}
	init_tables(bank)
	for x, i in bank.files {
		if x.url == f.url && x.sha256 == f.sha256 {
			return i32(i)
		}
	}
	append(&bank.files, device.Bank_File{register = -1, path = bank_text(bank, f.path), stamp = song_file_stamp(d, f), url = bank_text(bank, f.url), sha256 = bank_text(bank, f.sha256), size = f.size})
	return i32(len(bank.files) - 1)
}

// A song file's text: a source's fetched now (an SFZ is read to declare
// its set), the host's read through it.
@(private)
song_file_text :: proc(bank: ^device.Bank, d: ^Declaring, f: Song_File, name: string) -> (string, bool) {
	if f.url == "" {
		return host_text(d.host, f.path)
	}
	if f.sha256 == "" && !pinning(d.host) {
		base.report(d.findings, "not_pinned", .Error, name, "%s is not in its source's pins (odawg pin SPEC fetches and pins what the song plays)", name)
		return "", false
	}
	got, size, err := ensure_pinned(f.path, f.url, f.sha256, f.size)
	if err != nil {
		base.report(d.findings, "asset_unavailable", .Error, name, "%s: %s", name, err.?)
		return "", false
	}
	if f.sha256 == "" {
		// odawg pin: a row of the bank, so its pin is written with the rest
		g := f
		g.sha256, g.size = got, size
		bank_file_song(bank, d, g)
	}
	data, rerr := os.read_entire_file(f.path, context.temp_allocator)
	return string(data), rerr == nil
}

// A source's pins once odawg pin has fetched what a song plays: the files
// the bank fetched from it merged into what its pins held (sorted, earlier
// rows kept), as the text for the host to write at `pins_path` (a plain
// path of the song's, from the host's root).
Pin_Update :: struct {
	source:       string,
	licence:      string,
	pins_path:    string,
	total, added: int,
	text:         string,
}

// The pins each source of `s` (its own styles' included) holds after
// `bank` was declared and loaded with host.pinning. A source whose pins
// aren't a plain path in the song's folder (a style read from outside it)
// is a finding, and isn't updated; a pins line odawg wouldn't take is left
// out. In `allocator`.
pins_update :: proc(bank: ^device.Bank, s: ^spec.Spec, host: ^Bank_Host, findings: ^base.Findings, allocator := context.allocator) -> []Pin_Update {
	root := host != nil ? host.fetched : ""
	if root == "" {
		root, _ = data_dir(context.temp_allocator)
	}
	refs := make([dynamic]spec.Source_Ref, context.temp_allocator)
	spec.source_refs(s, &refs)
	out := make([dynamic]Pin_Update, allocator)
	for &r in refs {
		if !spec.plain_path(r.pins_path) {
			base.report(findings, "bad_value", .Error, r.name, "source %s: its pins %s are outside the song's folder; not written", r.name, r.pins_path)
			continue
		}
		dir := strings.concatenate({source_dir(root, &r.source), "/"}, context.temp_allocator)
		old, _ := host_text(host, r.pins_path)
		rows := make([dynamic]Pin_Row, context.temp_allocator)
		for row in pins_from_text(old) {
			if spec.plain_path(row.path) && len(row.sha256) == 64 && row.size >= 0 {
				append(&rows, row)
			}
		}
		added := 0
		for f in bank.files {
			if f.url == "" || f.sha256 == "" || !strings.has_prefix(f.path, dir) {
				continue
			}
			rel := f.path[len(dir):]
			known := false
			for x in rows {
				known ||= x.path == rel
			}
			if !known && spec.plain_path(rel) {
				append(&rows, Pin_Row{sha256 = f.sha256, size = f.size, path = rel})
				added += 1
			}
		}
		slice.sort_by(rows[:], proc(x, y: Pin_Row) -> bool {return x.path < y.path})
		append(&out, Pin_Update {
			source = strings.clone(r.name, allocator),
			licence = strings.clone(r.licence, allocator),
			pins_path = strings.clone(r.pins_path, allocator),
			total = len(rows),
			added = added,
			text = pins_text(rows[:], allocator),
		})
	}
	return out[:]
}

// How deep instrument files may name instrument files.
MAX_FILE_ROUNDS :: 16

// Reads the files a spec reads beside itself (its style files, then the
// instrument files it and they name, until none is new) through the host,
// a source's fetched and checked against its pins, and hands each to the
// spec. `files` notes each one read, for a host keying songs by their files
// (file_stamp). False: one couldn't be had (findings say which).
spec_read_files :: proc(s: ^spec.Spec, findings: ^base.Findings, host: ^Bank_Host = nil, files: ^[dynamic]string = nil, bank: ^device.Bank = nil) -> bool {
	d := Declaring{findings = findings, host = host, files = files, sources = make([dynamic]Source_Read, context.temp_allocator)}
	d.root = host != nil ? host.fetched : ""
	if d.root == "" {
		d.root, _ = data_dir(context.temp_allocator)
	}
	scratch: device.Bank
	b := bank != nil ? bank : &scratch
	ok := true
	read :: proc(d: ^Declaring, b: ^device.Bank, s: ^spec.Spec, name: string) -> (string, bool) {
		f, found := song_file(d, s, name)
		if !found {
			return "", false
		}
		text, read_ok := song_file_text(b, d, f, name)
		if !read_ok {
			base.report(d.findings, "missing_file", .Error, name, "%s can't be read", name)
			return "", false
		}
		note_file(d.files, f.path)
		return text, true
	}
	styles := make([dynamic]string, context.temp_allocator)
	spec.style_files(s, &styles)
	for name in styles {
		text, got := read(&d, b, s, name)
		added := got && spec.spec_add_style_text(s, name, text, findings)
		ok = ok && added
	}
	// files name files: until none is new (each round adds every one it
	// lists, read or not, so it ends; the cap is a guard)
	for round in 0 ..< MAX_FILE_ROUNDS {
		names := make([dynamic]string, context.temp_allocator)
		spec.instrument_files(s, &names)
		if len(names) == 0 {
			break
		}
		if round == MAX_FILE_ROUNDS - 1 {
			base.report(findings, "instrument_cycle", .Error, names[0], "%s: instrument files name files %d deep", names[0], MAX_FILE_ROUNDS)
			return false
		}
		for name in names {
			text, got := read(&d, b, s, name)
			if !got {
				// handed back empty, so it isn't asked for again
				spec.spec_add_instrument_text(s, name, "{}", findings)
				ok = false
				continue
			}
			if !spec.spec_add_instrument_text(s, name, text, findings) {
				spec.spec_add_instrument_text(s, name, "{}", findings) // not JSON: asked for once
				ok = false
			}
		}
	}
	return ok
}
