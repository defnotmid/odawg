package odawg_assets

import "core:encoding/endian"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import base "../base"
import device "../device"
import render "../render"
import song "../song"
import spec "../spec"

// A mono 16-bit WAV at `rate` of `frames` frames of a sine at `hz`.
@(private = "file")
sine_wav :: proc(rate, frames: int, hz: f64) -> []u8 {
	b := make([dynamic]u8, context.temp_allocator)
	put :: proc(b: ^[dynamic]u8, v: u32, n: int) {
		x: [4]u8
		endian.unchecked_put_u32le(x[:], v)
		append(b, ..x[:n])
	}
	append(&b, ..transmute([]u8)string("RIFF"))
	put(&b, u32(36 + 2 * frames), 4)
	append(&b, ..transmute([]u8)string("WAVEfmt "))
	put(&b, 16, 4)
	put(&b, 1, 2)
	put(&b, 1, 2)
	put(&b, u32(rate), 4)
	put(&b, u32(2 * rate), 4)
	put(&b, 2, 2)
	put(&b, 16, 2)
	append(&b, ..transmute([]u8)string("data"))
	put(&b, u32(2 * frames), 4)
	for i in 0 ..< frames {
		put(&b, u32(cast(u16)i16(16000 * math.sin(2 * math.PI * hz * f64(i) / f64(rate)))), 2)
	}
	return b[:]
}

@(private = "file")
scratch_root :: proc(name: string) -> string {
	dir := os.get_env("TMPDIR", context.temp_allocator)
	if dir == "" {
		dir = "/tmp"
	}
	root, _ := filepath.join({dir, fmt.tprintf("odawg_sets_%s_%d", name, os.get_pid())}, context.temp_allocator)
	os.remove_all(root)
	os.make_directory_all(root)
	return root
}

@(private = "file")
write :: proc(t: ^testing.T, root, rel: string, data: []u8) {
	path, _ := filepath.join({root, rel}, context.temp_allocator)
	os.make_directory_all(filepath.dir(path))
	testing.expect(t, os.write_entire_file(path, data) == nil)
}

@(private = "file")
has_code :: proc(fs: base.Findings, code: string) -> bool {
	for f in fs {
		if f.code == code {
			return true
		}
	}
	return false
}

// A set the song brings: zones split their keys between roots, pads sit
// at their drum keys, every file is reported, the song plays them at their
// own rate; a file changed declares the set again (new songs hear it, the
// set declared before stays for the songs that use it).
@(test)
test_inline_set :: proc(t: ^testing.T) {
	root := scratch_root("inline")
	defer os.remove_all(root)
	write(t, root, "keys/c3.wav", sine_wav(44100, 22050, 130.81))
	write(t, root, "keys/c4.wav", sine_wav(44100, 22050, 261.63))
	write(t, root, "kit/kick.wav", sine_wav(48000, 4800, 55))
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	findings := make(base.Findings)
	sp := new(spec.Spec)
	testing.expect(t, spec.spec_from_json(`{ bpm: 120, chords: "C", sections: [ { name: "a", duration: "1m" } ],
		sets: { keys: { zones: [ { file: "keys/c3.wav", root: "C3" }, { file: "keys/c4.wav", root: "C4" } ] },
		        kit: { pads: { kick: "kit/kick.wav" } } },
		parts: { piano: { instrument: { name: "Sampler", set: "keys" }, play: [ { name: "a", notes: "C3 E3 G3 C4" } ] },
		         drums: { instrument: { name: "Sampler", set: "kit" }, play: [ { name: "a", steps: { kick: "x...x...x...x..." } } ] } } }`, sp, &findings))
	testing.expect(t, !has_code(findings, "bad_value"))
	host := Bank_Host{root = root}
	bank: device.Bank
	defer device.bank_destroy(&bank)
	files := make([dynamic]string, context.temp_allocator)
	testing.expect(t, bank_declare_spec(&bank, sp, &findings, &host, &files))
	testing.expect_value(t, len(files), 3)
	keys, found := device.bank_set_from_name(&bank, spec.asset_key(sp, "keys"))
	testing.expect(t, found && strings.has_prefix(bank.sets[keys].name, "keys#"))
	zs := bank.sets[keys].zones
	lo, hi := bank.zones[zs.first], bank.zones[zs.first + 1]
	testing.expectf(t, lo.lo_key == 0 && lo.hi_key == 54 && hi.lo_key == 55 && hi.hi_key == 127, "split: %d..%d, %d..%d", lo.lo_key, lo.hi_key, hi.lo_key, hi.hi_key)
	kit, _ := device.bank_set_from_name(&bank, spec.asset_key(sp, "kit"))
	kick := bank.zones[bank.sets[kit].zones.first]
	testing.expect(t, kick.lo_key == 36 && kick.hi_key == 36 && kick.one_shot)
	s := new(song.Song)
	testing.expect(t, song.song_from_spec(sp, s, &bank))
	needs := make([dynamic]device.Sample_Need)
	song.sample_needs(s, &needs)
	testing.expect(t, bank_load(&bank, needs[:], &findings, nil, &host))
	testing.expectf(t, !has_code(findings, "asset_unavailable"), "%v", findings)
	testing.expect_value(t, int(bank.samples[bank.zones[zs.first].sample].rate), 44100)
	out := render.output_from_song(s, {threads = 1})
	testing.expect(t, render.peak_from_samples(out.left, out.right) > 0.01)
	// the same files again: nothing new; a file changed: the set again
	sets := len(bank.sets)
	testing.expect(t, bank_declare_spec(&bank, sp, &findings, &host))
	testing.expect_value(t, len(bank.sets), sets)
	write(t, root, "keys/c4.wav", sine_wav(44100, 11025, 261.63))
	testing.expect(t, bank_declare_spec(&bank, sp, &findings, &host))
	newer, _ := device.bank_set_from_name(&bank, spec.asset_key(sp, "keys"))
	testing.expect(t, int(newer) > int(keys) && bank.sets[newer].stamp != bank.sets[keys].stamp)
}

