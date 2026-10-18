package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import analyze "deps:odawg/analyze"
import assets "deps:odawg/assets"
import render "deps:odawg/render"
import song "deps:odawg/song"

// odawg analyze: what a song's sound is made of, per section, for the mix
// and every stem (the parts, the returns, the buses): loudness and true peak
// (the streaming meter's), crest, stereo width and correlation, and 31
// third-octave bands, from the tables odawg renders (render.Table kinds
// .Bands, .Stereo, .Crest), with the parts that crowd each other band by
// band, and the same measures of a reference recording beside the mix's.
// Its JSON matches onimite's `audio analyze` (snake_case, the unit in the
// name, an array of named objects per what is measured).

// A row of the tables every 100 ms.
ANALYSIS_STEP :: render.RATE / 10
MASK_KEEP :: 8 // per section, the most crowded first

Section_Report :: struct {
	name:          string `json:"name"`,
	start_seconds: f64 `json:"start_seconds"`,
	end_seconds:   f64 `json:"end_seconds"`,
	mix:           render.Measures `json:"mix"`,
	stems:         []render.Measures `json:"stems"`,
}

Reference_Report :: struct {
	using measures:             render.Measures,
	path:                       string `json:"path"`,
	integrated_lufs_diff_db:    f64 `json:"integrated_lufs_diff_db"`,
	crest_diff_db:              f64 `json:"crest_diff_db"`,
	width_diff_db:              f64 `json:"width_diff_db"`,
	bands_diff_db:              []f64 `json:"bands_diff_db"`,
}

Analysis_Report :: struct {
	song:              string `json:"song"`,
	band_hz:           []f64 `json:"band_hz"`,
	integrated_lufs:   f64 `json:"integrated_lufs"`,
	loudness_range_lu: f64 `json:"loudness_range_lu"`,
	true_peak_dbtp:    f64 `json:"true_peak_dbtp"`,
	mix:               render.Measures `json:"mix"`,
	sections:          []Section_Report `json:"sections"`,
	masking:           []render.Masking_Row `json:"masking"`,
	reference:         Maybe(Reference_Report) `json:"reference,omitempty"`,
}

// The tables of one source (the mix: -1, or a stem) and its meters, one per
// section and one for the whole.
@(private = "file")
Source :: struct {
	bands, stereo, crest: render.Table,
	meters:               []analyze.Meter, // per section, then the whole
}

