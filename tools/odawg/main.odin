// odawg: songs from JSON specs on the command line, with onimite's verbs.
// Every command is a row of COMMAND_TABLE; arguments are parsed once into
// Args and dispatched in one place.
//
//     odawg render song.json -o song.wav [--range drop] [--master streaming] [--stems DIR] [--float]
//     odawg timeline song.json [--json]
//     odawg show song.json parts/bass | sections/drop | style/house
//     odawg at song.json drop@1m
//     odawg inspect song.json [--range drop]
//     odawg analyze song.json [--master streaming] [--reference ref.wav] [--json]
//     odawg styles
package main

import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import assets "deps:odawg/assets"
import base "deps:odawg/base"
import check "deps:odawg/check"
import device "deps:odawg/device"
import render "deps:odawg/render"
import song "deps:odawg/song"
import spec "deps:odawg/spec"
import tempo "deps:odawg/tempo"
import theory "deps:odawg/theory"

Args :: struct {
	positional: [dynamic]string,
	out:        string,
	range:      string,
	master:     string,
	stems:      string,
	reference:  string,
	float:      bool,
	json:       bool,
	threads:    int,
}

Command_Row :: struct {
	name:  string,
	usage: string,
	about: string,
	run:   proc(a: ^Args) -> bool,
}

COMMAND_TABLE := []Command_Row {
	{"render", "render SPEC -o OUT.wav [--range R] [--master streaming|podcast|broadcast] [--stems DIR] [--float]", "the mix (and a WAV per stem with --stems: each part, return and bus)", run_render},
	{"timeline", "timeline SPEC [--json]", "sections (start, bars, tempo, style), parts and tracks, markers, findings", run_timeline},
	{"show", "show SPEC PATH [--json]", "one thing: sections/NAME, parts/NAME (its notes), style/NAME (its source)", run_show},
	{"at", "at SPEC POSITION", "what plays at a position: the section and bar, the chord, the notes sounding", run_at},
	{"inspect", "inspect SPEC [--range R]", "renders and reports: findings from the spec, the form and the sound", run_inspect},
	{"analyze", "analyze SPEC [--master M] [--reference REF.wav] [--json]", "what the sound is made of, per section, for the mix and every stem: loudness, true peak, crest, stereo width, 31 third-octave bands, the parts crowding each other; beside a reference recording's", run_analyze},
	{"styles", "styles", "the styles odawg ships", run_styles},
	{"sets", "sets", "the sample sets in the register: what each is, its licence and size", run_sets},
	{"fetch", "fetch [SET|SPEC ...] [--verify]", "downloads sample sets now (every set when none is named; songs fetch theirs on first use)", run_fetch},
	{"credits", "credits SPEC|SET ...", "what to credit for the sample sets a song plays", run_credits},
	{"bench", "bench SPEC ... [-o OUT.f32]", "how fast songs render on one core (seconds of sound per CPU second), the mix written raw to compare", run_bench},
}

main :: proc() {
	argv := os.args[1:]
	if len(argv) == 0 || argv[0] == "-h" || argv[0] == "--help" {
		usage()
		return
	}
	a: Args
	for i := 1; i < len(argv); i += 1 {
		next :: proc(argv: []string, i: ^int) -> string {
			i^ += 1
			return argv[i^] if i^ < len(argv) else ""
		}
		switch argv[i] {
		case "-o", "--out":
			a.out = next(argv, &i)
		case "--range":
			a.range = next(argv, &i)
		case "--master":
			a.master = next(argv, &i)
		case "--stems":
			a.stems = next(argv, &i)
		case "--reference":
			a.reference = next(argv, &i)
		case "--threads":
			a.threads = int(f64_from(next(argv, &i)))
		case "--float":
			a.float = true
		case "--json":
			a.json = true
		case:
			append(&a.positional, argv[i])
		}
	}
	for c in COMMAND_TABLE {
		if c.name == argv[0] {
			if !c.run(&a) {
				os.exit(1)
			}
			return
		}
	}
	fmt.eprintfln("odawg: no command %q", argv[0])
	usage()
	os.exit(2)
}

usage :: proc() {
	fmt.println("odawg: songs from specs, in Tone.js's vocabulary\n")
	for c in COMMAND_TABLE {
		fmt.printfln("  odawg %s\n      %s", c.usage, c.about)
	}
}

