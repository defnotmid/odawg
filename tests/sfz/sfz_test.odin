// An SFZ instrument end to end: its file and samples on disk, declared and
// loaded as a host does, composed and rendered; what each region plays
// heard as frequencies and levels.
package odawg_sfz_test

import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:testing"
import assets "../../assets"
import base "../../base"
import device "../../device"
import render "../../render"
import song "../../song"
import spec "../../spec"
import wav "deps:oicut/audio/wav"

RATE :: 48000

// A mono 16-bit WAV of a sine at `hz`, `seconds` long.
sine_wav :: proc(hz: f64, seconds: f64) -> []u8 {
	samples := make([]f32, int(seconds * RATE), context.temp_allocator)
	for &v, i in samples {
		v = f32(math.sin(2 * math.PI * hz * f64(i) / RATE) * 16000 / 32767)
	}
	data, _ := wav.encode(samples, RATE, 1, .S16, context.temp_allocator)
	return data
}

// A 44.1 kHz recording, as many libraries' are: 440 Hz for its first 0.75 s
// (33075 frames), 880 Hz after.
two_halves_44k :: proc() -> []u8 {
	samples := make([]f32, 44100, context.temp_allocator)
	for &v, i in samples {
		hz := i < 33075 ? 440.0 : 880.0
		v = f32(math.sin(2 * math.PI * hz * f64(i) / 44100) * 16000 / 32767)
	}
	data, _ := wav.encode(samples, 44100, 1, .S16, context.temp_allocator)
	return data
}

// The same at 880 Hz, a second, as Ogg Vorbis: ffmpeg -f lavfi -i
// "aevalsrc=0.488*sin(2*PI*880*t):s=48000:d=1" -c:a libvorbis -q:a 2
// -map_metadata -1 -fflags +bitexact c880.ogg
C880_OGG :: #load("c880.ogg")

SFZ :: `// what the test hears
<control> default_path=samples/ set_cc20=0 label_cc20=Mic
<global> amp_veltrack=0 ampeg_release=0.01
// velocity layers on C4: soft 440, loud 660
<group> key=60
<region> sample=a440.wav lovel=0 hivel=63
<region> sample=b660.wav lovel=64 hivel=127
// a round robin on D4: 440, then 880
<group> key=62
<region> sample=a440.wav seq_length=2 seq_position=1
<region> sample=c880.ogg seq_length=2 seq_position=2
<group>
// pitch: A4 from a 440 whose key is A3, an octave up
<region> sample=a440.wav key=69 pitch_keycenter=57
// E4 plays 440; its release, 2000
<region> sample=a440.wav key=64
<region> sample=r2000.wav key=64 trigger=release
// F4: 330 only where CC 20 is at 64 or more (the row sets it)
<region> sample=d330.wav key=65 locc20=64
// G4: a voice its group's next note cuts (off_by its own group)
<region> sample=a440.wav key=67 group=1 off_by=1 loop_mode=loop_continuous loop_start=0 loop_end=47999
// C5: 440 under the switch C1, 660 under C#1
<region> sample=a440.wav key=72 sw_lokey=24 sw_hikey=25 sw_last=24 sw_default=24
<region> sample=b660.wav key=72 sw_lokey=24 sw_hikey=25 sw_last=25
// D5: a sine generator at its pitch
<region> sample=*sine key=74
// E5: a flex envelope (written with a leading zero) closes it in 0.1 s
<region> sample=a440.wav key=76 eg01_time0=0 eg01_level0=1 eg01_time1=0.1 eg01_level1=0 eg01_amplitude=100
// F5: a 44.1 kHz recording from its offset in its own frames, 0.05 s before
// its 880 Hz (read as RATE's frames it would start 0.1 s before)
<region> sample=halves44k.wav key=77 pitch_keycenter=77 offset=30870
`

