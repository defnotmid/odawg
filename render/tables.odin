package odawg_render

import "base:runtime"
import "core:math"
import "core:os"
import "core:slice"
import "core:thread"
import analyze "../analyze"
import base "../base"
import device "../device"
import song "../song"

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
// same whatever segments the export cut, and the same as measuring the
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
	part:               i32, // a stem (stem_count's order: the parts, then the returns, then the buses); -1: the mix
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
	return int(math.ceil((s.duration + tail_from_song(s)) * RATE))
}

// Sizes table `t` for song `s`: rows for the steps where its source sounds
// (their values zero until built).
// `values`: memory of the caller's to fill (a GPU upload buffer a view
// draws), at least rows x width (table_rows tells how many before); nil: its
// own.
table_init :: proc(t: ^Table, s: ^song.Song, kind: Table_Kind, part: i32, step_num, step_den: int, size := 0, shape := analyze.Window.None, allocator := context.allocator, values: []f32 = nil) {
	t^ = {kind = kind, part = part, step_num = max(step_num, 1), step_den = max(step_den, 1), size = size, shape = shape}
	t.frames = frames_from_song(s)
	t.width = TABLE_KINDS[kind].width(t)
	window := TABLE_KINDS[kind].window(t)
	// every step whose window meets a sounding span, inside the song
	steps := (t.frames * t.step_den + t.step_num - 1) / t.step_num
	spans := make([dynamic]Table_Span, 0, 8, allocator)
	sounding := sounding_from_song(s, part)
	if part >= i32(len(s.parts)) {
		// a return's or a bus's: as long as the song (it sounds where what
		// feeds it does, and rings after)
		sounding = {{0, f64(t.frames) / RATE}}
	}
	for x in sounding {
		a := int(x[0] * RATE) - window
		b := int(math.ceil(x[1] * RATE))
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

// How many values a table of `kind` over `part` holds (rows x width): what
// a caller lending its memory sizes it to.
table_size :: proc(s: ^song.Song, kind: Table_Kind, part: i32, step_num, step_den: int, size := 0) -> int {
	t: Table
	table_init(&t, s, kind, part, step_num, step_den, size, allocator = context.temp_allocator, values = []f32{0})
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
sounding_from_song :: proc(s: ^song.Song, part: i32) -> [][2]f64 {
	out := make([dynamic][2]f64, context.temp_allocator)
	env := song.voice_env(s)
	for r in s.regions {
		if part >= 0 && r.part != part {
			continue
		}
		end := r.stop
		for t in s.tracks {
			if t.part != r.part {
				continue
			}
			fx := chain_tail(s, t.chain)
			ret := 0.0
			for snd in s.sends[t.sends.first:base.span_end(t.sends)] {
				ret = max(ret, chain_tail(s, s.returns[snd.ret].chain))
			}
			kind := s.devices[t.instrument]
			p := s.params[t.instrument]
			for i in t.notes.first ..< base.span_end(t.notes) {
				n := note_from_row(s, int(i))
				if n.time >= r.start - 1e-9 && n.time < r.stop - 1e-9 {
					end = max(end, n.time + device.note_tail(kind, &p, n, &env) + fx + ret)
				}
			}
		}
		append(&out, [2]f64{r.start, end})
	}
	slice.sort_by(out[:], proc(a, b: [2]f64) -> bool {return a[0] < b[0]})
	merged := make([dynamic][2]f64, 0, len(out), context.temp_allocator)
	for x in out {
		if n := len(merged); n > 0 && x[0] <= merged[n - 1][1] {
			merged[n - 1][1] = max(merged[n - 1][1], x[1])
		} else {
			append(&merged, x)
		}
	}
	return merged[:]
}

// The version a table of `part` (-1: the mix) is filled at.
source_version :: proc(s: ^song.Song, part: i32) -> u32 {
	return part < 0 ? song.mix_version(s) : song.part_version(s, int(part))
}

// Whether `t` must be filled (again) for the song as it is.
table_stale :: proc(s: ^song.Song, t: ^Table) -> bool {
	return t.version != source_version(s, t.part)
}

// Fills `tables` from the song's samples the caller holds (s nil: a
// recording's, its tables from table_init_frames): `mix` (after
// the master) and `parts` (one stem per part, song.parts order; only the
// parts a table reads), each from song sample 0 and as long as the caller
// has them (past their end reads as silence, as past the song does). Each
// row reads its window straight from the slices; the tables fill side by
// side (`threads`: 0, one per core).
tables_fill :: proc(s: ^song.Song, tables: []^Table, mix: [2][]f32, parts: [][2][]f32, threads := 0) {
	Fill :: struct {
		table:  ^Table,
		source: [2][]f32,
		frames: int,
	}
	jobs := make([]Fill, len(tables), context.temp_allocator)
	for t, k in tables {
		src := mix
		if t.part >= 0 {
			src = int(t.part) < len(parts) ? parts[t.part] : {}
		}
		jobs[k] = {t, src, t.frames}
	}
	run :: proc(j: ^Fill) {
		t := j.table
		row := TABLE_KINDS[t.kind]
		w := row.window(t)
		have := min(len(j.source[0]), len(j.source[1]), j.frames)
		for sp in t.spans {
			for step in sp.from ..< sp.to {
				r := t.values[(sp.first + step - sp.from) * t.width:][:t.width]
				start := row_start(t, step)
				end := min(start + w, j.frames)
				if (row.whole && start + w > j.frames) || start >= have {
					row.fill(t, r, nil, nil) // the kind's silence (bands: FLOOR_DB, not 0 dB)
					continue
				}
				// a window the caller's samples end inside reads silence past them
				if end > have {
					l := make([]f32, end - start, context.temp_allocator)
					rr := make([]f32, end - start, context.temp_allocator)
					copy(l, j.source[0][start:have])
					copy(rr, j.source[1][start:have])
					row.fill(t, r, l, rr)
					continue
				}
				row.fill(t, r, j.source[0][start:end], j.source[1][start:end])
			}
		}
	}
	workers := threads > 0 ? threads : max(1, os.get_processor_core_count())
	if workers == 1 || len(jobs) == 1 {
		for &j in jobs {
			run(&j)
		}
	} else {
		heap := runtime.heap_allocator()
		pool: thread.Pool
		thread.pool_init(&pool, heap, min(workers, len(jobs)))
		for &j in jobs {
			thread.pool_add_task(&pool, heap, proc(t: thread.Task) {
				scratch: virtual_scratch
				context.temp_allocator = scratch_begin(&scratch)
				defer scratch_end(&scratch)
				run((^Fill)(t.data))
			}, &j)
		}
		thread.pool_start(&pool)
		thread.pool_finish(&pool)
		thread.pool_destroy(&pool)
	}
	for t in tables {
		t.version = s != nil ? source_version(s, t.part) : 1
	}
}

// Sizes table `t` over `frames` samples of a recording (no song: its rows
// cover all of it), for tables_fill with a nil song.
table_init_frames :: proc(t: ^Table, kind: Table_Kind, frames: int, step_num, step_den: int, size := 0, shape := analyze.Window.None, allocator := context.allocator) {
	t^ = {kind = kind, part = -1, step_num = max(step_num, 1), step_den = max(step_den, 1), size = size, shape = shape, frames = frames}
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
tables_build :: proc(s: ^song.Song, tables: []^Table, threads := 0) {
	if len(tables) == 0 {
		return
	}
	Build :: struct {
		tables:     []^Table,
		next:       []int, // the next row of each table to fill
		span:       []int, // and the span it is in
		// What arrived and no row is done with: channels [mix l, mix r,
		// then each part's l, r] from song sample `held_first`.
		held:       [][dynamic]f32,
		held_first: int,
		received:   int,
		frames:     int,
	}
	b := Build{tables = tables, frames = frames_from_song(s)}
	b.next = make([]int, len(tables), context.temp_allocator)
	b.span = make([]int, len(tables), context.temp_allocator)
	stems := false
	for t in tables {
		stems ||= t.part >= 0
	}
	b.held = make([][dynamic]f32, 2 * (1 + (stems ? stem_count(s) : 0)), context.temp_allocator)
	for &h in b.held {
		h = make([dynamic]f32, context.temp_allocator)
	}
	fill_rows :: proc(b: ^Build) {
		frames := b.frames
		low := b.received
		for t, k in b.tables {
			row := TABLE_KINDS[t.kind]
			w := row.window(t)
			src := 2 * (t.part >= 0 ? 1 + int(t.part) : 0)
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
				// a window running past the song is the kind's silence (row.whole)
				r := t.values[b.next[k] * t.width:][:t.width]
				if row.whole && start + w > frames {
					row.fill(t, r, nil, nil)
				} else {
					a, z := start - b.held_first, end - b.held_first
					row.fill(t, r, b.held[src][a:z], b.held[src + 1][a:z])
				}
				b.next[k] += 1
			}
		}
		// what no table reads any more goes
		if drop := low - b.held_first; drop > 0 {
			for &h in b.held {
				remove_range(&h, 0, min(drop, len(h)))
			}
			b.held_first = low
		}
	}
	export_song(s, {to = f64(b.frames) / RATE, threads = threads, stems = stems}, {&b, proc(data: rawptr, at: i64, l, r: []f32, stems: [][2][]f32) {
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
		t.version = source_version(s, t.part)
	}
}
