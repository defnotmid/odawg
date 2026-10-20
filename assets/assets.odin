package odawg_assets

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Fetching, as ottis does: every file of a set downloaded into the data
// directory (`<source>/<path>`) and verified by SHA-256 before use. A
// verified file gets a `.sha256` stamp next to it; later runs trust a file
// whose size and stamp match its pin, and `verify` hashes everything again.

// What went wrong, for a finding (in the temp allocator).
Error :: Maybe(string)

// The data directory: $ODAWG_DATA, else odawg/ under the user's data
// directory (~/.local/share, ~/Library/Application Support, %APPDATA%).
data_dir :: proc(allocator := context.allocator) -> (string, Error) {
	if env := os.get_env("ODAWG_DATA", allocator); env != "" {
		return env, nil
	}
	base, err := os.user_data_dir(context.temp_allocator)
	if err != nil {
		return "", fmt.tprintf("no user data directory: %v", err)
	}
	dir, _ := filepath.join({base, "odawg"}, allocator)
	return dir, nil
}

// Where a file of a source lives under the data directory.
file_path :: proc(root: string, f: ^File_Row, allocator := context.temp_allocator) -> string {
	p, _ := filepath.join({root, SOURCE_TABLE[f.source].name, f.path}, allocator)
	return p
}

// The file's URL: its source's, then its path percent-encoded (the `/`s kept).
file_url :: proc(f: ^File_Row, allocator := context.temp_allocator) -> string {
	return url_join(SOURCE_TABLE[f.source].url, f.path, allocator)
}

// A folder's URL (ending /) and a path in it, percent-encoded (the `/`s kept).
url_join :: proc(folder, path: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, folder)
	for i in 0 ..< len(path) {
		c := path[i]
		switch c {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '_', '.', '~', '/':
			strings.write_byte(&b, c)
		case:
			fmt.sbprintf(&b, "%%%02X", c)
		}
	}
	return strings.to_string(b)
}

// http_get gives up on a connection not made within CONNECT_TIMEOUT_S, and
// on a transfer that receives nothing for STALL_TIMEOUT_S.
CONNECT_TIMEOUT_S :: 15
STALL_TIMEOUT_S :: 30

// Download destination: bytes go to a file and through SHA-256 together.
Sink :: struct {
	file:    ^os.File,
	hash:    sha2.Context_256,
	written: i64,
}

sink_write :: proc(s: ^Sink, data: []u8) -> os.Error {
	sha2.update(&s.hash, data)
	s.written += i64(len(data))
	_, err := os.write(s.file, data)
	return err
}

@(private)
hex_digest :: proc(ctx: ^sha2.Context_256) -> string {
	digest: [sha2.DIGEST_SIZE_256]u8
	sha2.final(ctx, digest[:])
	return string(hex.encode(digest[:], context.temp_allocator))
}

@(private)
hash_file :: proc(path: string) -> (string, Error) {
	f, err := os.open(path)
	if err != nil {
		return "", fmt.tprintf("opening %s: %v", path, err)
	}
	defer os.close(f)
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	buf := make([]u8, 1 << 20, context.temp_allocator)
	for {
		n, rerr := os.read(f, buf)
		if n > 0 {
			sha2.update(&ctx, buf[:n])
		}
		if rerr == .EOF || n == 0 {
			break
		}
		if rerr != nil {
			return "", fmt.tprintf("reading %s: %v", path, rerr)
		}
	}
	return hex_digest(&ctx), nil
}

@(private)
stamp_path :: proc(path: string) -> string {
	return strings.concatenate({path, ".sha256"}, context.temp_allocator)
}

// Whether `path` holds the pinned bytes: by its stamp, or by hashing when
// `verify` is set or the stamp is missing.
@(private)
holds :: proc(path, sha256: string, size: i64, verify: bool) -> bool {
	info, err := os.stat(path, context.temp_allocator)
	if err != nil || info.size != size {
		return false
	}
	if !verify {
		stamp, serr := os.read_entire_file(stamp_path(path), context.temp_allocator)
		if serr == nil && strings.trim_space(string(stamp)) == sha256 {
			return true
		}
	}
	got, herr := hash_file(path)
	if herr != nil || got != sha256 {
		return false
	}
	_ = os.write_entire_file(stamp_path(path), sha256)
	return true
}

Progress :: proc(message: string)

// Progress lines on stderr.
progress_stderr :: proc(message: string) {
	fmt.eprintfln("odawg: %s", message)
}

