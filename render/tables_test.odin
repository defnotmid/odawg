package odawg_render

import "core:mem/virtual"
import "core:slice"
import "core:testing"
import analyze "../analyze"
import base "../base"
import song "../song"
import spec "../spec"

@(private = "file")
SPEC :: `{ key: "A minor", seed: 3, sections: [
	{ name: "a", duration: "2m", bpm: 110, style: "styles/house.json", energy: 0.8, chords: "Am F" } ] }`

@(private = "file")
compose :: proc(t: ^testing.T, arena: ^virtual.Arena) -> ^song.Song {
	_ = virtual.arena_init_growing(arena)
	context.allocator = virtual.arena_allocator(arena)
	s := new(spec.Spec)
	findings := make(base.Findings)
	testing.expect(t, spec.spec_from_json(SPEC, s, &findings))
	add_examples(s, &findings)
	out := new(song.Song)
	testing.expect(t, song.song_from_spec(s, out))
	return out
}

// Every row of a table is what measuring the rendered song at that moment
// gives, on any pool: the mix's energy and spectrum
// per frame, a part's peaks per bucket.
@(test)
test_tables :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose(t, &arena)
	drums_row := song.part_index(s, "drums")
	testing.expect(t, drums_row >= 0)
	drums := song.part_id(s, drums_row)
	energy, spectrum, peaks: Table
	table_init(&energy, s, .Energy, 0, RATE, 30)
	table_init(&spectrum, s, .Spectrum, 0, RATE, 30, 512, .Hann)
	table_init(&peaks, s, .Peaks, drums, 256, 1)
	defer table_destroy(&energy)
	defer table_destroy(&spectrum)
	defer table_destroy(&peaks)
	testing.expect(t, table_stale(s, &energy))
	tables := []^Table{&energy, &spectrum, &peaks}
	tp11 := test_pool(4)
	defer test_pool_free(tp11)
	tables_build(s, tables, &tp11.work_pool)
	testing.expect(t, !table_stale(s, &energy))
	whole := output_from_song(s, {to = base.seconds_from_samples(i64(energy.frames)), stems = true})
	defer output_destroy(&whole)
	testing.expect_value(t, whole.frames, energy.frames)
	n := whole.frames
	worst, quiet: f32
	steps := (n * 30 + RATE - 1) / RATE
	for i in 0 ..< steps {
		at := row_start(&energy, i)
		end := min(at + max(RATE / 30, 512), n)
		e := analyze.energy_from_samples(whole.left[at:end], whole.right[at:end], 0, RATE / 30)
		row := table_row(&energy, i)
		if row == nil {
			// no row: the song is silent there
			quiet = max(quiet, e.rms, e.peak)
			continue
		}
		for v, k in ([5]f32{e.rms, e.peak, e.low, e.mid, e.high}) {
			worst = max(worst, abs(v - row[k]))
		}
		bins: [256]f32
		if at + 512 <= n {
			analyze.spectrum_from_samples(whole.left, whole.right, at, .Hann, bins[:])
		}
		for v, k in table_row(&spectrum, i) {
			worst = max(worst, abs(v - bins[k]))
		}
	}
	st := whole.stems[drums_row]
	for i in 0 ..< (n + 255) / 256 {
		at := row_start(&peaks, i)
		lo, hi: f32
		for k in at ..< min(at + 256, n) {
			lo, hi = min(lo, st[0][k], st[1][k]), max(hi, st[0][k], st[1][k])
		}
		row := table_row(&peaks, i)
		if row == nil {
			quiet = max(quiet, -lo, hi)
			continue
		}
		worst = max(worst, abs(lo - row[0]), abs(hi - row[1]))
	}
	testing.expectf(t, quiet < 1e-4, "the render sounds where a table has no rows (%g)", quiet)
	testing.expectf(t, worst == 0, "tables differ from the render by %g", worst)
	testing.expect(t, table_row(&energy, -1) == nil && table_row(&energy, steps + 10) == nil)
}

