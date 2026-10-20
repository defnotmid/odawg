package odawg_spec

import "base:runtime"
import "core:math"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import base "../base"
import theory "../theory"

// SFZ, the format sample libraries ship in, read into flat tables: every
// region a span of opcodes (what its <global>, <master> and <group> set,
// then its own: the last of a name wins), the <curve>s, and what <control>
// sets (default_path, note and octave offsets, each CC's value and label).
// `#define $NAME value` replaces $NAME in what follows; `#include "file"`
// reads another file of the instrument in place (a path from the first
// file's folder, its text handed over by the host as the instrument's own).
//
// Which opcodes there are is the SFZ reference's table (sfz_opcodes.tsv:
// sfz.github.io's syntax data, CC0), with how odawg reads each. A name the
// reference doesn't have is a finding (unknown_opcode, once per file with
// its count and first region), never silently dropped.

SFZ_OPCODES_TEXT :: #load("sfz_opcodes.tsv", string)

// How odawg reads an opcode.
Sfz_Status :: enum u8 {
	Warn, // not played: a warning names it (the sound differs from SFZ's)
	Plays, // it sounds as SFZ says
	Compile, // read once, at compile (a CC at its value)
	Info, // doesn't change the sound (a label, a default for a knob)
}

Sfz_Opcode_Row :: struct {
	name:     string, // N, X, Y, Z: a number
	version:  string,
	category: string,
	alias_of: string, // "": none
	status:   Sfz_Status,
}

SFZ_OPCODES: [dynamic]Sfz_Opcode_Row

@(init, private = "file")
sfz_opcodes_init :: proc "contextless" () {
	context = runtime.default_context()
	for line in strings.split_lines(SFZ_OPCODES_TEXT) {
		if line == "" || line[0] == '#' {
			continue
		}
		f := strings.split(line, "\t")
		if len(f) < 5 {
			continue
		}
		row := Sfz_Opcode_Row{name = f[0], version = f[1], category = f[2], alias_of = f[3]}
		switch f[4] {
		case "plays":
			row.status = .Plays
		case "compile":
			row.status = .Compile
		case "info":
			row.status = .Info
		}
		append(&SFZ_OPCODES, row)
	}
	SFZ_EXACT = make(map[string]int, len(SFZ_OPCODES))
	for r, i in SFZ_OPCODES {
		if strings.index_any(r.name, "NXYZ") >= 0 {
			append(&SFZ_PATTERNS, i)
		} else if r.name not_in SFZ_EXACT {
			SFZ_EXACT[r.name] = i
		}
	}
}

// Whether `name` is an opcode of the row's name pattern: a run of N, X, Y
// or Z in the pattern is a number in the name.
sfz_name_matches :: proc(pattern, name: string) -> bool {
	i, j := 0, 0
	for i < len(pattern) {
		c := pattern[i]
		if c == 'N' || c == 'X' || c == 'Y' || c == 'Z' {
			for i < len(pattern) && (pattern[i] == 'N' || pattern[i] == 'X' || pattern[i] == 'Y' || pattern[i] == 'Z') {
				i += 1
			}
			start := j
			for j < len(name) && name[j] >= '0' && name[j] <= '9' {
				j += 1
			}
			if j == start {
				return false
			}
			continue
		}
		if j >= len(name) || name[j] != c {
			return false
		}
		i += 1
		j += 1
	}
	return j == len(name)
}

// How an opcode's value moves it by a CC (SFZ v2: any opcode may take one
// of these suffixes, `cutoff_oncc74`; v1 wrote `cutoffcc74`).
Sfz_Cc_Mod :: enum u8 {
	None,
	On, // _onccN (and v1's ccN): the value at CC 127, added
	Curve, // _curveccN: the curve it is read through
	Smooth, // _smoothccN: how fast it follows (a CC at one value: nothing)
	Step, // _stepccN: its steps (likewise)
}

// An opcode's name read: its reference row (-1: none), the numbers in its
// name (lfo2_freq: 2) and, for a CC's form of another opcode (cutoff_oncc1,
// v1's cutoff_cc1; the reference lists some forms as rows of their own),
// the opcode it moves (`base`, its row; -1: none), how (`mod`) and by which CC.
Sfz_Name :: struct {
	row:     int,
	base:    int,
	mod:     Sfz_Cc_Mod,
	cc:      int,
	numbers: [4]int,
	count:   int,
}

