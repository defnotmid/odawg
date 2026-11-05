package odawg_render

import "core:math"
import "core:slice"
import analyze "../analyze"
import base "../base"
import device "../device"
import song "../song"
import common "deps:oicut/common"
import "core:sync"

// Tables: what is read of a song at random (a lane's peaks, a video frame's
// energy or spectrum) as rows of numbers, one per step of the song, of the
// mix (after the master) or of one part's stem, shaped like what they
// measure: rows only where the source sounds (its regions and their tails;
// the mix: every part's), none for silence. One streamed export fills
// every table asked for together, on every core, and nothing of the sound
// is kept: a table holds what was measured. A table is filled at its
// source's version (song.versions): a command that changes the source makes
// it stale, and the next build fills it again.
//
// A row is computed from its own window of samples alone, so a table is the
// same however the export was rendered, and the same as measuring the
// stream at that moment.

Table_Kind :: enum u8 {
	Peaks, // per step: the window's min and max over both sides
	Energy, // per video frame: analyze's rms, peak, low, mid, high
	Spectrum, // per video frame: `size / 2` magnitudes, `shape` windowed
	Bands, // per step: the 31 third-octave levels (BAND_HZ), dB, of the mid channel
	Stereo, // per step: width (side over mid, dB) and the sides' correlation
	Crest, // per step: peak and RMS, dBFS (the crest is their difference)
}

Table_Kind_Row :: struct {
	name:   string,
	// Samples a row reads from its start, and values it holds.
	window: proc(t: ^Table) -> int,
	width:  proc(t: ^Table) -> int,
	// A row whose window runs past the song is silent (else it reads what
	// of the window the song has).
	whole:  bool,
	fill:   proc(t: ^Table, row: []f32, l, r: []f32),
}

TABLE_KINDS := [Table_Kind]Table_Kind_Row {
	.Peaks = {
		name = "peaks",
		window = proc(t: ^Table) -> int {return max(t.step_num / max(t.step_den, 1), 1)},
		width = proc(t: ^Table) -> int {return 2},
		fill = proc(t: ^Table, row: []f32, l, r: []f32) {
			lo, hi: f32
			for x in l {
				lo, hi = min(lo, x), max(hi, x)
			}
			for x in r {
				lo, hi = min(lo, x), max(hi, x)
			}
			row[0], row[1] = lo, hi
		},
	},
	.Energy = {
		name = "energy",
		// the frame's samples, and what its 512-sample spectrum reads
		window = proc(t: ^Table) -> int {return max(energy_samples(t), 512)},
		width = proc(t: ^Table) -> int {return 5},
		fill = proc(t: ^Table, row: []f32, l, r: []f32) {
			e := analyze.energy_from_samples(l, r, 0, energy_samples(t))
			row[0], row[1], row[2], row[3], row[4] = e.rms, e.peak, e.low, e.mid, e.high
		},
	},
	.Spectrum = {
		name = "spectrum",
		window = proc(t: ^Table) -> int {return t.size},
		width = proc(t: ^Table) -> int {return t.size / 2},
		whole = true,
		fill = proc(t: ^Table, row: []f32, l, r: []f32) {analyze.spectrum_from_samples(l, r, 0, t.shape, row)},
	},
	.Bands = {
		name = "bands",
		window = proc(t: ^Table) -> int {return BANDS_FFT},
		width = proc(t: ^Table) -> int {return len(BAND_HZ)},
		whole = true,
		fill = fill_bands,
	},
	.Stereo = {
		name = "stereo",
		window = proc(t: ^Table) -> int {return max(t.step_num / max(t.step_den, 1), 1)},
		width = proc(t: ^Table) -> int {return 2},
		fill = fill_stereo,
	},
	.Crest = {
		name = "crest",
		window = proc(t: ^Table) -> int {return max(t.step_num / max(t.step_den, 1), 1)},
		width = proc(t: ^Table) -> int {return 2},
		fill = fill_crest,
	},
}

@(private = "file")
energy_samples :: proc(t: ^Table) -> int {
	return max(t.step_num / max(t.step_den, 1), 1)
}

