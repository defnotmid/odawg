package odawg_song

import "core:fmt"
import "core:math"
import "core:strings"
import base "../base"
import spec "../spec"
import tempo "../tempo"
import theory "../theory"

// The form: each section's length (whole bars), tempo and meter, carried
// over from the section before when it says nothing; then the sections that
// must start at a time, and the song's duration, are met by moving flex
// sections by whole bars, leaving out optional ones, and nudging the tempo.

// A section while the form is laid out.
@(private = "file")
Laying :: struct {
	spec:        ^spec.Section_Spec,
	bpm0, bpm1:  f64,
	bpb:         int,
	bars:        int,
	flex:        [2]int, // 0: none
	min_seconds: f64, // a line under it: it lasts at least this
	dropped:     bool,
}

@(private = "file")
seconds_of :: proc(l: Laying) -> f64 {return f64(tempo.seconds_from_ramp(f64(l.bars * l.bpb), l.bpm0, l.bpm1))}

@(private = "file")
seconds_at :: proc(l: Laying, bars: int) -> f64 {return f64(tempo.seconds_from_ramp(f64(bars * l.bpb), l.bpm0, l.bpm1))}

lay_out :: proc(s: ^spec.Spec, song: ^Song) -> bool {
	if len(s.sections) == 0 {
		append(&s.sections, spec.Section_Spec{name = "song", duration = {"4m", spec.UNSET_SECONDS}, start = spec.UNSET_SECONDS, energy = base.UNSET, flex = {{"", spec.UNSET_SECONDS}, {"", spec.UNSET_SECONDS}}})
	}
	lay := make([]Laying, len(s.sections), context.temp_allocator)
	bpm, bpb, bars := s.bpm, int(s.beats_per_bar), 4
	for &ss, i in s.sections {
		l := &lay[i]
		l.spec = &ss
		path := base.path_join("sections", ss.name)
		if ss.bpm[0] > 0 {
			l.bpm0, l.bpm1 = ss.bpm[0], ss.bpm[1]
		} else {
			l.bpm0, l.bpm1 = bpm, bpm
		}
		if ss.beats_per_bar > 0 {
			bpb = int(ss.beats_per_bar)
		}
		l.bpb = bpb
		d := ss.duration
		switch {
		case !math.is_nan(f64(d.seconds)):
			l.min_seconds = f64(d.seconds)
		case d.text != "":
			len_, ok := tempo.length_from_string(d.text, bpb)
			switch {
			case !ok:
				base.report(&song.findings, "bad_value", .Error, base.path_join(path, "duration"), "section %s: %q is not a length (\"8m\", \"2:0:0\", or seconds)", ss.name, d.text)
			case len_.in_seconds:
				l.min_seconds = len_.value
			case:
				whole := len_.value / f64(bpb)
				bars = max(1, int(math.ceil(whole - 1e-9)))
				if math.abs(whole - math.round(whole)) > 1e-6 {
					base.report(&song.findings, "not_whole_bars", .Warning, base.path_join(path, "duration"), "section %s: %q is not whole bars of %d beats; it lasts %d bars", ss.name, d.text, bpb, bars)
				}
			}
		}
		if l.min_seconds > 0 {
			bars = bars_lasting(l.min_seconds, l.bpm0, l.bpm1, bpb)
			if ss.stretch == "tempo" {
				stretch_to(l, l.min_seconds, &song.findings)
				bars = l.bars
			}
		}
		l.bars = bars
		if ss.flex[0].text != "" || ss.flex[1].text != "" {
			lo, ok_lo := tempo.length_from_string(ss.flex[0].text, bpb)
			hi, ok_hi := tempo.length_from_string(ss.flex[1].text, bpb)
			if ok_lo && ok_hi && !lo.in_seconds && !hi.in_seconds && lo.value <= hi.value {
				l.flex = {max(1, int(math.round(lo.value / f64(bpb)))), max(1, int(math.round(hi.value / f64(bpb))))}
				l.bars = clamp(l.bars, l.flex[0], l.flex[1])
			} else {
				base.report(&song.findings, "bad_value", .Error, base.path_join(path, "flex"), "section %s: flex is {{ \"4m\", \"8m\" }}, the fewest and most bars", ss.name)
			}
		}
		bpm = l.bpm1
	}

	// each section that must start at a time, then the song's end
	from, from_seconds := 0, 0.0
	for &ss, i in s.sections {
		if math.is_nan(f64(ss.start)) {
			continue
		}
		target := f64(ss.start - s.start)
		what := fmt.tprintf("section %s's start (%.3fs)", ss.name, ss.start)
		if i == 0 {
			if math.abs(target) > 1e-6 {
				base.report(&song.findings, "start_unreachable", .Error, base.path_join(base.path_join("sections", ss.name), "start"), "%s: the first section starts with the song (%.3fs)", what, s.start)
			}
			continue
		}
		fit_span(lay[from:i], target - from_seconds, START_TEMPO_LIMIT, false, "start_unreachable", what, &song.findings)
		from, from_seconds = i, target
	}
	if !math.is_nan(f64(s.duration)) {
		fit_span(lay[from:], f64(s.duration) - from_seconds, DURATION_TEMPO_LIMIT, true, "duration_unreachable", fmt.tprintf("the song's duration (%.3fs)", s.duration), &song.findings)
	}

	style, energy, chords := s.style, s.energy, s.chords
	energy = math.is_nan(energy) ? 0.5 : energy
	for l in lay {
		if l.dropped {
			continue
		}
		ss := l.spec
		tempo.tempo_push(&song.tempo, f64(l.bars * l.bpb), l.bpm0, l.bpm1)
		g := song.tempo.segments[len(song.tempo.segments) - 1]
		if ss.style != "" {
			style = ss.style
		}
		if !math.is_nan(ss.energy) {
			energy = clamp(ss.energy, 0, 1)
		}
		if ss.chords != "" {
			chords = ss.chords
		}
		sec := Section {
			name = ss.name, beat = g.beat, beats = g.beats, start = g.seconds, stop = g.seconds + base.Seconds(seconds_of(l)),
			bpm0 = l.bpm0, bpm1 = l.bpm1, beats_per_bar = l.bpb, bars = l.bars, style = style_intern(song, style), energy = energy,
			transition_part = ss.transition_part,
		}
		sec.chords.first = i32(len(song.chords))
		if chords == "" || !theory.progression_from_string(chords, &song.chords) {
			if chords != "" {
				base.report(&song.findings, "bad_value", .Error, base.path_join(base.path_join("sections", ss.name), "chords"), "section %s: %q is not a progression (\"Am7 F C G\")", ss.name, chords)
				resize(&song.chords, int(sec.chords.first))
			}
			append(&song.chords, theory.tonic_chord(song.key))
		}
		sec.chords.count = i32(len(song.chords)) - sec.chords.first
		if ss.transition != "" {
			found := false
			for row, t in TRANSITIONS {
				if row.name == ss.transition {
					sec.transition, found = t, true
				}
			}
			if !found {
				base.report(&song.findings, "bad_value", .Error, base.path_join(base.path_join("sections", ss.name), "transition"), "section %s: %q is not none, riser, impact, fill, pause or cut", ss.name, ss.transition)
			}
		}
		append(&song.sections, sec)
	}
	if len(song.sections) > 0 {
		song.duration = song.sections[len(song.sections) - 1].stop
	}
	return len(song.sections) > 0
}