f64_from :: proc(s: string) -> f64 {
	l, ok := tempo.length_from_string(strings.concatenate({s, "s"}, context.temp_allocator), 4)
	return ok ? l.value : 0
}

// ---- loading -----------------------------------------------------------------------

Loaded :: struct {
	arena:    virtual.Arena,
	spec:     spec.Spec,
	song:     song.Song,
	bank:     device.Bank, // the sample sets its Samplers play (fetched on first use)
	findings: base.Findings,
}

// Reads and composes the spec named by the first positional argument; the
// findings so far go to stderr.
load :: proc(a: ^Args, l: ^Loaded) -> bool {
	if len(a.positional) == 0 {
		fmt.eprintln("odawg: give a spec (song.json)")
		return false
	}
	path := a.positional[0]
	text, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("odawg: can't read %s", path)
		return false
	}
	if virtual.arena_init_growing(&l.arena) != nil {
		return false
	}
	context.allocator = virtual.arena_allocator(&l.arena)
	l.findings = make(base.Findings)
	if !spec.spec_from_json(string(text), &l.spec, &l.findings) {
		print_findings(l.findings[:])
		return false
	}
	// the song's own files are from its folder: style files read in first,
	// then its sample sets declared (names to indices: the register's, its
	// own, SFZ files), then only the zones the notes reach loaded (the
	// register's fetched on first use)
	host := assets.Bank_Host{root = filepath.dir(path)}
	styles := make([dynamic]string)
	spec.style_files(&l.spec, &styles)
	for name in styles {
		text, rerr := os.read_entire_file(assets.host_path(&host, name), context.allocator)
		if rerr != nil {
			base.report(&l.findings, "missing_file", .Error, name, "style file %s can't be read", name)
			continue
		}
		spec.spec_add_style_text(&l.spec, name, string(text), &l.findings)
	}
	assets.bank_declare_spec(&l.bank, &l.spec, &l.findings, &host)
	ok := song.song_from_spec(&l.spec, &l.song, &l.bank)
	if ok && len(l.bank.sets) > 0 {
		needs := make([dynamic]device.Sample_Need)
		song.sample_needs(&l.song, &needs)
		assets.bank_load(&l.bank, needs[:], &l.findings, host = &host)
	}
	append(&l.findings, ..l.song.findings[:])
	return ok
}

SEVERITY_NAMES := [base.Severity]string {
	.Info    = "info",
	.Warning = "warning",
	.Error   = "error",
}

print_findings :: proc(fs: []base.Finding) {
	for f in fs {
		fmt.eprintfln("%s %s: %s", SEVERITY_NAMES[f.severity], f.code, f.message)
	}
}

// ---- commands ----------------------------------------------------------------------

run_render :: proc(a: ^Args) -> bool {
	l: Loaded
	if !load(a, &l) {
		return false
	}
	print_findings(l.findings[:])
	if base.has_errors(l.findings[:]) {
		return false
	}
	if a.out == "" {
		fmt.eprintln("odawg render: give -o OUT.wav")
		return false
	}
	s := &l.song
	opts := render.Options{threads = a.threads}
	if a.range != "" {
		b0, b1, ok := song.beats_from_range(s, a.range)
		if !ok {
			fmt.eprintfln("odawg render: %q is not a range of the song", a.range)
			return false
		}
		opts.from, opts.to = tempo.seconds_from_beat(&s.tempo, b0), tempo.seconds_from_beat(&s.tempo, b1)
	}
	m := render.Master.None
	if a.master != "" {
		found: bool
		m, found = render.master_from_name(a.master)
		if !found {
			fmt.eprintfln("odawg render: master %q is not streaming, podcast, broadcast or none", a.master)
			return false
		}
	}
	// the mix (and each stem) written as the export streams it: nothing held
	Files :: struct {
		mix:   render.Wav_Writer,
		stems: []render.Wav_Writer,
	}
	files: Files
	if !render.wav_open(&files.mix, a.out, a.float) {
		fmt.eprintfln("odawg render: can't write %s", a.out)
		return false
	}
	opts.stems = a.stems != ""
	if opts.stems {
		os.make_directory(a.stems)
		// a WAV per stem: each part, return and bus the master sums
		files.stems = make([]render.Wav_Writer, render.stem_count(s))
		for &w, i in files.stems {
			stem, _ := filepath.join({a.stems, strings.concatenate({render.stem_name(s, i), ".wav"}, context.temp_allocator)}, context.temp_allocator)
			render.wav_open(&w, stem, a.float)
		}
	}
	loud := render.master_export(s, opts, m, {&files, proc(data: rawptr, at: i64, l, r: []f32, stems: [][2][]f32) {
		files := (^Files)(data)
		render.wav_push(&files.mix, l, r)
		for st, i in stems {
			render.wav_push(&files.stems[i], st[0], st[1])
		}
	}})
	frames := files.mix.frames
	ok := render.wav_close(&files.mix)
	for &w in files.stems {
		ok &&= render.wav_close(&w)
	}
	if !ok {
		fmt.eprintfln("odawg render: writing %s failed", a.out)
		return false
	}
	fmt.printfln("%s: %.2fs, %.1f LUFS, %.1f dBTP", a.out, f64(frames) / render.RATE, loud.integrated, loud.true_peak)
	return true
}