run_analyze :: proc(a: ^Args) -> bool {
	l: Loaded
	if !load(a, &l) {
		return false
	}
	print_findings(l.findings[:])
	s := &l.song
	m := render.Master.None
	if a.master != "" {
		found: bool
		if m, found = render.master_from_name(a.master); !found {
			fmt.eprintfln("odawg analyze: master %q is not streaming, podcast, broadcast or none", a.master)
			return false
		}
	}
	stems := render.stem_count(s)
	frames := render.frames_from_song(s)
	sources := make([]Source, 1 + stems)
	for &src, k in sources {
		part := i32(k - 1)
		render.table_init(&src.bands, s, .Bands, part, ANALYSIS_STEP, 1)
		render.table_init(&src.stereo, s, .Stereo, part, ANALYSIS_STEP, 1)
		render.table_init(&src.crest, s, .Crest, part, ANALYSIS_STEP, 1)
		src.meters = make([]analyze.Meter, len(s.sections) + 1)
		for &mt in src.meters {
			analyze.meter_init(&mt, render.RATE)
		}
	}
	// the meters, from the export (mastered when asked: the master is the
	// song's from then on, so the tables after it hear it too)
	Metering :: struct {
		song:    ^song.Song,
		sources: []Source,
	}
	x := Metering{s, sources}
	sink := render.Sink{&x, proc(data: rawptr, at: i64, l, r: []f32, stems: [][2][]f32) {
		x := (^Metering)(data)
		push :: proc(src: ^Source, s: ^song.Song, at: i64, l, r: []f32) {
			n := i64(len(l))
			for sec, i in s.sections {
				a := max(i64(math.round(sec.start * render.RATE)) - at, 0)
				b := min(i64(math.round(sec.stop * render.RATE)) - at, n)
				if b > a {
					analyze.meter_push(&src.meters[i], l[a:b], r[a:b])
				}
			}
			analyze.meter_push(&src.meters[len(s.sections)], l, r)
		}
		push(&x.sources[0], x.song, at, l, r)
		for st, p in stems {
			push(&x.sources[1 + p], x.song, at, st[0], st[1])
		}
	}}
	render.master_export(s, {to = f64(frames) / render.RATE, stems = true, threads = a.threads}, m, sink)
	tables := make([dynamic]^render.Table)
	for &src in sources {
		append(&tables, &src.bands, &src.stereo, &src.crest)
	}
	render.tables_build(s, tables[:], a.threads)

	report := Analysis_Report{song = s.name}
	report.band_hz = make([]f64, len(render.BAND_HZ))
	for hz, i in render.BAND_HZ {
		report.band_hz[i] = f64(hz)
	}
	whole := analyze.loudness_from_meter(&sources[0].meters[len(s.sections)])
	report.integrated_lufs, report.loudness_range_lu, report.true_peak_dbtp = finite(whole.integrated), finite(whole.range), finite(whole.true_peak)
	all_steps := [2]int{0, (frames + ANALYSIS_STEP - 1) / ANALYSIS_STEP}
	report.mix = measures_from(&sources[0], len(s.sections), all_steps)
	report.sections = make([]Section_Report, len(s.sections))
	masking := make([dynamic]render.Masking_Row)
	for sec, i in s.sections {
		steps := [2]int{int(sec.start * render.RATE) / ANALYSIS_STEP, int(math.ceil(sec.stop * render.RATE)) / ANALYSIS_STEP}
		r := &report.sections[i]
		r^ = {name = sec.name, start_seconds = s.start + sec.start, end_seconds = s.start + sec.stop}
		r.mix = measures_from(&sources[0], i, steps)
		r.stems = make([]render.Measures, stems)
		for p in 0 ..< stems {
			r.stems[p] = measures_from(&sources[1 + p], i, steps)
			r.stems[p].name = render.stem_name(s, p)
		}
		// the parts crowding each other where the mix is
		rows := render.masking_from(r.mix, r.stems[:len(s.parts)], sec.name, MASK_KEEP)
		append(&masking, ..rows)
	}
	report.masking = masking[:]
	if a.reference != "" {
		ref, ok := reference_from_file(a.reference, report.mix)
		if !ok {
			return false
		}
		report.reference = ref
	}
	if a.json {
		data, err := json.marshal(report, {pretty = true, use_enum_names = true})
		if err != nil {
			fmt.eprintfln("odawg analyze: %v", err)
			return false
		}
		fmt.println(string(data))
		return true
	}
	print_analysis(&report)
	return true
}

// A source's measures over steps [steps[0], steps[1]): loudness and true
// peak from its meter `meter`, the rest from its rows there.
@(private = "file")
measures_from :: proc(src: ^Source, meter: int, steps: [2]int) -> render.Measures {
	out := render.measures_from_tables(&src.bands, &src.stereo, &src.crest, steps)
	lo := analyze.loudness_from_meter(&src.meters[meter])
	out.integrated_lufs, out.true_peak_dbtp = finite(lo.integrated), finite(lo.true_peak)
	return out
}

