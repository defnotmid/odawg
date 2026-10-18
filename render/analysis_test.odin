package odawg_render

import "core:math"
import "core:mem/virtual"
import "core:slice"
import "core:testing"
import base "../base"
import song "../song"
import spec "../spec"

// A 1 kHz sine at half scale is the 1 kHz band at its level (a mean square
// of 0.125: -9.0 dB) and the bands an octave away are far under it.
@(test)
test_bands_sine :: proc(t: ^testing.T) {
	l := make([]f32, BANDS_FFT, context.temp_allocator)
	for &v, i in l {
		v = 0.5 * f32(math.sin(2 * math.PI * 1000 * f64(i) / RATE))
	}
	tab: Table
	row: [31]f32
	fill_bands(&tab, row[:], l, l)
	k := 17 // 1000 Hz
	testing.expect_value(t, BAND_HZ[k], 1000)
	testing.expectf(t, abs(row[k] - -9.03) < 0.5, "the 1 kHz band at %f dB", row[k])
	testing.expectf(t, row[k - 3] < row[k] - 40 && row[k + 3] < row[k] - 40, "an octave off: %f, %f", row[k - 3], row[k + 3])
}

// Stereo: one signal on both sides is mono (correlation 1, no side); one
// side inverted is out of phase (-1); unrelated sides are wide.
@(test)
test_stereo_rows :: proc(t: ^testing.T) {
	n := 4800
	a := make([]f32, n, context.temp_allocator)
	b := make([]f32, n, context.temp_allocator)
	neg := make([]f32, n, context.temp_allocator)
	rng := base.rng_init(7)
	for i in 0 ..< n {
		a[i] = f32(math.sin(2 * math.PI * 440 * f64(i) / RATE))
		neg[i] = -a[i]
		b[i] = f32(base.rng_unit(&rng) * 2 - 1)
	}
	tab: Table
	row: [2]f32
	fill_stereo(&tab, row[:], a, a)
	testing.expect(t, row[0] <= FLOOR_DB + 1 && abs(row[1] - 1) < 1e-4)
	fill_stereo(&tab, row[:], a, neg)
	testing.expect(t, abs(row[1] - -1) < 1e-4)
	fill_stereo(&tab, row[:], a, b)
	testing.expectf(t, abs(row[1]) < 0.1 && row[0] > -3, "unrelated sides: width %f, correlation %f", row[0], row[1])
}

// The Analyzer, started mid-song and fed blocks of any size, makes the rows
// a table filled from the whole song has there, to the bit.
@(test)
test_analyzer_is_table :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	sp := new(spec.Spec)
	findings := make(base.Findings)
	testing.expect(t, spec.spec_from_json(`{ key: "A minor", seed: 3, sections: [ { name: "a", duration: "2m", bpm: 110, style: "styles/house.json", energy: 0.8, chords: "Am F" } ] }`, sp, &findings))
	add_examples(sp, &findings)
	s := new(song.Song)
	testing.expect(t, song.song_from_spec(sp, s))
	whole := output_from_song(s, {threads = 2})
	STEP :: 4800
	kinds := [3]Table_Kind{.Bands, .Stereo, .Crest}
	for kind in kinds {
		tab: Table
		table_init(&tab, s, kind, -1, STEP, 1)
		tables_fill(s, {&tab}, {whole.left, whole.right}, nil)
		at := i64(3 * RATE + 777) // mid-song, off the grid
		a: Analyzer
		analyzer_init(&a, kind, STEP, 1, 64, at)
		worst: f32
		made := 0
		for pos := int(at); pos < whole.frames; pos += 333 {
			n := min(333, whole.frames - pos)
			analyzer_push(&a, whole.left[pos:][:n], whole.right[pos:][:n])
			row, step := analyzer_latest(&a)
			if row == nil {
				continue
			}
			want := table_row(&tab, step)
			if want == nil {
				continue // the table has no row there: the song is silent
			}
			made += 1
			for v, k in row {
				worst = max(worst, abs(v - want[k]))
			}
		}
		testing.expectf(t, made > 10, "%v: %d rows compared", kind, made)
		testing.expectf(t, worst == 0, "%v: the Analyzer differs from the table by %g", kind, worst)
		// nothing before its start: the first step it makes starts at or after it
		testing.expect(t, row_start(&a.table, int((at + STEP - 1) / STEP)) >= int(at))
	}
}