// A host that decodes its own files lends them: the bank plays its floats
// at their rate, copies nothing.
@(test)
test_host_read :: proc(t: ^testing.T) {
	Mine :: struct {
		samples: []f32,
		reads:   int,
	}
	mine := Mine{samples = make([]f32, 2 * 4410, context.temp_allocator)}
	for i in 0 ..< 4410 {
		v := f32(0.5 * math.sin(2 * math.PI * 440 * f64(i) / 44100))
		mine.samples[2 * i], mine.samples[2 * i + 1] = v, v
	}
	host := Bank_Host {
		data = &mine,
		read = proc(data: rawptr, path: string) -> (Host_Samples, bool) {
			m := (^Mine)(data)
			m.reads += 1
			return {samples = m.samples, channels = 2, rate = 44100}, path == "a440.ogg"
		},
		stamp = proc(data: rawptr, path: string) -> u64 {return 7},
	}
	findings := make(base.Findings, context.temp_allocator)
	sp := new(spec.Spec, context.temp_allocator)
	{
		context.allocator = context.temp_allocator
		testing.expect(t, spec.spec_from_json(`{ sections: [ { name: "a", duration: "1m" } ], sets: { tone: { zones: [ { file: "a440.ogg", root: "A4" } ] } },
			parts: { lead: { instrument: { name: "Sampler", set: "tone" }, play: [ { name: "a", notes: "A4" } ] } } }`, sp, &findings))
	}
	bank: device.Bank
	defer device.bank_destroy(&bank)
	testing.expect(t, bank_declare_spec(&bank, sp, &findings, &host))
	set, _ := device.bank_set_from_name(&bank, spec.asset_key(sp, "tone"))
	testing.expect(t, bank_load(&bank, {{set = set, keys = ~bit_set[0 ..< 128;u128]{}}}, &findings, nil, &host))
	testing.expect_value(t, mine.reads, 1)
	smp := bank.samples[bank.zones[bank.sets[set].zones.first].sample]
	testing.expect(t, smp.format == .F32 && smp.rate == 44100 && smp.channels == 2)
	testing.expect(t, raw_data(device.sample_f32(&bank, smp)) == raw_data(mine.samples)) // lent, not copied
}

// An SFZ: headers inherited, default_path, key and velocity ranges, tune,
// one_shot, round robins by seq_position; release regions left out and an
// opcode odawg doesn't read named once, as information.
@(test)
test_sfz :: proc(t: ^testing.T) {
	root := scratch_root("sfz")
	defer os.remove_all(root)
	for name in ([]string{"c4_soft.wav", "c4_loud_1.wav", "c4_loud_2.wav", "g4.wav", "rel.wav"}) {
		write(t, root, fmt.tprintf("inst/samples/%s", name), sine_wav(44100, 4410, 261.63))
	}
	write(t, root, "inst/piano.sfz", transmute([]u8)string(`// a test piano
<control> default_path=samples/
<global> amp_veltrack=80
<group> lovel=0 hivel=63
<region> sample=c4_soft.wav lokey=c4 hikey=f#4 pitch_keycenter=c4
<group> lovel=64 hivel=127 loop_mode=one_shot
<region> sample=c4_loud_1.wav lokey=60 hikey=66 pitch_keycenter=60 seq_position=2
<region> sample=c4_loud_2.wav lokey=60 hikey=66 pitch_keycenter=60 seq_position=1
<region> sample=g4.wav key=67 tune=-50 volume=-6
<region> sample=rel.wav key=67 trigger=release
`))
	findings := make(base.Findings, context.temp_allocator)
	host := Bank_Host{root = root}
	bank: device.Bank
	defer device.bank_destroy(&bank)
	files := make([dynamic]string, context.temp_allocator)
	ref := spec.Asset_Ref{name = "inst/piano.sfz"}
	testing.expect(t, declare_sfz(&bank, ref, &findings, &host, &files))
	testing.expect_value(t, len(files), 6) // the .sfz and its five samples
	set, found := device.bank_set_from_name(&bank, "inst/piano.sfz")
	testing.expect(t, found)
	zs := bank.zones[bank.sets[set].zones.first:][:bank.sets[set].zones.count]
	testing.expect_value(t, len(zs), 4) // the release region left out
	soft := zs[0]
	testing.expect(t, soft.lo_key == 60 && soft.hi_key == 66 && soft.hi_velocity == 63 && !soft.one_shot)
	// zones in the file's order; in the round robin, seq_position 1 is first
	testing.expect(t, zs[1].lo_velocity == 64 && zs[1].one_shot && zs[1].sequence == 1 && zs[2].sequence == 0 && zs[2].group == zs[1].group)
	testing.expect(t, bank.files[bank.zone_file[bank.sets[set].zones.first + 1]].path == "inst/samples/c4_loud_1.wav")
	g := zs[3]
	testing.expectf(t, g.lo_key == 67 && abs(g.root - 67.5) < 1e-4 && abs(g.gain - 0.501) < 0.01, "g4: key %d root %f gain %f", g.lo_key, g.root, g.gain)
	testing.expect(t, has_code(findings, "unsupported_opcode"))
	testing.expect(t, bank_load(&bank, {{set = set, keys = ~bit_set[0 ..< 128;u128]{}}}, &findings, nil, &host))
	testing.expect(t, !has_code(findings, "asset_unavailable"))
}

