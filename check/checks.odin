// check: what a rendered song is told about itself, since nobody can listen
// for the agent. Each check is a row: its code and the rule that reads the
// song and its render and reports findings. Add a row, never a branch.
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
	Loudness,
}

Context :: struct {
	song:     ^song.Song,
	out:      ^render.Output,
	loudness: analyze.Loudness,
	findings: ^base.Findings,
}

Check_Row :: struct {
	code: string,
	rule: proc(c: ^Context),
}

CHECK_TABLE := [Check]Check_Row {
	.True_Peak = {"true_peak", proc(c: ^Context) {
			if c.loudness.true_peak > -1 {
				base.report(c.findings, "true_peak", .Warning, "mix", "the mix peaks at %.1f dBTP (above -1): lower the parts or master it (--master streaming)", c.loudness.true_peak)
			}
		}},
	.Clipping = {"clipping", proc(c: ^Context) {
			if p := render.peak_from_samples(c.out.left, c.out.right); p > 1 {
				base.report(c.findings, "clipping", .Error, "mix", "the mix clips: samples reach %.2f (%.1f dBFS)", p, base.gain_to_db(f64(p)))
			}
		}},
	.Silent_Part = {"silent_part", proc(c: ^Context) {
			// the parts' stems (the returns' and buses' follow them)
			for st, i in c.out.stems[:min(len(c.out.stems), len(c.song.parts))] {
				peak := render.peak_from_samples(st[0], st[1])
				if peak < 1e-4 {
					base.report(c.findings, "silent_part", .Warning, base.path_join("parts", c.song.parts[i]), "part %s makes no sound in this range", c.song.parts[i])
				}
			}
		}},
	.Loudness = {"loudness", proc(c: ^Context) {
			l := c.loudness
			if math.is_inf(l.integrated) || l.integrated < -70 {
				base.report(c.findings, "silent_mix", .Error, "mix", "the mix is silent")
				return
			}
			base.report(c.findings, "loudness", .Info, "mix", "%.1f LUFS integrated, %.1f LU range, %.1f dBTP", l.integrated, l.range, l.true_peak)
		}},
}

// Runs every check over a render.
findings_from_render :: proc(s: ^song.Song, out: ^render.Output, findings: ^base.Findings) {
	c := Context{song = s, out = out, findings = findings}
	c.loudness = analyze.loudness_from_samples(out.left, out.right, render.RATE, context.temp_allocator)
	for row in CHECK_TABLE {
		row.rule(&c)
	}
}
