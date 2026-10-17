package odawg_base

import "core:fmt"
import "core:strings"

// What the reader and the checks report, as rows of one table: a code a
// host acts on (`unknown_key`, `true_peak`, `start_unreachable`), how bad,
// where (a `/` path into the spec: `sections/drop/bpm`, `parts/bass`), and a
// sentence for people.

Severity :: enum u8 {
	Info,
	Warning,
	Error,
}

Finding :: struct {
	code:     string,
	severity: Severity,
	path:     string,
	message:  string,
}

Findings :: [dynamic]Finding

// Appends a finding; its strings live in the findings' allocator.
report :: proc(findings: ^Findings, code: string, severity: Severity, path: string, format: string, args: ..any) {
	if findings == nil {
		return
	}
	a := findings.allocator
	append(findings, Finding{code, severity, strings.clone(path, a), fmt.aprintf(format, ..args, allocator = a)})
}

has_errors :: proc(findings: []Finding) -> bool {
	for f in findings {
		if f.severity == .Error {
			return true
		}
	}
	return false
}

// `a/b` paths: nesting is `/`, never `.` or `[]`.
path_join :: proc(path, key: string, allocator := context.temp_allocator) -> string {
	return path == "" ? strings.clone(key, allocator) : strings.concatenate({path, "/", key}, allocator)
}

path_index :: proc(path: string, i: int, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s/%d", path, i, allocator = allocator)
}