// "Make the kick louder" is one command: the drums' stem gets louder at
// the kicks, its tables go stale with the mix's, and another part's stay.
@(test)
test_commands :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose(t, &arena)
	drums_row, bass_row := song.part_index(s, "drums"), song.part_index(s, "bass")
	testing.expect(t, drums_row >= 0 && bass_row >= 0)
	drums, bass := song.part_id(s, drums_row), song.part_id(s, bass_row)
	mix, kick, low: Table
	table_init(&mix, s, .Peaks, 0, 256, 1)
	table_init(&kick, s, .Peaks, drums, 256, 1)
	table_init(&low, s, .Peaks, bass, 256, 1)
	defer table_destroy(&mix)
	defer table_destroy(&kick)
	defer table_destroy(&low)
	tables_build(s, {&mix, &kick, &low})
	before := peak_of(&kick)
	testing.expect(t, song.command_apply(s, {.Pad_Gain_Set, "drums/kick", 6}))
	testing.expect(t, table_stale(s, &mix) && table_stale(s, &kick) && !table_stale(s, &low))
	tables_build(s, {&mix, &kick})
	after := peak_of(&kick)
	testing.expectf(t, after > before * 1.5, "the kick's peak went from %f to %f", before, after)
	testing.expect(t, !song.command_apply(s, {.Pad_Gain_Set, "drums/nothing", 6}))
	testing.expect(t, !song.command_apply(s, {.Part_Gain_Set, "nobody", 0}))
	testing.expect(t, song.command_apply(s, {.Master_Gain_Step, "master", -3}))
	testing.expect(t, table_stale(s, &mix) && !table_stale(s, &kick))
}

@(private = "file")
peak_of :: proc(t: ^Table) -> f32 {
	p: f32
	for i in 0 ..< t.rows {
		p = max(p, -t.values[2 * i], t.values[2 * i + 1])
	}
	return p
}

// A part's table has rows only where it sounds: a part playing two
// sections of four has rows over those (and its tail), none between.
@(test)
test_tables_shape :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	sp := new(spec.Spec)
	findings := make(base.Findings)
	testing.expect(t, spec.spec_from_json(`{ bpm: 120, sections: [ { name: "a", duration: "2m" }, { name: "b", duration: "2m" }, { name: "c", duration: "2m" }, { name: "d", duration: "2m" } ],
		parts: { lead: { instrument: "pluck", play: [ { name: "a", notes: "C5 E5" }, { name: "c", notes: "G5" } ] },
		         pad: { instrument: "pad", play: [ { name: "a..d", chords: true } ] } } }`, sp, &findings))
	add_examples(sp, &findings)
	s := new(song.Song)
	testing.expect(t, song.song_from_spec(sp, s))
	lead: Table
	table_init(&lead, s, .Peaks, song.part_id(s, song.part_index(s, "lead")), 256, 1, allocator = context.temp_allocator)
	testing.expect_value(t, len(lead.spans), 2)
	full := (frames_from_song(s) + 255) / 256
	testing.expectf(t, lead.rows < full * 3 / 4, "lead has %d rows of %d", lead.rows, full)
	testing.expect(t, table_row(&lead, 5 * RATE / 256) == nil) // section b: silent
	// with the mix's table too, both its spans are the render's
	mix: Table
	table_init(&mix, s, .Peaks, 0, 256, 1, allocator = context.temp_allocator)
	tp12 := test_pool(3)
	defer test_pool_free(tp12)
	tables_build(s, {&lead, &mix}, &tp12.work_pool)
	tp13 := test_pool(2)
	defer test_pool_free(tp13)
	whole := output_from_song(s, {to = base.seconds_from_samples(i64(lead.frames)), stems = true, pool = &tp13.work_pool}, context.temp_allocator)
	st := whole.stems[song.part_index(s, "lead")]
	worst: f32
	rows := 0
	for i in 0 ..< full {
		at := i * 256
		lo, hi, mlo, mhi: f32
		for k in at ..< min(at + 256, whole.frames) {
			lo, hi = min(lo, st[0][k], st[1][k]), max(hi, st[0][k], st[1][k])
			mlo, mhi = min(mlo, whole.left[k], whole.right[k]), max(mhi, whole.left[k], whole.right[k])
		}
		if row := table_row(&lead, i); row != nil {
			worst = max(worst, abs(lo - row[0]), abs(hi - row[1]))
			rows += 1
		} else {
			worst = max(worst, -lo, hi)
		}
		if row := table_row(&mix, i); row != nil {
			worst = max(worst, abs(mlo - row[0]), abs(mhi - row[1]))
		}
	}
	testing.expectf(t, worst == 0, "a part's spans differ from its stem by %g", worst)
	testing.expect_value(t, rows, lead.rows)
	// filled from the caller's buffers instead: the same rows
	lead2, mix2: Table
	table_init(&lead2, s, .Peaks, lead.source, 256, 1, allocator = context.temp_allocator)
	table_init(&mix2, s, .Peaks, 0, 256, 1, allocator = context.temp_allocator)
	testing.expect(t, table_stale(s, &lead2))
	// the samples into the caller's own buffers: the same as Output's
	buf := make([]f32, 2 * whole.frames * (1 + len(s.parts)), context.temp_allocator)
	into_mix := [2][]f32{buf[:whole.frames], buf[whole.frames:][:whole.frames]}
	into_parts := make([][2][]f32, len(s.parts), context.temp_allocator)
	for &st, p in into_parts {
		at := 2 * whole.frames * (1 + p)
		st = {buf[at:][:whole.frames], buf[at + whole.frames:][:whole.frames]}
	}
	tp14 := test_pool(3)
	defer test_pool_free(tp14)
	export_into(s, {pool = &tp14.work_pool}, into_mix, into_parts)
	for v, i in into_mix[0] {
		same_samples := v == whole.left[i] && into_parts[0][1][i] == whole.stems[0][1][i]
		if !same_samples {
			testing.expectf(t, false, "export_into differs at %d", i)
			break
		}
	}
	tables_fill(s, {&lead2, &mix2}, into_mix, into_parts)
	testing.expect(t, !table_stale(s, &lead2) && !table_stale(s, &mix2))
	same := len(lead2.values) == len(lead.values) && len(mix2.values) == len(mix.values)
	for v, i in lead2.values {
		same &&= v == lead.values[i]
	}
	for v, i in mix2.values {
		same &&= v == mix.values[i]
	}
	testing.expect(t, same)
}