Timeline_Section :: struct {
	name:          string,
	start, stop:   f64,
	bars:          int,
	bpm:           [2]f64,
	beats_per_bar: int,
	style:         string,
	energy:        f64,
	chords:        string,
	transition:    string,
}

Timeline_Track :: struct {
	part, variant, instrument: string,
	notes:                     int,
	gain_db:                   f64,
}

Timeline :: struct {
	name:     string,
	duration: f64,
	key:      string,
	sections: []Timeline_Section,
	tracks:   []Timeline_Track,
	markers:  []song.Marker,
	findings: []base.Finding,
}

timeline_from_song :: proc(l: ^Loaded) -> Timeline {
	s := &l.song
	t := Timeline{name = s.name, duration = s.duration, key = l.spec.key, markers = s.markers[:], findings = l.findings[:]}
	sections := make([dynamic]Timeline_Section)
	for sec in s.sections {
		b := strings.builder_make()
		for c, i in s.chords[sec.chords.first:base.span_end(sec.chords)] {
			fmt.sbprintf(&b, "%s%s", i > 0 ? " " : "", chord_name(c))
		}
		append(&sections, Timeline_Section{sec.name, sec.start, sec.stop, sec.bars, {sec.bpm0, sec.bpm1}, sec.beats_per_bar, sec.style, sec.energy, strings.to_string(b), song.TRANSITION_NAMES[sec.transition]})
	}
	tracks := make([dynamic]Timeline_Track)
	for tr in s.tracks {
		append(&tracks, Timeline_Track{s.parts[tr.part], tr.variant, device.DEVICE_TABLE[s.devices[tr.instrument]].name, int(tr.notes.count), tr.gain_db})
	}
	t.sections, t.tracks = sections[:], tracks[:]
	return t
}

chord_name :: proc(c: theory.Chord) -> string {
	return theory.string_from_chord(c)
}

run_timeline :: proc(a: ^Args) -> bool {
	l: Loaded
	if !load(a, &l) {
		print_findings(l.findings[:])
		return false
	}
	context.allocator = virtual.arena_allocator(&l.arena)
	t := timeline_from_song(&l)
	if a.json {
		b, _ := json.marshal(t, {pretty = true})
		fmt.println(string(b))
		return true
	}
	fmt.printfln("song %s  %s  %.2fs", t.name, t.key, t.duration)
	for sec in t.sections {
		bpm := sec.bpm[0] == sec.bpm[1] ? fmt.tprintf("%.1f", sec.bpm[0]) : fmt.tprintf("%.1f->%.1f", sec.bpm[0], sec.bpm[1])
		span := fmt.tprintf("%.2fs..%.2fs", sec.start, sec.stop)
		bars := fmt.tprintf("%d bars of %d", sec.bars, sec.beats_per_bar)
		fmt.printfln("  section %-10s %-18s %-13s %-12s bpm  %-9s energy %.2f  %s%s", sec.name, span, bars, bpm, sec.style, sec.energy, sec.chords, sec.transition != "" ? fmt.tprintf("  (into: %s)", sec.transition) : "")
	}
	for m in t.markers {
		fmt.printfln("  marker  %-10s %.2fs", m.name, m.seconds)
	}
	for tr in t.tracks {
		fmt.printfln("  track   %-10s %-10s %-14s %-11s %+.1f dB", tr.part, tr.variant, tr.instrument, fmt.tprintf("%d notes", tr.notes), tr.gain_db)
	}
	print_findings(t.findings)
	return true
}