// Steps [from, to) that have rows, from row `first` on.
Table_Span :: struct {
	from, to, first: int,
}

Table :: struct {
	kind:               Table_Kind,
	source:             song.Node_Id, // what it measures: a part, a return or a bus, wherever it is in the song (0: the mix)
	// A row every step_num / step_den samples from the song's start (a video
	// frame: RATE / fps; a peak bucket: n / 1), rounded down.
	step_num, step_den: int,
	size:               int, // Spectrum: the FFT size, a power of two to analyze.SPECTRUM_MAX
	shape:              analyze.Window, // Spectrum
	frames:             int, // the song's samples (its tail included)
	spans:              []Table_Span, // where it has rows, in order
	width, rows:        int,
	values:             []f32, // rows x width (the caller's when it lent them)
	lent:               bool, // values are the caller's: table_destroy leaves them
	version:            u32, // its source's, when filled (0: never)
}

// The song's samples with its tail: what a table covers.
frames_from_song :: proc(s: ^song.Song) -> int {
	return int(math.ceil(f64(s.duration + tail_from_song(s)) * RATE))
}

// Sizes table `t` for song `s`: rows for the steps where its source sounds
// (their values zero until built).
// `values`: memory of the caller's to fill (a GPU upload buffer a view
// draws), at least rows x width (table_rows tells how many before); nil: its
// own.
table_init :: proc(t: ^Table, s: ^song.Song, kind: Table_Kind, source: song.Node_Id, step_num, step_den: int, size := 0, shape := analyze.Window.None, allocator := context.allocator, values: []f32 = nil) {
	t^ = {kind = kind, source = source, step_num = max(step_num, 1), step_den = max(step_den, 1), size = size, shape = shape}
	t.frames = frames_from_song(s)
	t.width = TABLE_KINDS[kind].width(t)
	window := TABLE_KINDS[kind].window(t)
	// every step whose window meets a sounding span, inside the song
	steps := (t.frames * t.step_den + t.step_num - 1) / t.step_num
	spans := make([dynamic]Table_Span, 0, 8, allocator)
	// a part's where it plays; the mix's where anything does; a return's or
	// a bus's as long as the song (it sounds where what feeds it does, and
	// rings after)
	sounding := [][2]base.Seconds{{0, base.seconds_from_samples(i64(t.frames))}}
	stem := stem_from_id(s, source)
	if stem == STEM_NONE {
		sounding = nil // not in this build: no rows
	} else if part := stem_part(s, stem); part >= 0 || stem < 0 {
		sounding = sounding_from_song(s, part)
	}
	for x in sounding {
		a := int(f64(x[0]) * RATE) - window
		b := int(math.ceil(f64(x[1]) * RATE))
		from := clamp((max(a, 0) * t.step_den) / t.step_num, 0, steps)
		to := clamp((b * t.step_den + t.step_num - 1) / t.step_num + 1, 0, steps)
		if n := len(spans); n > 0 && from <= spans[n - 1].to {
			spans[n - 1].to = max(spans[n - 1].to, to)
		} else if to > from {
			append(&spans, Table_Span{from = from, to = to})
		}
	}
	for &sp in spans {
		sp.first = t.rows
		t.rows += sp.to - sp.from
	}
	t.spans = spans[:]
	if values != nil && len(values) >= t.rows * t.width {
		t.values, t.lent = values[:t.rows * t.width], true
	} else {
		t.values = make([]f32, t.rows * t.width, allocator)
	}
}

// How many values a table of `kind` over `source` holds (rows x width): what
// a caller lending its memory sizes it to.
table_size :: proc(s: ^song.Song, kind: Table_Kind, source: song.Node_Id, step_num, step_den: int, size := 0) -> int {
	t: Table
	table_init(&t, s, kind, source, step_num, step_den, size, allocator = context.temp_allocator, values = []f32{0})
	n := t.rows * t.width
	delete(t.spans, context.temp_allocator)
	return n
}

