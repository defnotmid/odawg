// check: what a rendered song is told about itself, since nobody can listen
// for the agent. Each check is a row: its code and the rule that reads the
// song and what was measured of its render (Measures) and reports findings.
// Add a row, never a branch. A render is measured whole (findings_from_render)
// or as it streams, chunk by chunk (Measuring), the same way either way.
package odawg_check

import "core:math"
import analyze "../analyze"
import base "../base"
import render "../render"
import song "../song"

Check :: enum u8 {
	True_Peak,
	Clipping,
	Silent_Part,
	Buried_Part,
	Loudness,
}

// What the checks read of a render: its mix's loudness and peak (linear:
// above 1 it clips), and each measured part's peak (song.parts order,
// linear; a render without stems measures none); the K-weighted energy of
// the mix and of each measured part every 100 ms (analyze.Steps), from
// `from` (song seconds) for `samples`, a section's loudness read from them.
Measures :: struct {
	loudness:    analyze.Loudness,
	mix_peak:    f32,
	part_peaks:  []f32,
	mix_energy:  []f64,
	part_energy: [][]f64,
	part_peak_steps: [][]f32, // each measured part's sample peak (linear) every 100 ms step
	from:        f64,
	samples:     i64,
}

// A part more than BURIED_LU under the mix in every section it plays is
// buried (inaudible in a mix, SOUND_DESIGN.md); the raise it's told puts it
// BURIED_TARGET_LU under where it's loudest against the mix. A section
// span under 400 ms holds no loudness block and isn't judged.
BURIED_LU :: 15
BURIED_TARGET_LU :: 12

// A section as the measured render holds it: its whole 100 ms steps
// (counted in samples from the render's first, so no rounding moves a
// boundary) and its seconds within the render.
Section_Span :: struct {
	first, last: int, // steps [first, last)
	from, to:    f64, // song seconds
}

// What the rules read: the song, what was measured, and from both once,
// each section's span and where each part plays (plays[part * sections +
// section]: a note of its, an attack of a track that's heard, sounding in
// the section within the render; a tail or silence isn't playing).
Context :: struct {
	song:     ^song.Song,
	measures: ^Measures,
	findings: ^base.Findings,
	spans:    []Section_Span,
	plays:    []bool,
	balance:  []Balance_Row, // balance_from_measures's
}

// A part in a section against the mix (balance_from_measures): its
// integrated loudness over the section (BS.1770's gates: where it sounds;
// -inf where it's silent or the span holds no 400 ms block), the mix's over
// the same span, how far under the mix it sits (LU; +inf where it's
// silent), its sample peak there (dBFS: a hit that lands reads loud here
// and low in loudness), and whether a note of its sounds there.
Balance_Row :: struct {
	lufs:    f64,
	mix:     f64,
	under:   f64,
	peak_db: f64,
	plays:   bool,
}

// Every measured part (song.parts order) against the mix in every section
// of the render (clipped to its range), then over the song: part-major,
// len(s.sections) + 1 rows a part. row(part, section) is
// rows[part * (len(s.sections) + 1) + section]; at section
// len(s.sections), the part over the sections it plays and the mix over
// the same. From what Measuring measured as the render streamed (its stems
// pushed): no render of its own. In `allocator`.
balance_from_measures :: proc(s: ^song.Song, m: ^Measures, allocator := context.allocator) -> []Balance_Row {
	spans, plays := section_plays(s, m)
	return balance_rows(s, m, spans, plays, allocator)
}

@(private = "file")
balance_rows :: proc(s: ^song.Song, m: ^Measures, spans: []Section_Span, plays: []bool, allocator := context.allocator) -> []Balance_Row {
	parts := min(len(m.part_energy), len(s.parts))
	per := len(spans) + 1
	rows := make([]Balance_Row, parts * per, allocator)
	mix := make([]f64, len(spans), context.temp_allocator)
	for sp, j in spans {
		mix[j] = analyze.loudness_of_span(m.mix_energy, sp.first, sp.last)
	}
	played := make([dynamic][2]int, context.temp_allocator)
	for energy, i in m.part_energy[:parts] {
		peaks := m.part_peak_steps[i]
		peak_over :: proc(peaks: []f32, first, last: int) -> f32 {
			p: f32
			for v in peaks[clamp(first, 0, len(peaks)):clamp(last, 0, len(peaks))] {
				p = max(p, v)
			}
			return p
		}
		clear(&played)
		song_peak: f32
		for sp, j in spans {
			part := analyze.loudness_of_span(energy, sp.first, sp.last)
			peak := peak_over(peaks, sp.first, sp.last)
			rows[i * per + j] = {lufs = part, mix = mix[j], under = mix[j] - part, peak_db = base.gain_to_db(f64(peak)), plays = plays[i * len(spans) + j]}
			if plays[i * len(spans) + j] {
				append(&played, [2]int{sp.first, sp.last})
				song_peak = max(song_peak, peak)
			}
		}
		part := analyze.loudness_of_spans(energy, played[:])
		whole := analyze.loudness_of_spans(m.mix_energy, played[:])
		rows[i * per + len(spans)] = {lufs = part, mix = whole, under = whole - part, peak_db = base.gain_to_db(f64(song_peak)), plays = len(played) > 0}
	}
	return rows
}