run_show :: proc(a: ^Args) -> bool {
	if len(a.positional) >= 2 && strings.has_prefix(a.positional[1], "style/") || len(a.positional) == 1 && strings.has_prefix(a.positional[0], "style/") {
		name := a.positional[len(a.positional) - 1][len("style/"):]
		text, ok := song.style_source(name)
		if !ok {
			fmt.eprintfln("odawg show: no style %q", name)
			return false
		}
		fmt.print(text)
		return true
	}
	l: Loaded
	if !load(a, &l) || len(a.positional) < 2 {
		print_findings(l.findings[:])
		if len(a.positional) < 2 {
			fmt.eprintln("odawg show: give a path: sections/NAME, parts/NAME, style/NAME")
		}
		return false
	}
	context.allocator = virtual.arena_allocator(&l.arena)
	s := &l.song
	path := a.positional[1]
	slash := strings.index_byte(path, '/')
	if slash < 0 {
		fmt.eprintfln("odawg show: %q: sections/NAME, parts/NAME or style/NAME", path)
		return false
	}
	group, name := path[:slash], path[slash + 1:]
	switch group {
	case "sections":
		i := song.section_from_name(s, name)
		if i < 0 {
			fmt.eprintfln("odawg show: no section %q", name)
			return false
		}
		t := timeline_from_song(&l)
		b, _ := json.marshal(t.sections[i], {pretty = true})
		fmt.println(string(b))
	case "parts":
		found := false
		for p, pi in s.parts {
			if p != name {
				continue
			}
			found = true
			for tr in s.tracks {
				if int(tr.part) != pi {
					continue
				}
				fmt.printfln("track %s/%s  %s  %d notes  %+.1f dB  pan %.2f", p, tr.variant, device.DEVICE_TABLE[s.devices[tr.instrument]].name, tr.notes.count, tr.gain_db, tr.pan)
				for i in tr.notes.first ..< base.span_end(tr.notes) {
					n := s.notes[i]
					what := n.pad != .None ? device.PAD_NAMES[n.pad] : theory.string_from_pitch(n.pitch)
					fmt.printfln("  %8.3fs  beat %7.2f  %-8s %.3fs  vel %.2f", n.time, n.beat, what, n.duration, n.velocity)
				}
			}
		}
		if !found {
			fmt.eprintfln("odawg show: no part %q", name)
			return false
		}
	case:
		fmt.eprintfln("odawg show: %q: sections/NAME, parts/NAME or style/NAME", path)
		return false
	}
	return true
}

run_at :: proc(a: ^Args) -> bool {
	l: Loaded
	if !load(a, &l) || len(a.positional) < 2 {
		print_findings(l.findings[:])
		if len(a.positional) < 2 {
			fmt.eprintln("odawg at: give a position (drop@1m, 12.5s)")
		}
		return false
	}
	s := &l.song
	t, ok := song.seconds_from_position(s, a.positional[1])
	if !ok {
		fmt.eprintfln("odawg at: %q is not a position in the song", a.positional[1])
		return false
	}
	place, inside := song.place_from_seconds(s, t)
	if !inside {
		fmt.printfln("%.3fs: outside the song (0..%.2fs)", t, s.duration)
		return true
	}
	b := tempo.beat_from_seconds(&s.tempo, t)
	fmt.printfln("%.3fs  section %s bar %d beat %.2f (%.0f%% through)  %.1f bpm  chord %s", t, place.name, place.bar + 1, place.beat + 1, place.progress * 100, tempo.bpm_from_beat(&s.tempo, b), chord_name(song.chord_from_beat(s, b)))
	env := device.Voice_Env{bank = s.bank}
	for tr in s.tracks {
		kind := s.devices[tr.instrument]
		p := s.params[tr.instrument]
		for i in tr.notes.first ..< base.span_end(tr.notes) {
			n := s.notes[i]
			note := device.Note{n.time, n.duration, n.pitch, n.velocity, n.pad}
			if n.time <= t && t < n.time + device.note_tail(kind, &p, note, &env) {
				what := n.pad != .None ? device.PAD_NAMES[n.pad] : theory.string_from_pitch(n.pitch)
				state := t < n.time + n.duration ? "held" : "ringing"
				fmt.printfln("  %-10s %-8s from %.3fs  %s", s.parts[tr.part], what, n.time, state)
			}
		}
	}
	return true
}