// The lowest band reads something: a 20 Hz sine at full scale is about its
// mean square (-3 dB) in band 0, through the bin nearest it.
@(test)
test_bands_low :: proc(t: ^testing.T) {
	l := make([]f32, BANDS_FFT, context.temp_allocator)
	for &v, i in l {
		v = f32(math.sin(2 * math.PI * 20 * f64(i) / RATE))
	}
	tab: Table
	row: [31]f32
	fill_bands(&tab, row[:], l, l)
	testing.expectf(t, abs(row[0] - -3) < 4, "the 20 Hz band at %f dB", row[0])
	for b, i in BAND_BINS {
		testing.expectf(t, b[0] >= 1 && b[1] >= b[0], "band %d has no bins", i)
	}
}

// One block larger than the Analyzer's ring: the rows are still the
// table's.
@(test)
test_analyzer_big_block :: proc(t: ^testing.T) {
	n := 4 * RATE
	l := make([]f32, n, context.temp_allocator)
	r := make([]f32, n, context.temp_allocator)
	rng := base.rng_init(3)
	for i in 0 ..< n {
		l[i] = f32(math.sin(2 * math.PI * 440 * f64(i) / RATE)) * 0.5 + f32(base.rng_unit(&rng) - 0.5) * 0.1
		r[i] = l[i] * 0.8
	}
	STEP :: 2400
	tab: Table
	table_init_frames(&tab, .Bands, n, STEP, 1, allocator = context.temp_allocator)
	tables_fill(nil, {&tab}, {l, r}, nil)
	a: Analyzer
	analyzer_init(&a, .Bands, STEP, 1, 256, 0, allocator = context.temp_allocator)
	analyzer_push(&a, l[:3 * RATE], r[:3 * RATE]) // 144000 samples into a ring of 16384
	worst: f32
	made := 0
	for step in 0 ..< 256 {
		row := analyzer_row(&a, step)
		if row == nil {
			continue
		}
		made += 1
		for v, k in row {
			worst = max(worst, abs(v - table_row(&tab, step)[k]))
		}
	}
	testing.expectf(t, made > 50 && worst == 0, "%d rows, worst %g", made, worst)
}

// A table and an Analyzer write into memory the caller lends (a view's
// buffer), and leave it to the caller.
@(test)
test_lent_values :: proc(t: ^testing.T) {
	n := RATE
	l := make([]f32, n, context.temp_allocator)
	for &v, i in l {
		v = f32(math.sin(2 * math.PI * 1000 * f64(i) / RATE)) * 0.5
	}
	mine := make([]f32, 64 * 31, context.temp_allocator)
	tab: Table
	table_init_frames(&tab, .Bands, n, 4800, 1, allocator = context.temp_allocator)
	tables_fill(nil, {&tab}, {l, l}, nil)
	a: Analyzer
	analyzer_init(&a, .Bands, 4800, 1, 64, 0, allocator = context.temp_allocator, values = mine)
	testing.expect(t, a.table.lent && raw_data(a.table.values) == raw_data(mine))
	analyzer_push(&a, l, l)
	row, step := analyzer_latest(&a)
	testing.expect(t, row != nil && raw_data(row) >= raw_data(mine) && raw_data(row) < raw_data(mine[len(mine) - 1:]))
	for v, k in row {
		testing.expect(t, v == table_row(&tab, step)[k])
	}
	analyzer_destroy(&a, context.temp_allocator) // leaves `mine`
	testing.expect(t, mine[17] != 0)
}

// A recording's last rows, whose windows run past its end, read the kind's
// silence: bands at FLOOR_DB, not 0 dBFS.
@(test)
test_bands_end_silent :: proc(t: ^testing.T) {
	n := RATE / 2
	l := make([]f32, n, context.temp_allocator)
	for &v, i in l {
		v = 0.5 * f32(math.sin(2 * math.PI * 440 * f64(i) / RATE))
	}
	tab: Table
	table_init_frames(&tab, .Bands, n, 2400, 1, allocator = context.temp_allocator)
	tables_fill(nil, {&tab}, {l, l}, nil)
	last := table_row(&tab, tab.rows - 1)
	for v in last {
		testing.expectf(t, v == FLOOR_DB, "the last row reads %f", v)
	}
	testing.expect(t, slice.max(table_row(&tab, 0)) > -30) // a sounding row is the sound's
}