@(test)
test_sfz_instrument :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	join :: proc(parts: ..string) -> string {
		p, _ := filepath.join(parts, context.temp_allocator)
		return p
	}
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	root := join(tmp != "" ? tmp : "/tmp", fmt.tprintf("odawg_sfz_%d", os.get_pid()))
	defer os.remove_all(root)
	_ = os.make_directory_all(join(root, "inst", "samples"))
	write :: proc(root, path: string, data: []u8) {
		p, _ := filepath.join({root, path}, context.temp_allocator)
		_ = os.write_entire_file(p, data)
	}
	write(root, "inst/test.sfz", transmute([]u8)string(SFZ))
	for f in ([]struct {
			name: string,
			hz:   f64,
		}{{"a440.wav", 440}, {"b660.wav", 660}, {"d330.wav", 330}, {"r2000.wav", 2000}}) {
		write(root, join("inst/samples", f.name), sine_wav(f.hz, f.name == "r2000.wav" ? 0.2 : 1))
	}
	write(root, "inst/samples/c880.ogg", C880_OGG)
	write(root, "inst/samples/halves44k.wav", two_halves_44k())
	sp := new(spec.Spec)
	findings := make(base.Findings)
	testing.expect(t, spec.spec_from_json(`{ bpm: 120, gain_db: 0, seed: 1, sections: [ { name: "a", duration: "8m" } ],
		parts: { p: { gain_db: 0, instrument: { name: "inst/test.sfz", Mic: 127, ampeg_release: 0.01 }, play: [ { name: "a", events: [
			{ time: 0, note: "C4", duration: 0.4, velocity: 0.3 },
			{ time: 0.5, note: "C4", duration: 0.4, velocity: 0.9 },
			{ time: 1, note: "D4", duration: 0.4 }, { time: 1.5, note: "D4", duration: 0.4 },
			{ time: 2, note: "A4", duration: 0.4 },
			{ time: 2.5, note: "E4", duration: 0.3 },
			{ time: 3.5, note: "F4", duration: 0.4 },
			{ time: 4, note: "G4", duration: 2 }, { time: 4.5, note: "G4", duration: 0.3 },
			{ time: 5.5, note: "C5", duration: 0.4 }, { time: 6, note: "C#1", duration: 0.1 }, { time: 6.5, note: "C5", duration: 0.4 },
			{ time: 7, note: "D5", duration: 0.4 }, { time: 7.5, note: "E5", duration: 0.4 }, { time: 8, note: "F5", duration: 0.4 } ] } ] } } }`, sp, &findings))
	host := assets.Bank_Host{root = root}
	bank: device.Bank
	defer device.bank_destroy(&bank)
	testing.expectf(t, assets.bank_declare_spec(&bank, sp, &findings, &host), "%v", findings[:])
	s := new(song.Song)
	testing.expect(t, song.song_from_spec(sp, s, &bank))
	needs := make([dynamic]device.Sample_Need)
	song.sample_needs(s, &needs)
	testing.expect(t, assets.bank_load(&bank, needs[:], &findings, nil, &host))
	append(&s.findings, ..findings[:])
	for f in s.findings {
		testing.expectf(t, f.severity != .Error, "%s: %s", f.code, f.message)
	}
	// its CC as a knob to read (by number and label), fixed until automation
	{
		d := s.tracks[0].instrument
		program := i32(s.params[d][.Program])
		mic := device.control_of(&s.programs, program, base.name_id("Mic"))
		cc := device.control_of(&s.programs, program, base.name_id("cc20"))
		testing.expect(t, mic != nil && cc != nil && mic.value == 127 && cc.value == 127)
		testing.expect(t, !song.command_apply(s, {.Param_Set, "p/cc20", 0}))
	}
	out := render.output_from_song(s, {})
	defer render.output_destroy(&out)
	// a window's frequency (its zero crossings) and level
	hear :: proc(out: render.Output, from, to: f64) -> (hz, rms: f64) {
		a, b := int(from * RATE), min(int(to * RATE), out.frames)
		crossings := 0
		sum: f64
		for i in a + 1 ..< b {
			if (out.left[i - 1] < 0) != (out.left[i] < 0) {
				crossings += 1
			}
			sum += f64(out.left[i] * out.left[i])
		}
		n := f64(max(b - a, 1))
		return f64(crossings) / 2 / (n / RATE), math.sqrt(sum / n)
	}
	near :: proc(t: ^testing.T, what: string, out: render.Output, at, want: f64) {
		hz, rms := hear(out, at + 0.05, at + 0.25)
		testing.expectf(t, rms > 0.05 && abs(hz / want - 1) < 0.02, "%s: %.1f Hz (level %.3f), want %.0f", what, hz, rms, want)
	}
	near(t, "a soft C4: the soft layer", out, 0, 440)
	near(t, "a loud C4: the loud layer", out, 0.5, 660)
	near(t, "D4, first in its round robin", out, 1, 440)
	near(t, "D4, second: an Ogg Vorbis sample", out, 1.5, 880)
	near(t, "A4 from an A3 recording", out, 2, 880)
	near(t, "E4", out, 2.5, 440)
	{
		hz, rms := hear(out, 2.85, 2.95)
		testing.expectf(t, rms > 0.05 && abs(hz / 2000 - 1) < 0.03, "E4's release trigger: %.1f Hz (level %.3f)", hz, rms)
	}
	near(t, "F4 where its CC holds", out, 3.5, 330)
	{
		_, rms := hear(out, 4.9, 5.4)
		testing.expectf(t, rms < 1e-3, "G4's first voice, cut by the second: level %.4f", rms)
	}
	near(t, "C5 under C1", out, 5.5, 440)
	{
		_, rms := hear(out, 6, 6.1)
		testing.expectf(t, rms < 1e-3, "the keyswitch sounds: level %.4f", rms)
	}
	near(t, "C5 under C#1", out, 6.5, 660)
	near(t, "D5's sine", out, 7, 587.33)
	{
		_, early := hear(out, 7.5, 7.55)
		_, late := hear(out, 7.65, 7.85)
		testing.expectf(t, early > 0.05 && late < early * 0.01, "E5's flex envelope: %.3f then %.4f", early, late)
	}
	near(t, "F5: a 44.1 kHz recording from its offset, in its own frames", out, 8, 880)
}