@(private = "file")
SFZ_CC_SUFFIXES := [?]struct {
	suffix: string,
	mod:    Sfz_Cc_Mod,
} {{"_oncc", .On}, {"_curvecc", .Curve}, {"_smoothcc", .Smooth}, {"_stepcc", .Step}, {"_cc", .On}, {"cc", .On}}

sfz_name :: proc(name: string) -> (n: Sfz_Name) {
	n.row, n.base = sfz_row_of(name), -1
	// a CC's form of an opcode the reference has: its row, unless the
	// reference lists the form itself
	digits := len(name)
	for digits > 0 && name[digits - 1] >= '0' && name[digits - 1] <= '9' {
		digits -= 1
	}
	if digits < len(name) {
		for x in SFZ_CC_SUFFIXES {
			if strings.has_suffix(name[:digits], x.suffix) {
				if row := sfz_row_of(name[:digits - len(x.suffix)]); row >= 0 {
					n.base, n.mod = row, x.mod
					n.cc, _ = strconv.parse_int(name[digits:])
					break
				}
			}
		}
	}
	if n.row < 0 {
		n.row = n.base
	}
	for k := 0; k < len(name) && n.count < 4; {
		if name[k] < '0' || name[k] > '9' {
			k += 1
			continue
		}
		start := k
		for k < len(name) && name[k] >= '0' && name[k] <= '9' {
			k += 1
		}
		n.numbers[n.count], _ = strconv.parse_int(name[start:k])
		n.count += 1
	}
	return
}

// The opcode a CC's form moves, as its own name reads (cutoff_oncc1:
// cutoff; lfo1_freq_oncc2: lfo1_freq); n itself when it is none.
sfz_moved :: proc(n: Sfz_Name) -> Sfz_Name {
	if n.base < 0 {
		return n
	}
	m := Sfz_Name{row = n.base, base = -1, count = max(n.count - 1, 0)}
	for i in 0 ..< m.count {
		m.numbers[i] = n.numbers[i]
	}
	return m
}

// A name's row: an exact name's from SFZ_EXACT, else the first pattern (N,
// X, Y) it matches.
@(private = "file")
sfz_row_of :: proc(name: string) -> int {
	if row, found := SFZ_EXACT[name]; found {
		return row
	}
	for i in SFZ_PATTERNS {
		if sfz_name_matches(SFZ_OPCODES[i].name, name) {
			return i
		}
	}
	return -1
}

// The row the reference names `name` (a pattern's too: loccN). -1: none.
sfz_row_named :: proc(name: string) -> int {
	if row, found := SFZ_EXACT[name]; found {
		return row
	}
	for i in SFZ_PATTERNS {
		if SFZ_OPCODES[i].name == name {
			return i
		}
	}
	return -1
}

// The rows by name, for the names without a number in them, and the rows
// whose names have one (filled at init, read only after).
@(private = "file")
SFZ_EXACT: map[string]int
@(private = "file")
SFZ_PATTERNS: [dynamic]int

// The names SFZ files write that the reference spells otherwise (older
// players' spellings; sfizz reads them too).
@(private = "file")
SFZ_SPELLINGS := [?][2]string {
	{"loopmode", "loop_mode"},
	{"loopstart", "loop_start"},
	{"loopend", "loop_end"},
	{"bendup", "bend_up"},
	{"benddown", "bend_down"},
	{"bendstep", "bend_step"},
	{"offmode", "off_mode"},
	{"rtdecay", "rt_decay"},
}