// A host filling a table's rows as its samples come (table_fill_steps, a
// segment at a time from the samples it holds) fills them as one streamed
// export does (tables_build): the mix's energy, spectrum and bands, a
// part's peaks, the rows at the song's end among them.
@(test)
test_table_fill_steps :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose(t, &arena)
	context.allocator = virtual.arena_allocator(&arena)
	drums := song.part_id(s, song.part_index(s, "drums"))
	init :: proc(s: ^song.Song, drums: song.Node_Id, set: ^[4]Table) {
		table_init(&set[0], s, .Energy, 0, RATE, 30)
		table_init(&set[1], s, .Spectrum, 0, RATE, 30, 512, .Hann)
		table_init(&set[2], s, .Bands, 0, 4096, 1)
		table_init(&set[3], s, .Peaks, drums, 256, 1)
	}
	built, held: [4]Table
	init(s, drums, &built)
	init(s, drums, &held)
	tables_build(s, {&built[0], &built[1], &built[2], &built[3]})
	whole := output_from_song(s, {to = base.seconds_from_samples(i64(built[0].frames)), stems = true})
	n := whole.frames
	SEGMENT :: 4 * RATE
	for &tb in held {
		src := [2][]f32{whole.left, whole.right}
		if stem := stem_from_id(s, tb.source); stem >= 0 {
			src = whole.stems[stem]
		}
		w := table_window(&tb)
		steps := (n * tb.step_den + tb.step_num - 1) / tb.step_num
		done := 0
		for upto := min(SEGMENT, n); done < steps; upto = min(upto + SEGMENT, n) {
			// the steps whose windows the samples so far hold; at the end, the rest
			end := done
			for end < steps && (row_start(&tb, end) + w <= upto || upto == n) {
				end += 1
			}
			if end > done {
				from := row_start(&tb, done)
				table_fill_steps(&tb, done, end, from, src[0][from:upto], src[1][from:upto])
			}
			done = end
		}
	}
	for k in 0 ..< 4 {
		testing.expectf(t, slice.equal(built[k].values, held[k].values), "%v a segment at a time differs from tables_build", built[k].kind)
	}
}

// A table names what it measures by id: every stem's id comes back to it, the
// mix is none, and a node the song hasn't gives a table with no rows, which a
// build leaves alone beside one that has them.
@(test)
test_table_source :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	s := compose(t, &arena)
	context.allocator = virtual.arena_allocator(&arena)
	testing.expect_value(t, stem_from_id(s, 0), i32(STEM_MIX))
	for stem in 0 ..< stem_count(s) {
		testing.expect_value(t, stem_from_id(s, stem_id(s, stem)), i32(stem))
	}
	testing.expect_value(t, stem_from_id(s, song.Node_Id(base.name_id("part nothing"))), i32(STEM_NONE))
	// a track is a node and no stem
	testing.expect_value(t, stem_from_id(s, s.node_ids[0]), i32(STEM_NONE))
	drums := song.part_index(s, "drums")
	gone, good: Table
	table_init(&gone, s, .Peaks, song.Node_Id(base.name_id("part nothing")), 256, 1)
	table_init(&good, s, .Peaks, song.part_id(s, drums), 256, 1)
	testing.expect_value(t, gone.rows, 0)
	testing.expect(t, good.rows > 0)
	testing.expect(t, !table_stale(s, &gone))
	testing.expect(t, table_stale(s, &good))
	tables_build(s, {&gone, &good})
	testing.expect(t, !table_stale(s, &good))
	whole := output_from_song(s, {to = base.seconds_from_samples(i64(good.frames)), stems = true})
	st := whole.stems[drums]
	loudest: f32
	for v in good.values {
		loudest = max(loudest, abs(v))
	}
	testing.expect(t, loudest > 0.001)
	testing.expect(t, loudest <= peak_from_samples(st[0], st[1]) + 1e-5)
}