// The fewest whole bars lasting at least `seconds`.
@(private = "file")
bars_lasting :: proc(seconds, bpm0, bpm1: f64, bpb: int) -> int {
	n := max(1, int(math.ceil(seconds / f64(tempo.seconds_from_ramp(f64(bpb), bpm0, bpm1)) - 1e-9)))
	for n > 1 && f64(tempo.seconds_from_ramp(f64((n - 1) * bpb), bpm0, bpm1)) >= seconds - 1e-9 {
		n -= 1
	}
	for f64(tempo.seconds_from_ramp(f64(n * bpb), bpm0, bpm1)) < seconds - 1e-9 {
		n += 1
	}
	return n
}

// `stretch = "tempo"`: the nearest whole bars, the tempo nudged (at most 6 %)
// so they last exactly `seconds`.
@(private = "file")
stretch_to :: proc(l: ^Laying, seconds: f64, findings: ^base.Findings) {
	n := max(1, int(math.round(seconds / seconds_at(l^, 1))))
	k := seconds_at(l^, n) / seconds
	if math.abs(k - 1) > START_TEMPO_LIMIT {
		base.report(findings, "stretch_limit", .Info, base.path_join("sections", l.spec.name), "section %s: %d bars would need the tempo %+.1f%% to last %.3fs; rounded up to whole bars instead", l.spec.name, n, (k - 1) * 100, seconds)
		l.bars = bars_lasting(seconds, l.bpm0, l.bpm1, l.bpb)
		return
	}
	l.bars, l.bpm0, l.bpm1 = n, l.bpm0 * k, l.bpm1 * k
}