// A name's numbers without their leading zeros (eg01_time1 is eg1_time1).
sfz_unpadded :: proc(name: string) -> string {
	if strings.index(name, "0") < 0 {
		return name
	}
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(name); i += 1 {
		c := name[i]
		if c == '0' && (i == 0 || name[i - 1] < '0' || name[i - 1] > '9') && i + 1 < len(name) && name[i + 1] >= '0' && name[i + 1] <= '9' {
			continue // a leading zero of a number (not a lone 0)
		}
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}

// One opcode as written: its name (spelled as the reference does) and
// value, $defines replaced.
Sfz_Opcode :: struct {
	name:  string,
	value: string,
	read:  Sfz_Name, // what the name is (sfz_name's), found once as it is read
}

Sfz_Region :: struct {
	opcodes: Span, // into Sfz.opcodes: inherited, then its own (the last of a name wins)
	file:    string, // where it was written
	line:    i32,
}

// A <curve>: 128 points (the vNNN given, straight between them).
Sfz_Curve :: struct {
	index:  int,
	points: [128]f32,
}

Sfz_Unknown :: struct {
	name:  string,
	count: int,
	file:  string,
	line:  i32, // the first one's
}

Sfz :: struct {
	opcodes:       [dynamic]Sfz_Opcode,
	regions:       [dynamic]Sfz_Region,
	curves:        [dynamic]Sfz_Curve,
	effects:       int, // <effect> headers (not played)
	default_path:  string,
	note_offset:   int,
	octave_offset: int,
	cc:            [128]f32, // each CC's value: set_ccN's, else SFZ's default
	cc_set:        bit_set[0 ..< 128;u128], // given by set_ccN
	cc_labels:     [128]string,
	files:         [dynamic]string, // the file, then what it includes, each once
	missing:       [dynamic]string, // included but not handed over
	unknown:       [dynamic]Sfz_Unknown,
}

// SFZ's defaults for a CC nothing sets: volume 100, pan 64, expression 127.
sfz_cc_default :: proc(cc: int) -> f32 {
	switch cc {
	case 7:
		return 100
	case 10:
		return 64
	case 11:
		return 127
	}
	return 0
}

// An SFZ instrument from the file at `path`, its own text and, by path,
// what it includes (`texts`: the host's; one it lacks goes in `missing`).
sfz_read :: proc(out: ^Sfz, path, text: string, texts: map[string]string, allocator := context.allocator) {
	context.allocator = allocator
	out^ = {}
	for k in 0 ..< 128 {
		out.cc[k] = sfz_cc_default(k)
	}
	r := Sfz_Reader{out = out, texts = texts, folder = filepath.dir(path)}
	r.defines = make(map[string]string, context.temp_allocator)
	for &l in r.levels {
		l = make([dynamic]Sfz_Opcode, context.temp_allocator)
	}
	sfz_file(&r, path, text, 0)
	sfz_close_region(&r)
	sfz_close_curve(&r)
}

@(private = "file")
Sfz_Level :: enum {
	Global,
	Master,
	Group,
	Region,
}

@(private = "file")
Sfz_Header :: enum {
	None,
	Control,
	Global,
	Master,
	Group,
	Region,
	Curve,
	Effect, // and any header odawg doesn't play: its opcodes are skipped
}

@(private = "file")
Sfz_Reader :: struct {
	out:       ^Sfz,
	texts:     map[string]string,
	folder:    string,
	defines:   map[string]string,
	header:    Sfz_Header,
	levels:    [Sfz_Level][dynamic]Sfz_Opcode,
	region_at: struct {
		file: string,
		line: i32,
	},
	open:      bool, // a region is being read
	curve:     Sfz_Curve,
	curve_set: [128]bool,
	in_curve:  bool,
	comment:   bool, // inside /* */
}

@(private = "file")
sfz_file :: proc(r: ^Sfz_Reader, path, text: string, depth: int) {
	append(&r.out.files, strings.clone(path))
	line_no: i32 = 0
	for raw in strings.split_lines(text, context.temp_allocator) {
		line_no += 1
		line := sfz_strip_comments(r, raw)
		// its directives, wherever they are on it (`<master> ... #include
		// "x.sfz"`, two #defines on one line), the rest read between them
		for len(line) > 0 {
			at := sfz_directive(line)
			if at < 0 {
				sfz_line(r, path, line_no, sfz_defined(r, line))
				break
			}
			if at > 0 {
				sfz_line(r, path, line_no, sfz_defined(r, line[:at]))
			}
			rest := line[at:]
			if strings.has_prefix(rest, "#define") {
				rest = strings.trim_left_space(rest[len("#define"):])
				name, after := sfz_token(rest)
				value, after2 := sfz_token(strings.trim_left_space(after))
				if name != "" {
					r.defines[strings.clone(name)] = strings.clone(sfz_defined(r, value))
				}
				line = after2
				continue
			}
			// a $define may hold the path, quotes and all
			rest = strings.trim_left_space(sfz_defined(r, rest[len("#include"):]))
			name: string
			if strings.has_prefix(rest, "\"") {
				end := strings.index_byte(rest[1:], '"')
				if end < 0 {
					name, line = rest[1:], ""
				} else {
					name, line = rest[1:1 + end], rest[2 + end:]
				}
			} else {
				name, line = sfz_token(rest)
			}
			name, _ = strings.replace_all(name, "\\", "/", context.temp_allocator)
			full, _ := filepath.join({r.folder, name}, context.temp_allocator)
			if depth > 16 {
				continue
			}
			if t, found := r.texts[full]; found {
				sfz_file(r, full, t, depth + 1)
			} else {
				append(&r.out.missing, strings.clone(full))
			}
		}
	}
}

// Where the line's next #define or #include starts (-1: none).
@(private = "file")
sfz_directive :: proc(line: string) -> int {
	for i := 0; i < len(line); i += 1 {
		if line[i] == '#' && (strings.has_prefix(line[i:], "#define") || strings.has_prefix(line[i:], "#include")) {
			return i
		}
	}
	return -1
}

// The text up to the next space, and what follows it.
@(private = "file")
sfz_token :: proc(s: string) -> (token, rest: string) {
	end := strings.index_any(s, " \t\r")
	if end < 0 {
		return s, ""
	}
	return s[:end], s[end:]
}

// A line without its comments (`//` to its end; `/* */`, across lines).
@(private = "file")
sfz_strip_comments :: proc(r: ^Sfz_Reader, line: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(line) {
		if r.comment {
			end := strings.index(line[i:], "*/")
			if end < 0 {
				return strings.to_string(b)
			}
			i += end + 2
			r.comment = false
			continue
		}
		if strings.has_prefix(line[i:], "//") {
			break
		}
		if strings.has_prefix(line[i:], "/*") {
			r.comment = true
			i += 2
			continue
		}
		strings.write_byte(&b, line[i])
		i += 1
	}
	return strings.to_string(b)
}

// `s` with every $NAME defined so far replaced (the longest name first).
@(private = "file")
sfz_defined :: proc(r: ^Sfz_Reader, s: string) -> string {
	if strings.index_byte(s, '$') < 0 || len(r.defines) == 0 {
		return s
	}
	out := s
	for {
		at := strings.index_byte(out, '$')
		if at < 0 {
			return out
		}
		best := ""
		for name in r.defines {
			if len(name) > len(best) && strings.has_prefix(out[at:], name) {
				best = name
			}
		}
		if best == "" {
			// not defined: left as written, the rest still replaced
			rest := sfz_defined(r, out[at + 1:])
			return strings.concatenate({out[:at + 1], rest}, context.temp_allocator)
		}
		out = strings.concatenate({out[:at], r.defines[best], out[at + len(best):]}, context.temp_allocator)
	}
}

// A line's headers and opcodes, in order. A value runs to the next name=
// or header on the line (a sample's path may hold spaces).
@(private = "file")
sfz_line :: proc(r: ^Sfz_Reader, file: string, line_no: i32, line: string) {
	src := line
	i := 0
	for i < len(src) {
		c := src[i]
		if c == ' ' || c == '\t' || c == '\r' {
			i += 1
			continue
		}
		if c == '<' {
			end := strings.index_byte(src[i:], '>')
			if end < 0 {
				return
			}
			sfz_header(r, src[i + 1:i + end], file, line_no)
			i += end + 1
			continue
		}
		eq := strings.index_byte(src[i:], '=')
		if eq < 0 {
			return
		}
		name := strings.trim_space(src[i:i + eq])
		if sp := strings.last_index_any(name, " \t"); sp >= 0 {
			name = name[sp + 1:]
		}
		rest := src[i + eq + 1:]
		stop := len(rest)
		if lt := strings.index_byte(rest, '<'); lt >= 0 {
			stop = lt
		}
		if next_eq := strings.index_byte(rest[:stop], '='); next_eq >= 0 {
			cut := strings.last_index_any(rest[:next_eq], " \t")
			stop = cut >= 0 ? cut : next_eq
		}
		value := strings.trim_space(rest[:stop])
		i += eq + 1 + stop
		sfz_opcode(r, file, line_no, name, value)
	}
}

@(private = "file")
sfz_header :: proc(r: ^Sfz_Reader, name, file: string, line_no: i32) {
	sfz_close_region(r)
	sfz_close_curve(r)
	switch name {
	case "control":
		r.header = .Control
	case "global":
		r.header = .Global
		clear(&r.levels[.Global])
		clear(&r.levels[.Master])
		clear(&r.levels[.Group])
	case "master":
		r.header = .Master
		clear(&r.levels[.Master])
		clear(&r.levels[.Group])
	case "group":
		r.header = .Group
		clear(&r.levels[.Group])
	case "region":
		r.header = .Region
		clear(&r.levels[.Region])
		r.open = true
		r.region_at = {file, line_no}
	case "curve":
		r.header = .Curve
		r.in_curve = true
		r.curve = {}
		r.curve_set = {}
	case "effect":
		r.header = .Effect
		r.out.effects += 1
	case:
		r.header = .Effect
		sfz_unknown(r, strings.concatenate({"<", name, ">"}, context.temp_allocator), file, line_no)
	}
}

@(private = "file")
sfz_opcode :: proc(r: ^Sfz_Reader, file: string, line_no: i32, written, value: string) {
	// names are matched as lower case (some files write `Sample=`)
	name := strings.to_lower(written, context.temp_allocator)
	if name == "" {
		return
	}
	for s in SFZ_SPELLINGS {
		if s[0] == name {
			name = s[1]
		}
	}
	name = sfz_unpadded(name)
	switch r.header {
	case .None, .Effect:
		return
	case .Curve:
		if name == "curve_index" {
			r.curve.index, _ = strconv.parse_int(value)
		} else if len(name) > 1 && name[0] == 'v' {
			if k, ok := strconv.parse_int(name[1:]); ok && k >= 0 && k < 128 {
				v, _ := strconv.parse_f64(value)
				r.curve.points[k] = f32(v)
				r.curve_set[k] = true
			}
		}
		return
	case .Control:
		if sfz_control(r, name, value) {
			return
		}
	case .Global, .Master, .Group, .Region:
	}
	n := sfz_name(name)
	if n.row < 0 {
		sfz_unknown(r, name, file, line_no)
	}
	level := Sfz_Level.Region
	#partial switch r.header {
	case .Control, .Global:
		level = .Global
	case .Master:
		level = .Master
	case .Group:
		level = .Group
	}
	append(&r.levels[level], Sfz_Opcode{strings.clone(name), strings.clone(value), n})
}