// Whether part i plays anywhere in the render.
@(private = "file")
part_plays :: proc(c: ^Context, i: int) -> bool {
	for p in c.plays[i * len(c.spans):][:len(c.spans)] {
		if p {
			return true
		}
	}
	return false
}

Check_Row :: struct {
	code: string,
	rule: proc(c: ^Context),
}

CHECK_TABLE := [Check]Check_Row {
	.True_Peak = {"true_peak", proc(c: ^Context) {
			if c.measures.loudness.true_peak > -1 {
				base.report(c.findings, "true_peak", .Warning, "mix", "the mix peaks at %.1f dBTP (above -1): lower the parts or master it (--master streaming)", c.measures.loudness.true_peak)
			}
		}},
	.Clipping = {"clipping", proc(c: ^Context) {
			if p := c.measures.mix_peak; p > 1 {
				base.report(c.findings, "clipping", .Error, "mix", "the mix clips: samples reach %.2f (%.1f dBFS)", p, base.gain_to_db(f64(p)))
			}
		}},
	.Silent_Part = {"silent_part", proc(c: ^Context) {
			for peak, i in c.measures.part_peaks[:min(len(c.measures.part_peaks), len(c.song.parts))] {
				// a part with no notes here is quiet by design
				if peak < 1e-4 && part_plays(c, i) {
					base.report(c.findings, "silent_part", .Warning, base.path_join("parts", c.song.parts[i]), "part %s has notes in this range but makes no sound", c.song.parts[i])
				}
			}
		}},
	.Buried_Part = {"buried_part", proc(c: ^Context) {
			sections := len(c.spans)
			for i in 0 ..< len(c.balance) / (sections + 1) {
				least := math.INF_F64 // how far under the mix it sits where it's loudest against it
				for b in c.balance[i * (sections + 1):][:sections] {
					if b.plays && !math.is_inf(b.lufs) {
						least = min(least, b.under)
					}
				}
				if !math.is_inf(least) && least > BURIED_LU {
					name := c.song.parts[i]
					base.report(c.findings, "buried_part", .Warning, base.path_join("parts", name), "part %s sits %.1f LU or more under the mix in every section it plays: raise parts/%s/gain_db by about %.0f dB (%d LU under where it's loudest)", name, least, name, least - BURIED_TARGET_LU, BURIED_TARGET_LU)
				}
			}
		}},
	.Loudness = {"loudness", proc(c: ^Context) {
			l := c.measures.loudness
			if math.is_inf(l.integrated) || l.integrated < -70 {
				base.report(c.findings, "silent_mix", .Error, "mix", "the mix is silent")
				return
			}
			base.report(c.findings, "loudness", .Info, "mix", "%.1f LUFS integrated, %.1f LU range, %.1f dBTP", l.integrated, l.range, l.true_peak)
		}},
}

// Runs every check over what was measured of a render.
findings_from_measures :: proc(s: ^song.Song, m: ^Measures, findings: ^base.Findings) {
	c := Context{song = s, measures = m, findings = findings}
	c.spans, c.plays = section_plays(s, m)
	c.balance = balance_rows(s, m, c.spans, c.plays, context.temp_allocator)
	for row in CHECK_TABLE {
		row.rule(&c)
	}
}

// Each section's span of the render, and where each part plays (Context).
// In temp memory.
@(private = "file")
section_plays :: proc(s: ^song.Song, m: ^Measures) -> (spans: []Section_Span, plays: []bool) {
	STEP :: i64(render.RATE / 10)
	start := i64(math.round(m.from * render.RATE)) // the render's first sample
	from, to := f64(start) / render.RATE, f64(start + m.samples) / render.RATE
	spans = make([]Section_Span, len(s.sections), context.temp_allocator)
	for sec, j in s.sections {
		a := max(i64(math.round(sec.start * render.RATE)) - start, 0)
		b := max(i64(math.round(sec.stop * render.RATE)) - start, 0)
		spans[j] = {first = int((a + STEP - 1) / STEP), last = int(b / STEP), from = max(sec.start, from), to = min(sec.stop, to)}
	}
	plays = make([]bool, len(s.parts) * len(spans), context.temp_allocator)
	for t in s.tracks {
		if t.muted {
			continue
		}
		for n in t.notes.first ..< base.span_end(t.notes) {
			if s.notes.kind[n] != .Attack {
				continue
			}
			t0 := s.notes.time[n]
			t1 := t0 + s.notes.duration[n]
			beat := s.notes.beat[n]
			for sp, j in spans {
				// it's written there (its beat: humanize and swing move its
				// time, not where it belongs) and sounds within the render, or
				// it sounds through a loudness block of it (a held note); a
				// note's last moments past a section's end aren't playing in it
				sec := s.sections[j]
				written := beat >= sec.beat && beat < sec.beat + sec.beats && t0 < sp.to && t1 > sp.from
				if written || min(t1, sp.to) - max(t0, sp.from) >= 0.4 {
					plays[int(t.part) * len(spans) + j] = true
				}
			}
		}
	}
	return
}