run_inspect :: proc(a: ^Args) -> bool {
	l: Loaded
	ok := load(a, &l)
	if !ok || base.has_errors(l.findings[:]) {
		print_findings(l.findings[:])
		return false
	}
	s := &l.song
	opts := render.Options{threads = a.threads}
	if a.range != "" {
		b0, b1, in_song := song.beats_from_range(s, a.range)
		if !in_song {
			fmt.eprintfln("odawg inspect: %q is not a range of the song", a.range)
			return false
		}
		opts.from, opts.to = tempo.seconds_from_beat(&s.tempo, b0), tempo.seconds_from_beat(&s.tempo, b1)
	}
	context.allocator = virtual.arena_allocator(&l.arena)
	out := render.output_from_song(s, opts)
	check.findings_from_render(s, &out, &l.findings)
	print_findings(l.findings[:])
	return !base.has_errors(l.findings[:])
}

run_styles :: proc(a: ^Args) -> bool {
	for st in song.STYLE_TABLE {
		v, _ := json.parse_string(st.text, .JSON5)
		about := ""
		if o, ok := v.(json.Object); ok {
			about, _ = o["description"].(json.String)
		}
		fmt.printfln("%-10s %s", st.name, about)
	}
	return true
}

// Each song rendered whole on one core (one segment: no pre-roll), timed:
// the realtime factor is seconds of sound per second of that core. With -o
// the last song's mix is written as raw interleaved f32, to compare runs.
run_bench :: proc(a: ^Args) -> bool {
	if len(a.positional) == 0 {
		fmt.eprintln("odawg bench: give one or more SPECs")
		return false
	}
	total_sound, total_cpu: f64
	for path in a.positional {
		one := Args{positional = make([dynamic]string, context.temp_allocator)}
		append(&one.positional, path)
		l: Loaded
		load_began := time.tick_now()
		if !load(&one, &l) {
			return false
		}
		load_ms := time.duration_milliseconds(time.tick_since(load_began))
		s := &l.song
		frames := render.frames_from_song(s)
		Sink :: struct {
			out:  ^[dynamic]f32,
			keep: bool,
		}
		out := make([dynamic]f32, context.temp_allocator)
		x := Sink{&out, a.out != ""}
		began := time.tick_now()
		render.export_song(s, {threads = 1, segment = f64(frames) / render.RATE + 1}, {&x, proc(data: rawptr, at: i64, l, r: []f32, stems: [][2][]f32) {
			x := (^Sink)(data)
			if x.keep {
				for i in 0 ..< len(l) {
					append(x.out, l[i], r[i])
				}
			}
		}})
		cpu := time.duration_seconds(time.tick_since(began))
		sound := f64(frames) / render.RATE
		total_sound += sound
		total_cpu += cpu
		// exact seeks spread over the song, each then a preview's block
		e: render.Engine
		render.engine_init(&e, s)
		block := make([]f32, 2 * 800, context.temp_allocator)
		SEEKS :: 40
		seek_began := time.tick_now()
		for k in 0 ..< SEEKS {
			render.engine_seek(&e, i64(frames) * i64(k) / SEEKS, true)
			render.engine_process(&e, block[:800], block[800:])
		}
		seek_ms := time.duration_milliseconds(time.tick_since(seek_began)) / SEEKS
		render.engine_destroy(&e)
		fmt.printfln("%-40s loaded in %.0f ms; %.1fs of sound in %.2fs: %.1fx realtime; an exact seek %.1f ms", filepath.base(path), load_ms, sound, cpu, sound / cpu, seek_ms)
		if a.out != "" {
			if err := os.write_entire_file(a.out, slice.to_bytes(out[:])); err != nil {
				fmt.eprintfln("odawg bench: can't write %s", a.out)
				return false
			}
		}
	}
	fmt.printfln("%-40s %.1fs of sound in %.2fs: %.1fx realtime", "all", total_sound, total_cpu, total_sound / total_cpu)
	return true
}