// What <control> sets for the whole instrument. False: an opcode of the
// regions' (<control> gives it to every region, as <global> does).
@(private = "file")
sfz_control :: proc(r: ^Sfz_Reader, name, value: string) -> bool {
	switch name {
	case "default_path":
		r.out.default_path, _ = strings.replace_all(value, "\\", "/")
		return true
	case "note_offset":
		r.out.note_offset, _ = strconv.parse_int(value)
		return true
	case "octave_offset":
		r.out.octave_offset, _ = strconv.parse_int(value)
		return true
	}
	n := sfz_name(name)
	if n.count == 1 && n.numbers[0] >= 0 && n.numbers[0] < 128 {
		cc := n.numbers[0]
		v, _ := strconv.parse_f64(value)
		switch {
		case strings.has_prefix(name, "set_cc"):
			r.out.cc[cc], r.out.cc_set = f32(v), r.out.cc_set + {cc}
			return true
		case strings.has_prefix(name, "set_hdcc"), strings.has_prefix(name, "set_realcc"):
			r.out.cc[cc], r.out.cc_set = f32(v * 127), r.out.cc_set + {cc}
			return true
		case strings.has_prefix(name, "label_cc"):
			r.out.cc_labels[cc] = strings.clone(value)
			return true
		}
	}
	return false
}