// A recording measured as the mix is (its whole length one section), and
// the mix's differences from it.
@(private = "file")
reference_from_file :: proc(path: string, mix: render.Measures) -> (out: Reference_Report, ok: bool) {
	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		fmt.eprintfln("odawg analyze: can't read %s", path)
		return
	}
	d, derr := assets.decode(path, data)
	if derr != nil {
		fmt.eprintfln("odawg analyze: %s: %v", path, derr)
		return
	}
	// stereo at RATE (mono on both sides; more channels: the first two)
	ch := max(d.channels, 1)
	n := len(d.samples) / ch
	stereo := make([]f32, 2 * n)
	for i in 0 ..< n {
		stereo[2 * i] = d.samples[ch * i]
		stereo[2 * i + 1] = d.samples[ch * i + min(1, ch - 1)]
	}
	if d.rate != render.RATE {
		stereo = assets.resample(stereo, 2, d.rate)
		n = len(stereo) / 2
	}
	l, r := make([]f32, n), make([]f32, n)
	for i in 0 ..< n {
		l[i], r[i] = stereo[2 * i], stereo[2 * i + 1]
	}
	src: Source
	render.table_init_frames(&src.bands, .Bands, n, ANALYSIS_STEP, 1)
	render.table_init_frames(&src.stereo, .Stereo, n, ANALYSIS_STEP, 1)
	render.table_init_frames(&src.crest, .Crest, n, ANALYSIS_STEP, 1)
	render.tables_fill(nil, {&src.bands, &src.stereo, &src.crest}, {l, r}, nil)
	src.meters = make([]analyze.Meter, 1)
	analyze.meter_init(&src.meters[0], render.RATE)
	analyze.meter_push(&src.meters[0], l, r)
	out.measures = measures_from(&src, 0, {0, src.bands.rows})
	out.path = path
	out.integrated_lufs_diff_db = mix.integrated_lufs - out.integrated_lufs
	out.crest_diff_db = mix.crest_db - out.crest_db
	out.width_diff_db = mix.width_db - out.width_db
	out.bands_diff_db = make([]f64, len(render.BAND_HZ))
	for i in 0 ..< len(render.BAND_HZ) {
		out.bands_diff_db[i] = mix.bands_db[i] - out.bands_db[i]
	}
	return out, true
}

// A number as text with `places` decimals (fmt pads widths with zeros).
@(private = "file")
num :: proc(x: f64, places: int) -> string {
	switch places {
	case 0:
		return fmt.tprintf("%.0f", x)
	case 2:
		return fmt.tprintf("%.2f", x)
	}
	return fmt.tprintf("%.1f", x)
}

// A number JSON can carry (silence's -inf as the floor).
@(private = "file")
finite :: proc(x: f64) -> f64 {
	return math.is_inf(x) || math.is_nan(x) ? render.FLOOR_DB : x
}

// The report as text: per section the mix and each stem's loudness, crest
// and width, then where parts crowd each other.
@(private = "file")
print_analysis :: proc(r: ^Analysis_Report) {
	fmt.printfln("%s: %.1f LUFS, %.1f LU range, %.1f dBTP", r.song, r.integrated_lufs, r.loudness_range_lu, r.true_peak_dbtp)
	for sec in r.sections {
		fmt.printfln("\n%s  %.2fs..%.2fs", sec.name, sec.start_seconds, sec.end_seconds)
		line :: proc(m: render.Measures, name: string) {
			if m.integrated_lufs <= render.FLOOR_DB + 1 {
				return
			}
			fmt.printfln("  %-16s %7s LUFS  crest %5s dB  width %7s dB  corr %5s", name, num(m.integrated_lufs, 1), num(m.crest_db, 1), num(m.width_db, 1), num(m.correlation, 2))
		}
		line(sec.mix, "mix")
		for st in sec.stems {
			line(st, st.name)
		}
	}
	if len(r.masking) > 0 {
		fmt.println("\ncrowding (two parts within 6 dB of each other in a band, near the mix's level there):")
		for m in r.masking {
			fmt.printfln("  %-8s %-10s %-10s %6s Hz  %6s dB", m.section, m.a, m.b, num(m.band_hz, 0), num(m.overlap_db, 1))
		}
	}
	if ref, has := r.reference.?; has {
		fmt.printfln("\nagainst %s: %+.1f LU, crest %+.1f dB, width %+.1f dB; bands (mix minus reference):", ref.path, ref.integrated_lufs_diff_db, ref.crest_diff_db, ref.width_diff_db)
		for d, i in ref.bands_diff_db {
			fmt.printf("  %g Hz %+.1f", r.band_hz[i], d)
			if i % 6 == 5 {
				fmt.println()
			}
		}
		fmt.println()
	}
}