// A layered row whose SFZ layer can't play a note yet (its region's file
// isn't loaded: a host plays on until it is): that region's voice is
// silent from its first sample, and a voice of the same program starting
// while it holds (the loaded region) plays beside it. Every voice a call
// runs has its nodes started (v0.0.36 ran the silent voice's envelope
// unstarted: a crash), the missing region plays silence and the rest
// sound.
@(test)
test_layer_unavailable :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	join :: proc(parts: ..string) -> string {
		p, _ := filepath.join(parts, context.temp_allocator)
		return p
	}
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	root := join(tmp != "" ? tmp : "/tmp", fmt.tprintf("odawg_sfz_missing_%d", os.get_pid()))
	defer os.remove_all(root)
	_ = os.make_directory_all(join(root, "inst", "samples"))
	write :: proc(root, path: string, data: []u8) {
		p, _ := filepath.join({root, path}, context.temp_allocator)
		_ = os.write_entire_file(p, data)
	}
	// soft.wav is never written: its region can't play
	write(root, "inst/two.sfz", transmute([]u8)string(`<control> default_path=samples/
<global> amp_veltrack=0 ampeg_release=0.05
<region> sample=soft.wav lovel=0 hivel=63
<region> sample=loud.wav lovel=64 hivel=127
`))
	write(root, "inst/samples/loud.wav", sine_wav(660, 2))
	sp := new(spec.Spec)
	findings := make(base.Findings)
	testing.expect(t, spec.spec_from_json(`{ bpm: 120, gain_db: 0, seed: 1, sections: [ { name: "a", duration: "2m" } ],
		instruments: { grit: { mono: true, portamento: 0.03, nodes: {
			env: { class: "Env", attack: 0.01, decay: 0.2, sustain: 0.6, release: 0.1 },
			out: { class: "Osc", wave: "triangle", amp: "env", gain_db: -12 } } } },
		parts: { p: { gain_db: 0, instrument: { layers: [ { instrument: "grit" }, { instrument: { name: "inst/two.sfz" }, gain_db: -8 } ] }, play: [ { name: "a", events: [
			{ time: 0, note: "F1", duration: 2, velocity: 0.3 },
			{ time: 0.5, note: "C4", duration: 1, velocity: 0.85 },
			{ time: 2.5, note: "F1", duration: 0.5, velocity: 0.3 } ] } ] } } }`, sp, &findings))
	host := assets.Bank_Host{root = root}
	bank: device.Bank
	defer device.bank_destroy(&bank)
	_ = assets.bank_declare_spec(&bank, sp, &findings, &host)
	s := new(song.Song)
	testing.expect(t, song.song_from_spec(sp, s, &bank))
	needs := make([dynamic]device.Sample_Need)
	song.sample_needs(s, &needs)
	_ = assets.bank_load(&bank, needs[:], &findings, nil, &host) // soft.wav: a finding, and it plays on
	out := render.output_from_song(s, {})
	defer render.output_destroy(&out)
	level :: proc(out: render.Output, from, to: f64) -> (peak: f32) {
		for i in int(from * RATE) ..< min(int(to * RATE), out.frames) {
			peak = max(peak, abs(out.left[i]), abs(out.right[i]))
		}
		return
	}
	testing.expectf(t, level(out, 0.1, 0.4) > 0.01, "the row's other layer under the missing region: silent")
	testing.expectf(t, level(out, 0.6, 1.4) > 0.05, "the loaded region beside the missing one's voice: silent")
	for v in out.left {
		testing.expect(t, !math.is_nan(v) && abs(v) < 4)
	}
}