// Runs every check over a render in memory (its stems, the parts' first,
// when it has them): measured whole, the same as streamed.
findings_from_render :: proc(s: ^song.Song, out: ^render.Output, findings: ^base.Findings) {
	m: Measuring
	measuring_init(&m, s, context.temp_allocator, out.from)
	defer measuring_destroy(&m)
	measuring_push(&m, out.left, out.right, out.stems)
	measures := measures_from(&m, context.temp_allocator)
	findings_from_measures(s, &measures, findings)
}

// A render being measured as it streams: its mix through a loudness meter,
// each part's peak and K-weighted energy. Push its chunks in order (a
// sink's: the mix and the stems, the parts' first), then take what was
// measured. `from`: the song second it starts at (a range's).
Measuring :: struct {
	meter:      analyze.Meter,
	peak_steps: [][dynamic]f32, // each part's sample peak every 100 ms step (the steps' grid)
	parts:      []analyze.Steps,
	measured:   int, // the parts whose stems came
	from:       f64,
}

measuring_init :: proc(m: ^Measuring, s: ^song.Song, allocator := context.allocator, from := 0.0) {
	analyze.meter_init(&m.meter, render.RATE, allocator)
	m.peak_steps = make([][dynamic]f32, len(s.parts), allocator)
	for &p in m.peak_steps {
		p = make([dynamic]f32, allocator)
	}
	m.parts = make([]analyze.Steps, len(s.parts), allocator)
	for &p in m.parts {
		analyze.steps_init(&p, render.RATE, allocator)
	}
	m.from = from
}

measuring_destroy :: proc(m: ^Measuring) {
	analyze.meter_destroy(&m.meter)
	for &p in m.parts {
		analyze.steps_destroy(&p)
	}
	for p in m.peak_steps {
		delete(p)
	}
}

// The next chunk: the mix, and the stems (stem_count's order: the parts'
// first; nil or fewer: those parts unmeasured).
measuring_push :: proc(m: ^Measuring, l, r: []f32, stems: [][2][]f32) {
	STEP :: i64(render.RATE / 10)
	at := m.meter.pushed // the chunk's first sample, counted from the render's
	analyze.meter_push(&m.meter, l, r)
	k := min(len(stems), len(m.parts))
	m.measured = max(m.measured, k)
	n := len(l)
	for st in stems[:k] {
		n = min(n, len(st[0]), len(st[1]))
	}
	// each part's peak a step at a time: the chunk cut where steps begin,
	// once for every part (a streamed chunk is one step or two)
	for j := 0; j < n; {
		g := at + i64(j)
		step := int(g / STEP)
		end := min(n, j + int(STEP - g % STEP))
		for st, i in stems[:k] {
			p := &m.peak_steps[i]
			if len(p) <= step {
				resize(p, step + 1)
			}
			p[step] = max(p[step], render.peak_from_samples(st[0][j:end], st[1][j:end]))
		}
		j = end
	}
	for st, i in stems[:k] {
		analyze.steps_push(&m.parts[i], st[0], st[1])
	}
}

// What was measured; its energies are the Measuring's (valid until it is
// destroyed).
measures_from :: proc(m: ^Measuring, allocator := context.allocator) -> Measures {
	energy := make([][]f64, m.measured, allocator)
	steps := make([][]f32, m.measured, allocator)
	peaks := make([]f32, m.measured, allocator)
	for &e, i in energy {
		e = m.parts[i].energy[:]
		// its finished steps' (the loudness steps'), and the whole render's
		steps[i] = m.peak_steps[i][:min(len(m.peak_steps[i]), len(e))]
		for v in m.peak_steps[i] {
			peaks[i] = max(peaks[i], v)
		}
	}
	return {loudness = analyze.loudness_from_meter(&m.meter, allocator), mix_peak = m.meter.sample_peak, part_peaks = peaks, mix_energy = m.meter.energy[:], part_energy = energy, part_peak_steps = steps, from = m.from, samples = m.meter.pushed}
}