@(private = "file")
sfz_close_region :: proc(r: ^Sfz_Reader) {
	if !r.open {
		return
	}
	r.open = false
	at := i32(len(r.out.opcodes))
	for level in Sfz_Level {
		append(&r.out.opcodes, ..r.levels[level][:])
	}
	append(&r.out.regions, Sfz_Region{opcodes = {at, i32(len(r.out.opcodes)) - at}, file = strings.clone(r.region_at.file), line = r.region_at.line})
}

// A curve's points: those given, straight between them (0 and 1 at its
// ends when not given).
@(private = "file")
sfz_close_curve :: proc(r: ^Sfz_Reader) {
	if !r.in_curve {
		return
	}
	r.in_curve = false
	c := r.curve
	if !r.curve_set[0] {
		c.points[0], r.curve_set[0] = 0, true
	}
	if !r.curve_set[127] {
		c.points[127], r.curve_set[127] = 1, true
	}
	last := 0
	for k in 1 ..< 128 {
		if !r.curve_set[k] {
			continue
		}
		for j in last + 1 ..< k {
			t := f32(j - last) / f32(k - last)
			c.points[j] = c.points[last] + (c.points[k] - c.points[last]) * t
		}
		last = k
	}
	append(&r.out.curves, c)
}

@(private = "file")
sfz_unknown :: proc(r: ^Sfz_Reader, name, file: string, line_no: i32) {
	for &u in r.out.unknown {
		if u.name == name {
			u.count += 1
			return
		}
	}
	append(&r.out.unknown, Sfz_Unknown{strings.clone(name), 1, strings.clone(file), line_no})
}