// Makes the sections of `span` last `target` seconds: flex sections move by
// whole bars toward it, optional ones are left out (last first) when
// allowed, then the tempo moves by at most `limit` (only sections no line
// sizes get faster). What can't be met is reported with each section's
// least length.
@(private = "file")
fit_span :: proc(span: []Laying, target: f64, limit: f64, allow_drop: bool, code, what: string, findings: ^base.Findings) {
	total :: proc(span: []Laying) -> f64 {
		t := 0.0
		for l in span {
			if !l.dropped {
				t += seconds_of(l)
			}
		}
		return t
	}
	flex_toward :: proc(span: []Laying, target: f64) {
		for {
			cur := total(span)
			best, best_d, best_err := -1, 0, math.abs(cur - target)
			#reverse for l, i in span {
				if l.flex[0] == 0 || l.dropped {
					continue
				}
				for d in ([2]int{-1, 1}) {
					nb := l.bars + d
					if nb < l.flex[0] || nb > l.flex[1] || seconds_at(l, nb) < l.min_seconds - 1e-9 {
						continue
					}
					if err := math.abs(cur - seconds_of(l) + seconds_at(l, nb) - target); err < best_err - 1e-9 {
						best, best_d, best_err = i, d, err
					}
				}
			}
			if best < 0 {
				return
			}
			span[best].bars += best_d
		}
	}
	if target <= 0 {
		base.report(findings, code, .Error, "", "%s: it comes before the sections leading to it could start", what)
		return
	}
	flex_toward(span, target)
	if allow_drop {
		#reverse for &l in span {
			if total(span) <= target * (1 + limit) + 1e-9 {
				break
			}
			if l.spec.optional && !l.dropped {
				l.dropped = true
				base.report(findings, "section_dropped", .Info, base.path_join("sections", l.spec.name), "section %s (optional) is left out to meet %s", l.spec.name, what)
				flex_toward(span, target)
			}
		}
	}
	cur := total(span)
	if math.abs(cur - target) < 1e-9 {
		return
	}
	slower := cur < target
	scalable := 0.0
	for l in span {
		if !l.dropped && (slower || l.min_seconds == 0) {
			scalable += seconds_of(l)
		}
	}
	need := scalable - (cur - target)
	k := need > 0 ? scalable / need : math.INF_F64 // tempo factor
	if math.abs(k - 1) > limit + 1e-9 {
		b := strings.builder_make(context.temp_allocator)
		for l, i in span {
			if l.dropped {
				continue
			}
			least := l
			if l.flex[0] > 0 {
				least.bars = l.flex[0]
			}
			fmt.sbprintf(&b, "%s%s %.1fs", i > 0 ? ", " : "", l.spec.name, seconds_of(least) / (l.min_seconds > 0 ? 1 : 1 + limit))
		}
		base.report(findings, code, .Error, "", "%s: the sections before it last %.1fs, %.1fs asked (each at least: %s); shorten a line, give a section flex or optional, or move the target", what, cur, target, strings.to_string(b))
		k = clamp(k, 1 - limit, 1 + limit)
	}
	for &l in span {
		if !l.dropped && (slower || l.min_seconds == 0) {
			l.bpm0 *= k
			l.bpm1 *= k
		}
	}
}
