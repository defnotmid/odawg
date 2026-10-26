package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import assets "deps:odawg/assets"
import base "deps:odawg/base"
import spec "deps:odawg/spec"

// The sample sets on the command line: `fetch`, `credits`, `sets` and
// `pin`. A positional argument is a set's name or a spec (`.json`), which
// stands for the register's sets it plays (and, for credits, its sources).
//
//     odawg fetch [SET|SPEC ...] [--verify]     every set when none is named
//     odawg credits SPEC|SET ...
//     odawg sets
//     odawg pin SPEC

// The register's set names the arguments give (a spec's for a spec), the
// sources the specs fetch from, and whether every argument was understood.
@(private = "file")
set_names_from_args :: proc(a: ^Args) -> (names: [dynamic]string, ok: bool, sources: [dynamic]spec.Source_Ref) {
	names = make([dynamic]string, context.temp_allocator)
	sources = make([dynamic]spec.Source_Ref, context.temp_allocator)
	ok = true
	for arg in a.positional {
		switch {
		case strings.has_suffix(arg, ".json"):
			text, err := os.read_entire_file(arg, context.temp_allocator)
			if err != nil {
				fmt.eprintfln("odawg: can't read %s", arg)
				ok = false
				continue
			}
			s := new(spec.Spec, context.temp_allocator)
			findings := make(base.Findings, context.temp_allocator)
			if !spec.spec_from_json(string(text), s, &findings) {
				print_findings(findings[:])
				ok = false
				continue
			}
			host := assets.Bank_Host{root = filepath.dir(arg)}
			read_style_files(&host, s, &findings) // a style file's sets and sources are the song's too
			// the register's: a song's own sets and SFZ files are its files'
			all := make([dynamic]string, context.temp_allocator)
			spec.asset_names(s, &all)
			for n in all {
				if _, found := assets.set_row_from_name(n); found {
					append(&names, n)
				}
			}
			spec.source_refs(s, &sources)
		case:
			if _, found := assets.set_row_from_name(arg); !found {
				fmt.eprintfln("odawg: no sample set %q (odawg sets lists them)", arg)
				ok = false
				continue
			}
			append(&names, arg)
		}
	}
	return
}

// Downloads (and verifies) the named sets, or every set.
run_fetch :: proc(a: ^Args) -> bool {
	names, ok, _ := set_names_from_args(a)
	if !ok {
		return false
	}
	verify := a.verify
	if len(names) == 0 {
		for s in assets.SET_TABLE {
			append(&names, s.name)
		}
	}
	root, err := assets.data_dir(context.temp_allocator)
	if err != nil {
		fmt.eprintfln("odawg fetch: %s", err.?)
		return false
	}
	all := true
	for name in names {
		s, _ := assets.set_row_from_name(name)
		if ferr := assets.ensure_set(root, s, verify); ferr != nil {
			fmt.eprintfln("odawg fetch: %s: %s", name, ferr.?)
			all = false
			continue
		}
		fmt.printfln("%s: in %s", name, root)
	}
	return all
}

// The credit lines for what a spec plays (or the named sets).
run_credits :: proc(a: ^Args) -> bool {
	names, ok, sources := set_names_from_args(a)
	if !ok {
		return false
	}
	if len(names) == 0 && len(sources) == 0 {
		fmt.println("no sample sets: everything is synthesized")
		return true
	}
	for line in assets.credits_from_names(names[:], context.temp_allocator) {
		fmt.println(line)
	}
	for src in sources {
		credit := src.credit != "" ? src.credit : src.name
		fmt.printfln("%s, %s (%s)", credit, src.licence, src.page != "" ? src.page : src.url)
	}
	return true
}

// odawg pin: fetches what the song's notes reach from its sources that
// their pins don't list yet, and writes each source's pins file (sorted,
// the earlier rows kept). What comes is trusted on first use: read the
// source's licence and look over the new rows before committing them.
run_pin :: proc(a: ^Args) -> bool {
	l: Loaded
	ok := load(a, &l, pinning = true)
	if !ok {
		print_findings(l.findings[:])
		return false
	}
	host := assets.Bank_Host{root = filepath.dir(a.positional[0])}
	updates := assets.pins_update(&l.bank, &l.spec, &host, &l.findings, context.temp_allocator)
	print_findings(l.findings[:])
	if len(updates) == 0 {
		fmt.println("odawg pin: no pins to write (the song names no sources in its folder)")
		return !base.has_errors(l.findings[:])
	}
	all := true
	for u in updates {
		path := assets.host_path(&host, u.pins_path)
		if werr := os.write_entire_file(path, u.text); werr != nil {
			fmt.eprintfln("odawg pin: can't write %s: %v", path, werr)
			all = false
			continue
		}
		fmt.printfln("%s: %d pinned (%d new) in %s, licence %s", u.source, u.total, u.added, path, u.licence)
	}
	// what was fetched is pinned either way; a file that couldn't be (its
	// error above) fails the command, so a script running it knows
	return all && !base.has_errors(l.findings[:])
}

// The register: every set, its licence, its download size and whether it
// is on disk.
run_sets :: proc(a: ^Args) -> bool {
	root, _ := assets.data_dir(context.temp_allocator)
	for &s in assets.SET_TABLE {
		files, _ := assets.set_files(&s)
		size: i64
		for f in files {
			size += f.size
		}
		src := &assets.SOURCE_TABLE[s.source]
		mb := fmt.tprintf("%.1f MB", f64(size) / 1e6)
		fmt.printfln("%-22s %-9s %-9s  %-8s %s", s.name, assets.LICENCE_TABLE[src.licence].spdx, mb, assets.set_present(root, &s) ? "on disk" : "", s.about)
	}
	return true
}