// A style from a file: named by its path, read by the host, composed as the
// shipped ones are.
@(test)
test_style_file :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	findings := make(base.Findings)
	sp := new(spec.Spec)
	testing.expect(t, spec.spec_from_json(`{ bpm: 124, sections: [ { name: "a", duration: "2m", style: "styles/disco.json", chords: "Am7 D9" } ] }`, sp, &findings))
	names := make([dynamic]string)
	spec.style_files(sp, &names)
	testing.expect(t, len(names) == 1 && names[0] == "styles/disco.json")
	testing.expect(t, spec.spec_add_style_text(sp, names[0], `{ parts: { drums: { instrument: { name: "DrumMachine", machine: "909" }, play: [ { steps: { kick: "x...x...x...x...", open_hat: "..x...x...x...x." } } ] },
		bass: { instrument: "bass", play: [ { degrees: "1 . 1 8 . 1 . 8", subdivision: "8n" } ] } } }`, &findings))
	s := new(song.Song)
	testing.expect(t, song.song_from_spec(sp, s))
	testing.expect(t, !has_code(s.findings, "unknown_style"))
	testing.expect(t, song.part_index(s, "drums") >= 0 && song.part_index(s, "bass") >= 0)
	testing.expect(t, len(s.notes) > 16)
}

// A style file's part plays a set the song brings, and a set the style
// brings itself; a set no one has is a finding while the others still
// declare.
@(test)
test_style_plays_song_set :: proc(t: ^testing.T) {
	root := scratch_root("style_set")
	defer os.remove_all(root)
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	write(t, root, "kit/kick.wav", sine_wav(44100, 4410, 60))
	write(t, root, "pad/a3.wav", sine_wav(44100, 4410, 220))
	findings := make(base.Findings)
	sp := new(spec.Spec)
	testing.expect(t, spec.spec_from_json(`{ sets: { kit: { pads: { kick: "kit/kick.wav" } } },
		sections: [ { name: "a", duration: "1m", style: "styles/mine.json", chords: "Am" } ] }`, sp, &findings))
	testing.expect(t, spec.spec_add_style_text(sp, "styles/mine.json", `{ sets: { pad: { zones: [ { file: "pad/a3.wav", root: "A3" } ] } },
		parts: { drums: { instrument: { name: "Sampler", set: "kit" }, play: [ { steps: { kick: "x...x...x...x..." } } ] },
		         keys: { instrument: { name: "Sampler", set: "pad" }, play: [ { degrees: "1", subdivision: "1n" } ] },
		         lost: { instrument: { name: "Sampler", set: "nowhere/at_all" }, play: [ { degrees: "1", subdivision: "1n" } ] } } }`, &findings))
	bank: device.Bank
	defer device.bank_destroy(&bank)
	host := Bank_Host{root = root}
	testing.expect(t, !bank_declare_spec(&bank, sp, &findings, &host)) // nowhere/at_all
	testing.expect(t, has_code(findings, "unknown_asset"))
	_, kit := device.bank_set_from_name(&bank, spec.asset_key(sp, "kit"))
	testing.expect(t, kit)
	found := false
	for s in bank.sets {
		found ||= strings.has_prefix(s.name, "pad#")
	}
	testing.expect(t, found)
	clear(&findings)
	s := new(song.Song)
	song.song_from_spec(sp, s, &bank)
	needs := make([dynamic]device.Sample_Need)
	song.sample_needs(s, &needs)
	testing.expect(t, bank_load(&bank, needs[:], &s.findings, nil, &host))
	paths := make([dynamic]string)
	for f in s.findings {
		append(&paths, f.path)
	}
	testing.expectf(t, len(s.findings) == 1 && strings.contains(s.findings[0].path, "lost"), "only the lost part: %v", paths[:])
}