table_destroy :: proc(t: ^Table, allocator := context.allocator) {
	if !t.lent {
		delete(t.values, allocator)
	}
	delete(t.spans, allocator)
	t^ = {}
}

row_start :: proc(t: ^Table, step: int) -> int {
	return step * t.step_num / t.step_den
}

// The row of step `step` (nil where the source is silent, or outside the
// song).
table_row :: proc(t: ^Table, step: int) -> []f32 {
	if t == nil {
		return nil
	}
	lo, hi := 0, len(t.spans)
	for lo < hi {
		mid := (lo + hi) / 2
		if t.spans[mid].to <= step {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo >= len(t.spans) || step < t.spans[lo].from {
		return nil
	}
	r := t.spans[lo].first + step - t.spans[lo].from
	return t.values[r * t.width:][:t.width]
}

// Where a part (-1: any) sounds, song seconds in order and merged: its
// regions to their notes' last sound (release, the effects' and returns'
// tails).
// The part stem `stem` is (stem_count's order); -1: a return's, a bus's or
// the mix's, which hear every part.
@(private = "file")
stem_part :: proc(s: ^song.Song, stem: i32) -> i32 {
	return stem >= 0 && stem < i32(len(s.parts)) ? stem : -1
}

// What stem_from_id gives for the mix, and for a node this build hasn't.
STEM_MIX :: -1
STEM_NONE :: -2

// The stem a node is in this build (stem_count's order: the nodes after the
// tracks).
stem_from_id :: proc(s: ^song.Song, id: song.Node_Id) -> i32 {
	if id == 0 {
		return STEM_MIX
	}
	k := song.node_from_id(s, id) - i32(len(s.tracks))
	return k >= 0 && k < i32(stem_count(s)) ? k : STEM_NONE
}

// What names stem `stem` from outside this build.
stem_id :: proc(s: ^song.Song, stem: int) -> song.Node_Id {
	return s.node_ids[len(s.tracks) + stem]
}

sounding_from_song :: proc(s: ^song.Song, part: i32) -> [][2]base.Seconds {
	out := make([dynamic][2]base.Seconds, context.temp_allocator)
	env := song.voice_env(s)
	rings := rings_from_song(s, context.temp_allocator)
	for r in s.regions {
		if part >= 0 && r.part != part {
			continue
		}
		end := r.stop
		for t, ti in s.tracks {
			if t.part != r.part {
				continue
			}
			p := s.params[t.instrument]
			for i in t.notes.first ..< base.span_end(t.notes) {
				n := note_from_row(s, int(i))
				if n.time >= r.start - 1e-9 && n.time < r.stop - 1e-9 {
					end = max(end, n.time + device.note_tail(&p, n, &env) + rings[ti])
				}
			}
		}
		append(&out, [2]base.Seconds{r.start, end})
	}
	slice.sort_by(out[:], proc(a, b: [2]base.Seconds) -> bool {return a[0] < b[0]})
	merged := make([dynamic][2]base.Seconds, 0, len(out), context.temp_allocator)
	for x in out {
		if n := len(merged); n > 0 && x[0] <= merged[n - 1][1] {
			merged[n - 1][1] = max(merged[n - 1][1], x[1])
		} else {
			append(&merged, x)
		}
	}
	return merged[:]
}

// The version a table of stem `stem` (STEM_MIX: the mix) is filled at.
@(private = "file")
source_version :: proc(s: ^song.Song, stem: i32) -> u32 {
	part := stem_part(s, stem)
	return part < 0 ? song.mix_version(s) : song.part_version(s, int(part))
}

// Whether `t` must be filled (again) for the song as it is.
table_stale :: proc(s: ^song.Song, t: ^Table) -> bool {
	stem := stem_from_id(s, t.source)
	return stem != STEM_NONE && t.version != source_version(s, stem)
}

// Fills `tables` from the song's samples the caller holds (s nil: a
// recording's, its tables from table_init_frames): `mix` (after
// the master) and `parts` (one stem per part, song.parts order; only the
// parts a table reads), each from song sample 0 and as long as the caller
// has them (past their end reads as silence, as past the song does). Each
// row reads its window straight from the slices; the tables fill side by
// side on the caller's pool (nil: in turn on the caller's thread).
tables_fill :: proc(s: ^song.Song, tables: []^Table, mix: [2][]f32, parts: [][2][]f32, pool: ^common.Work_Pool = nil) {
	Fill :: struct {
		table:  ^Table,
		source: [2][]f32,
	}
	jobs := make([]Fill, len(tables), context.temp_allocator)
	for t, k in tables {
		src := mix
		if stem := stem_from_id(s, t.source); stem != STEM_MIX {
			src = stem >= 0 && int(stem) < len(parts) ? parts[stem] : {}
		}
		jobs[k] = {t, src}
	}
	run :: proc(j: ^Fill) {
		table_fill_steps(j.table, 0, max(int), 0, j.source[0], j.source[1])
	}
	// the jobs by a shared cursor (their sizes differ: a spectrum's rows cost
	// more than a level's), a scratch arena each
	Fills :: struct {
		jobs: []Fill,
		next: int,
		run:  proc(j: ^Fill),
	}
	fills := Fills{jobs, 0, run}
	each :: proc(data: rawptr, first, end: int) {
		f := (^Fills)(data)
		for {
			i := sync.atomic_add(&f.next, 1)
			if i >= len(f.jobs) {
				return
			}
			scratch: virtual_scratch
			context.temp_allocator = scratch_begin(&scratch)
			f.run(&f.jobs[i])
			scratch_end(&scratch)
		}
	}
	if pool == nil || len(jobs) <= 1 {
		each(&fills, 0, 1)
	} else {
		pool.run(pool, len(jobs), each, &fills)
	}
	for t in tables {
		t.version = s != nil ? source_version(s, stem_from_id(s, t.source)) : 1
	}
}

// The samples a row of `t` reads from its step's start.
table_window :: proc(t: ^Table) -> int {
	return TABLE_KINDS[t.kind].window(t)
}

// Fills the rows `t` has (where its source sounds) of steps [first, end)
// from `l` and `r`, the source's samples from song sample `from` on (no
// row's window starting before it): each row reads its window, silence
// past the samples given as past the song, and a whole kind's window running
// past the song is the kind's silence. What tables_fill and tables_build do
// with each row, for a host filling rows as its samples come (onimite's kept
// renders).
table_fill_steps :: proc(t: ^Table, first, end: int, from: int, l, r: []f32) {
	row := TABLE_KINDS[t.kind]
	w := row.window(t)
	for sp in t.spans {
		if sp.from >= end {
			break
		}
		for step in max(sp.from, first) ..< min(sp.to, end) {
			fill_row(t, row, w, step, t.values[(sp.first + step - sp.from) * t.width:][:t.width], from, l, r)
		}
	}
}

// Row `dst` of step `step` (`w`: its window) from the source's samples `l`
// and `r` from song sample `from` on.
@(private = "file")
fill_row :: proc(t: ^Table, row: Table_Kind_Row, w, step: int, dst: []f32, from: int, l, r: []f32) {
	have := min(from + min(len(l), len(r)), t.frames)
	start := row_start(t, step)
	end := min(start + w, t.frames)
	if (row.whole && start + w > t.frames) || start >= have {
		row.fill(t, dst, nil, nil) // the kind's silence (bands: FLOOR_DB, not 0 dB)
		return
	}
	a := start - from
	// a window the samples given end inside reads silence past them
	if end > have {
		pl := make([]f32, end - start, context.temp_allocator)
		pr := make([]f32, end - start, context.temp_allocator)
		copy(pl, l[a:have - from])
		copy(pr, r[a:have - from])
		row.fill(t, dst, pl, pr)
		return
	}
	row.fill(t, dst, l[a:end - from], r[a:end - from])
}

// Sizes table `t` over `frames` samples of a recording (no song: its rows
// cover all of it), for tables_fill with a nil song.
table_init_frames :: proc(t: ^Table, kind: Table_Kind, frames: int, step_num, step_den: int, size := 0, shape := analyze.Window.None, allocator := context.allocator) {
	t^ = {kind = kind, step_num = max(step_num, 1), step_den = max(step_den, 1), size = size, shape = shape, frames = frames}
	t.width = TABLE_KINDS[kind].width(t)
	t.rows = (frames * t.step_den + t.step_num - 1) / t.step_num
	spans := make([]Table_Span, 1, allocator)
	spans[0] = {0, t.rows, 0}
	t.spans = spans
	t.values = make([]f32, t.rows * t.width, allocator)
}

// Fills every table in `tables` from one streamed export of the song
// (`threads` as export_song's). The tables are the song's own size
// (table_init); what each reads is held only until its rows are filled.
tables_build :: proc(s: ^song.Song, tables: []^Table, pool: ^common.Work_Pool = nil) {
	if len(tables) == 0 {
		return
	}
	Build :: struct {
		tables:      []^Table,
		next:        []int, // the next row of each table to fill
		span:        []int, // and the span it is in
		source:      []int, // and the channel of `held` it reads from
		// What arrived and no row is done with: channels [mix l, mix r,
		// then each part's l, r] from song sample `held_first`.
		held:        [][dynamic]f32,
		held_first:  int,
		held_offset: int,
		received:    int,
		frames:      int,
	}
	b := Build{tables = tables, frames = frames_from_song(s)}
	b.next = make([]int, len(tables), context.temp_allocator)
	b.span = make([]int, len(tables), context.temp_allocator)
	b.source = make([]int, len(tables), context.temp_allocator)
	stems := false
	for t, k in tables {
		stem := stem_from_id(s, t.source)
		stems ||= stem >= 0
		b.source[k] = 2 * (stem >= 0 ? 1 + int(stem) : 0)
		if stem == STEM_NONE {
			b.span[k] = len(t.spans) // not in this build: nothing to read
		}
	}
	b.held = make([][dynamic]f32, 2 * (1 + (stems ? stem_count(s) : 0)), context.temp_allocator)
	for &h in b.held {
		h = make([dynamic]f32, context.temp_allocator)
	}
	fill_rows :: proc(b: ^Build) {
		frames := b.frames
		low := b.received
		from := b.held_first + b.held_offset
		for t, k in b.tables {
			row := TABLE_KINDS[t.kind]
			w := row.window(t)
			src := b.source[k]
			for b.span[k] < len(t.spans) {
				sp := t.spans[b.span[k]]
				step := sp.from + b.next[k] - sp.first
				if step >= sp.to {
					b.span[k] += 1
					continue
				}
				start := row_start(t, step)
				end := min(start + w, frames)
				if end > b.received {
					low = min(low, start)
					break
				}
				fill_row(t, row, w, step, t.values[b.next[k] * t.width:][:t.width], from, b.held[src][b.held_offset:], b.held[src + 1][b.held_offset:])
				b.next[k] += 1
			}
		}
		// what no table reads any more goes
		if drop := low - from; drop > 0 {
			b.held_offset += drop
			if b.held_offset > 0 && b.held_offset * 2 >= len(b.held[0]) {
				for &h in b.held {
					remove_range(&h, 0, min(b.held_offset, len(h)))
				}
				b.held_first += b.held_offset
				b.held_offset = 0
			}
		}
	}
	export_song(s, {to = base.seconds_from_samples(i64(b.frames)), pool = pool, stems = stems}, {&b, proc(data: rawptr, at: i64, l, r: []f32, stems: [][2][]f32) {
		b := (^Build)(data)
		append(&b.held[0], ..l)
		append(&b.held[1], ..r)
		for st, p in stems {
			if 2 + 2 * p + 1 < len(b.held) {
				append(&b.held[2 + 2 * p], ..st[0])
				append(&b.held[3 + 2 * p], ..st[1])
			}
		}
		b.received = int(at) + len(l)
		fill_rows(b)
	}})
	b.received = b.frames
	fill_rows(&b)
	for t in tables {
		t.version = source_version(s, stem_from_id(s, t.source))
	}
}