@(private)
say :: proc(progress: Progress, format: string, args: ..any) {
	if progress != nil {
		progress(fmt.tprintf(format, ..args))
	}
}

// Makes the data directory hold the register file's pinned bytes,
// downloading them when it doesn't.
ensure_file :: proc(root: string, f: ^File_Row, verify := false) -> Error {
	_, _, err := ensure_pinned(file_path(root, f), file_url(f), f.sha256, f.size, verify)
	return err
}

// Makes `path` hold the bytes at `url` pinned by `sha256` and `size`,
// downloading them when it doesn't. An empty pin (a file odawg pin is
// pinning) takes what comes once, and gives its SHA-256 and size (in the
// temp allocator) for the pins.
ensure_pinned :: proc(path, url, sha256: string, size: i64, verify := false) -> (got: string, got_size: i64, err: Error) {
	if sha256 != "" && holds(path, sha256, size, verify) {
		return sha256, size, nil
	}
	if sha256 == "" {
		// fetched once already: what its stamp says it was
		stamp, serr := os.read_entire_file(stamp_path(path), context.temp_allocator)
		info, ierr := os.stat(path, context.temp_allocator)
		if serr == nil && ierr == nil {
			return strings.trim_space(string(stamp)), info.size, nil
		}
	}
	if derr := os.make_directory_all(filepath.dir(path)); derr != nil && derr != .Exist {
		return "", 0, fmt.tprintf("creating %s: %v", filepath.dir(path), derr)
	}
	part := strings.concatenate({path, ".part"}, context.temp_allocator)
	file, cerr := os.create(part)
	if cerr != nil {
		return "", 0, fmt.tprintf("creating %s: %v", part, cerr)
	}
	sink := Sink{file = file}
	sha2.init_256(&sink.hash)
	get_err := http_get(url, &sink)
	os.close(file)
	if get_err != nil {
		os.remove(part)
		return "", 0, get_err
	}
	got = hex_digest(&sink.hash)
	if sha256 != "" && (got != sha256 || sink.written != size) {
		os.remove(part)
		return "", 0, fmt.tprintf("%s: got %d bytes with SHA-256 %s, pinned %d bytes with %s", url, sink.written, got, size, sha256)
	}
	os.remove(path)
	if rerr := os.rename(part, path); rerr != nil {
		return "", 0, fmt.tprintf("renaming %s: %v", part, rerr)
	}
	_ = os.write_entire_file(stamp_path(path), got)
	return got, sink.written, nil
}

// The files a set's zones play, each once, in zone order.
set_files :: proc(s: ^Set_Row, allocator := context.temp_allocator) -> (files: [dynamic]^File_Row, err: Error) {
	files = make([dynamic]^File_Row, allocator)
	for &z in set_zones(s) {
		i, ok := file_index_from_path(s.source, z.path)
		if !ok {
			return files, fmt.tprintf("%s: %s is not pinned", s.name, z.path)
		}
		f := &FILE_TABLE[i]
		seen := false
		for g in files {
			if g == f {
				seen = true
				break
			}
		}
		if !seen {
			append(&files, f)
		}
	}
	return files, nil
}

// Whether every file of the set is on disk with its pin (by stamp).
set_present :: proc(root: string, s: ^Set_Row) -> bool {
	files, err := set_files(s)
	if err != nil {
		return false
	}
	for f in files {
		if !holds(file_path(root, f), f.sha256, f.size, false) {
			return false
		}
	}
	return true
}

// Makes the data directory hold every file of the set, downloading what is
// missing (progress: one line for the set, one per file fetched).
ensure_set :: proc(root: string, s: ^Set_Row, verify := false, progress: Progress = progress_stderr) -> Error {
	files := set_files(s) or_return
	missing := make([dynamic]^File_Row, context.temp_allocator)
	bytes: i64
	for f in files {
		if !holds(file_path(root, f), f.sha256, f.size, verify) {
			append(&missing, f)
			bytes += f.size
		}
	}
	if len(missing) == 0 {
		return nil
	}
	src := &SOURCE_TABLE[s.source]
	say(progress, "fetching %s: %d files, %.1f MB, from %s (%s)", s.name, len(missing), f64(bytes) / 1e6, src.page, LICENCE_TABLE[src.licence].spdx)
	done: i64
	for f, i in missing {
		say(progress, "  [%d/%d] %s (%.1f of %.1f MB)", i + 1, len(missing), f.path, f64(done + f.size) / 1e6, f64(bytes) / 1e6)
		ensure_file(root, f, verify) or_return
		done += f.size
	}
	return nil
}