// ---- a region's values ----------------------------------------------------------------

// The value a region gives `name` (the last written), else "".
sfz_value :: proc(s: ^Sfz, region: int, name: string) -> (string, bool) {
	sp := s.regions[region].opcodes
	#reverse for op in s.opcodes[sp.first:base.span_end(sp)] {
		if op.name == name {
			return op.value, true
		}
	}
	return "", false
}

// The value a region gives the opcode read as `n` (the last written).
sfz_value_of :: proc(s: ^Sfz, region: int, n: Sfz_Name) -> (string, bool) {
	sp := s.regions[region].opcodes
	#reverse for op in s.opcodes[sp.first:base.span_end(sp)] {
		if op.read == n {
			return op.value, true
		}
	}
	return "", false
}

sfz_number :: proc(s: ^Sfz, region: int, name: string, fallback: f64) -> f64 {
	v, found := sfz_value(s, region, name)
	if !found {
		return fallback
	}
	n, ok := strconv.parse_f64(v)
	return ok ? n : fallback
}

// A key as a number or a note name (c4 is 60, as SFZ has it), moved by the
// instrument's note and octave offsets.
sfz_key :: proc(s: ^Sfz, v: string, fallback: int) -> int {
	k := fallback
	if n, ok := strconv.parse_int(v); ok {
		k = n
	} else if len(v) > 0 {
		name := strings.concatenate({strings.to_upper(v[:1], context.temp_allocator), v[1:]}, context.temp_allocator)
		if p, ok := theory.pitch_from_string(name); ok {
			k = int(math.round(p))
		} else {
			return fallback
		}
	} else {
		return fallback
	}
	return k + s.note_offset + 12 * s.octave_offset
}

// A curve by index (nil: none of that index).
sfz_curve :: proc(s: ^Sfz, index: int) -> ^Sfz_Curve {
	for &c in s.curves {
		if c.index == index {
			return &c
		}
	}
	return nil
}

// How many of s's regions give each opcode of the reference (by row of
// SFZ_OPCODES; a name given twice counts once).
sfz_coverage :: proc(s: ^Sfz, counts: []int) {
	seen := make([]bool, len(SFZ_OPCODES), context.temp_allocator)
	for r in s.regions {
		for &x in seen {
			x = false
		}
		for op in s.opcodes[r.opcodes.first:base.span_end(r.opcodes)] {
			if row := op.read.row; row >= 0 && !seen[row] {
				seen[row] = true
				counts[row] += 1
			}
		}
	}
}
