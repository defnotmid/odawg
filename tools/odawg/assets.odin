package main

import "core:fmt"
import "core:os"
import "core:strings"
import assets "deps:odawg/assets"
import base "deps:odawg/base"
import spec "deps:odawg/spec"

// The sample sets on the command line: `fetch`, `credits` and `sets`. A
// positional argument is a set's name or a spec (`.json`), which stands for
// the sets it plays.
//
//     odawg fetch [SET|SPEC ...] [--verify]     every set when none is named
//     odawg credits SPEC|SET ...
//     odawg sets

// The set names the arguments give (a spec's own sets for a spec), and
// whether every argument was understood.
@(private = "file")
set_names_from_args :: proc(a: ^Args) -> (names: [dynamic]string, ok: bool) {
	names = make([dynamic]string, context.temp_allocator)
	ok = true
	for arg in a.positional {
		switch {
		case arg == "--verify":
		case strings.has_suffix(arg, ".json"):
			text, err := os.read_entire_file(arg, context.temp_allocator)
			if err != nil {
				fmt.eprintfln("odawg: can't read %s", arg)
				ok = false
				continue
			}
			s: spec.Spec
			findings := make(base.Findings, context.temp_allocator)
			if !spec.spec_from_json(string(text), &s, &findings) {
				print_findings(findings[:])
				ok = false
				continue
			}
			spec.asset_names(&s, &names)
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
	names, ok := set_names_from_args(a)
	if !ok {
		return false
	}
	verify := false
	for arg in a.positional {
		verify ||= arg == "--verify"
	}
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
	names, ok := set_names_from_args(a)
	if !ok {
		return false
	}
	if len(names) == 0 {
		fmt.println("no sample sets: everything is synthesized")
		return true
	}
	for line in assets.credits_from_names(names[:], context.temp_allocator) {
		fmt.println(line)
	}
	return true
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
