package odawg_assets

import "core:fmt"
import "core:hash"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"
import base "../base"
import device "../device"
import render "../render"
import song "../song"
import spec "../spec"
import wav "deps:oicut/audio/wav"
import common "deps:oicut/common"

// A mono 16-bit WAV at `rate` of `frames` frames of a sine at `hz`.
@(private = "file")
sine_wav :: proc(rate, frames: int, hz: f64) -> []u8 {
	samples := make([]f32, frames, context.temp_allocator)
	for &v, i in samples {
		v = f32(16000 * math.sin(2 * math.PI * hz * f64(i) / f64(rate)) / 32767)
	}
	data, _ := wav.encode(samples, rate, 1, .S16, context.temp_allocator)
	return data
}

@(private = "file")
set_row :: proc(b: ^device.Bank, id: device.Set_Id) -> device.Sample_Set {
	return b.sets[device.bank_set_row(b, id)]
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

// A song plays its own view of its sets, made once as it loads: the bank it
// was loaded into may grow (its rows moving) and have its rows written over
// while it plays, and it plays the same. Its view holds only the sets it
// names; a mix's, made the same way from the bank, holds a set two of its
// songs play once. A command can't point a node at another set.
@(test)
test_song_view :: proc(t: ^testing.T) {
	root := scratch_root("view")
	defer os.remove_all(root)
	write(t, root, "keys/c4.wav", sine_wav(44100, 22050, 261.63))
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	findings := make(base.Findings)
	sp := new(spec.Spec)
	testing.expect(t, spec.spec_from_json(`{ bpm: 120, chords: "C", sections: [ { name: "a", duration: "1m" } ],
		sets: { keys: { zones: [ { file: "keys/c4.wav", root: "C4" } ] } },
		parts: { piano: { instrument: { name: "Sampler", set: "keys" }, play: [ { name: "a", notes: "C4 E4 G4 C5" } ] } } }`, sp, &findings))
	host := Bank_Host{root = root}
	bank: device.Bank
	defer device.bank_destroy(&bank)
	testing.expect(t, bank_declare_spec(&bank, sp, &findings, &host))
	frames := make([]f32, 64)
	device.bank_borrow(&bank, "lent", frames) // a set it doesn't name
	testing.expect_value(t, len(bank.sets), 2)
	s := new(song.Song)
	testing.expect(t, song.song_from_spec(sp, s, &bank))
	testing.expect(t, len(s.bank.sets) == 0, "composed, it has no view yet")
	testing.expect(t, song_load(s, &bank, &findings, nil, &host))
	keys, _ := device.bank_set_from_name(&bank, spec.asset_key(sp, "keys"))
	testing.expect(t, len(s.bank.sets) == 1 && s.bank.sets[0].id == keys, "its view: the one set it names")
	out := render.output_from_song(s, {})
	testing.expect(t, render.peak_from_samples(out.left, out.right) > 0.01)
	// the bank grows past every row's room and its rows are written over
	for _ in 0 ..< 1000 {
		device.bank_borrow(&bank, "lent", frames)
	}
	for &z in bank.zones {
		z.sample = -1
	}
	again := render.output_from_song(s, {})
	testing.expect(t, again.frames == out.frames && slice.equal(again.left, out.left) && slice.equal(again.right, out.right), "it plays its view, not the bank")
	// once: a view made again is another song
	testing.expect(t, !song_load(s, &bank, &findings, nil, &host))
	testing.expect(t, !song.song_bank_view(s, &bank))
	testing.expect(t, len(s.bank.sets) == 1)
	// a mix of two songs playing one set: its own view, the set once
	s2 := new(song.Song)
	testing.expect(t, song.song_from_spec(sp, s2, &bank))
	m := new(song.Song)
	song.mix_init(m)
	song.append_song(m, s, 0, "one")
	song.append_song(m, s2, 0, "two")
	song.mix_end(m)
	testing.expect(t, len(m.bank.sets) == 0, "a mix takes no view from its songs")
	testing.expect(t, song.song_bank_view(m, &bank))
	testing.expect(t, len(m.bank.sets) == 1 && m.bank.sets[0].id == keys)
	// a command or a lane moves a Sampler's own values, never the set it
	// plays: not by its row's option (`set`, a control), nor by the field
	set_of :: proc(s: ^song.Song) -> f32 {
		program := i32(s.params[s.tracks[0].instrument][.Program])
		for n in s.programs.nodes[s.programs.programs[program].nodes.first:][:s.programs.programs[program].nodes.count] {
			if row := device.node_row(n.kind); row.name == "Sampler" {
				return n.values[row.slots[0]] // its `set`
			}
		}
		return -1
	}
	testing.expect_value(t, set_of(s), f32(keys))
	testing.expect(t, song.command_apply(s, {.Param_Set, "piano/attack", 0.05}))
	testing.expect(t, song.command_apply(s, {.Param_Set, "piano/out/release", 0.2}))
	testing.expect(t, !song.command_apply(s, {.Param_Set, "piano/set", f64(keys) + 1}))
	testing.expect(t, !song.command_apply(s, {.Param_Set, "piano/out/set", f64(keys) + 1}))
	testing.expect_value(t, set_of(s), f32(keys))
	program := i32(s.params[s.tracks[0].instrument][.Program])
	testing.expect_value(t, device.control_from_path(&s.programs, program, "out/set"), -1)
	c := device.control_from_path(&s.programs, program, "set")
	testing.expect(t, c >= 0 && !device.control_moves(&s.programs, program, c, f32(keys), f32(keys) + 1))
	testing.expect_value(t, set_of(s), f32(keys))
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
	testing.expect(t, found && strings.has_prefix(set_row(&bank, keys).name, "keys#"))
	zs := set_row(&bank, keys).zones
	lo, hi := bank.zones[zs.first], bank.zones[zs.first + 1]
	testing.expectf(t, lo.lo_key == 0 && lo.hi_key == 54 && hi.lo_key == 55 && hi.hi_key == 127, "split: %d..%d, %d..%d", lo.lo_key, lo.hi_key, hi.lo_key, hi.hi_key)
	kit, _ := device.bank_set_from_name(&bank, spec.asset_key(sp, "kit"))
	kick := bank.zones[set_row(&bank, kit).zones.first]
	testing.expect(t, kick.lo_key == 36 && kick.hi_key == 36 && kick.one_shot)
	s := new(song.Song)
	testing.expect(t, song.song_from_spec(sp, s, &bank))
	testing.expect(t, song_load(s, &bank, &findings, nil, &host))
	testing.expectf(t, !has_code(findings, "asset_unavailable"), "%v", findings)
	testing.expect_value(t, int(bank.samples[bank.zones[zs.first].sample].rate), 44100)
	out := render.output_from_song(s, {})
	testing.expect(t, render.peak_from_samples(out.left, out.right) > 0.01)
	// the same files again: nothing new; a file changed: the set again
	sets := len(bank.sets)
	testing.expect(t, bank_declare_spec(&bank, sp, &findings, &host))
	testing.expect_value(t, len(bank.sets), sets)
	write(t, root, "keys/c4.wav", sine_wav(44100, 11025, 261.63))
	testing.expect(t, bank_declare_spec(&bank, sp, &findings, &host))
	newer, _ := device.bank_set_from_name(&bank, spec.asset_key(sp, "keys"))
	testing.expect(t, int(newer) > int(keys) && set_row(&bank, newer).stamp != set_row(&bank, keys).stamp)
	// the song still names the old one, so it stays until its song goes
	live := make([dynamic]device.Set_Id)
	song.sets_of_song(s, &live)
	testing.expect(t, device.bank_collect(&bank, live[:]) == 1) // only the new one: no song names it
	testing.expect(t, device.bank_set_row(&bank, keys) >= 0 && device.bank_set_row(&bank, newer) < 0)
	again := render.output_from_song(s, {})
	testing.expect_value(t, again.frames, out.frames)
	testing.expect(t, slice.equal(again.left, out.left), "the song plays the same after its bank is collected")
	// composed again, the song names what the file is now; the old set goes
	testing.expect(t, bank_declare_spec(&bank, sp, &findings, &host))
	newest, _ := device.bank_set_from_name(&bank, spec.asset_key(sp, "keys"))
	s2 := new(song.Song)
	testing.expect(t, song.song_from_spec(sp, s2, &bank))
	clear(&live)
	song.sets_of_song(s2, &live)
	testing.expect(t, device.bank_collect(&bank, live[:]) == 1)
	testing.expect(t, device.bank_set_row(&bank, keys) < 0 && device.bank_set_row(&bank, newest) >= 0)
	testing.expect(t, device.bank_set_row(&bank, kit) >= 0, "a set unchanged keeps its id")
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
		read = proc(data: rawptr, path: string) -> (Host_Samples, Host_Read) {
			m := (^Mine)(data)
			m.reads += 1
			switch {
			case path == "a440.ogg":
				return {samples = m.samples, channels = 2, rate = device.RATE}, .Read
			case strings.has_suffix(path, ".wav"):
				return {}, .Declined // the loader's own WAV reader
			}
			return {}, .Failed
		},
		stamp = proc(data: rawptr, path: string) -> u64 {return 7},
	}
	// a WAV the host declines: the loader reads it from root itself
	root := scratch_root("host_read")
	defer os.remove_all(root)
	host.root = root
	write(t, root, "c3.wav", sine_wav(44100, 4410, 130.81))
	findings := make(base.Findings, context.temp_allocator)
	sp := new(spec.Spec, context.temp_allocator)
	{
		context.allocator = context.temp_allocator
		testing.expect(t, spec.spec_from_json(`{ sections: [ { name: "a", duration: "1m" } ], sets: { tone: { zones: [ { file: "a440.ogg", root: "A4" }, { file: "c3.wav", root: "C3" } ] } },
			parts: { lead: { instrument: { name: "Sampler", set: "tone" }, play: [ { name: "a", notes: "A4" } ] } } }`, sp, &findings))
	}
	bank: device.Bank
	defer device.bank_destroy(&bank)
	testing.expect(t, bank_declare_spec(&bank, sp, &findings, &host))
	set, _ := device.bank_set_from_name(&bank, spec.asset_key(sp, "tone"))
	testing.expect(t, bank_load(&bank, {{set = set, keys = ~bit_set[0 ..< 128;u128]{}}}, &findings, nil, &host))
	testing.expect_value(t, mine.reads, 2)
	zs := set_row(&bank, set).zones
	smp := bank.samples[bank.zones[zs.first].sample]
	testing.expect(t, smp.format == .F32 && smp.rate == device.RATE && smp.channels == 2)
	testing.expect(t, raw_data(device.sample_f32(&bank, smp)) == raw_data(mine.samples)) // lent, not copied
	declined := bank.samples[bank.zones[zs.first + 1].sample]
	testing.expect(t, declined.format == .I16 && declined.rate == 44100 && declined.channels == 1 && declined.frames == 4800) // the loader's own, at RATE
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
	d := Declaring{findings = &findings, host = &host, files = &files}
	testing.expect(t, declare_sfz(&bank, ref, &d))
	testing.expect_value(t, len(files), 6) // the .sfz and its five samples
	set, found := device.bank_set_from_name(&bank, "inst/piano.sfz")
	testing.expect(t, found)
	// a zone per region with a sample, in the file's order (the release
	// region's too): what each region's Region node plays, by index; how it
	// plays (its tune, level, loop, round robin) is its program's
	zs := bank.zones[set_row(&bank, set).zones.first:][:set_row(&bank, set).zones.count]
	testing.expect_value(t, len(zs), 5)
	soft := zs[0]
	testing.expect(t, soft.lo_key == 60 && soft.hi_key == 66 && soft.hi_velocity == 63)
	testing.expect(t, zs[1].lo_velocity == 64 && zs[2].lo_velocity == 64)
	testing.expect(t, bank.files[bank.zone_file[set_row(&bank, set).zones.first + 1]].path == "inst/samples/c4_loud_1.wav")
	testing.expectf(t, zs[3].lo_key == 67 && zs[3].root == 67, "g4: key %d root %f", zs[3].lo_key, zs[3].root)
	testing.expect(t, bank.files[bank.zone_file[set_row(&bank, set).zones.first + 4]].path == "inst/samples/rel.wav")
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
	testing.expect(t, spec.spec_add_style_text(sp, names[0], `{ instruments: { kit: { pads: { kick: { name: "MembraneSynth" }, open_hat: { name: "MetalSynth" } } } },
		parts: { drums: { instrument: "kit", play: [ { steps: { kick: "x...x...x...x...", open_hat: "..x...x...x...x." } } ] },
		bass: { instrument: { name: "MonoSynth" }, play: [ { degrees: "1 . 1 8 . 1 . 8", subdivision: "8n" } ] } } }`, &findings))
	s := new(song.Song)
	testing.expect(t, song.song_from_spec(sp, s))
	testing.expect(t, !has_code(s.findings, "unknown_style"))
	testing.expect(t, song.part_index(s, "drums") >= 0 && song.part_index(s, "bass") >= 0)
	testing.expect(t, len(s.notes) > 16)
}

// A style file's part plays a set the song brings, and a set the style
// brings itself (its files beside the style file); a set no one has is a
// finding while the others still declare.
@(test)
test_style_plays_song_set :: proc(t: ^testing.T) {
	root := scratch_root("style_set")
	defer os.remove_all(root)
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	write(t, root, "kit/kick.wav", sine_wav(44100, 4410, 60))
	write(t, root, "styles/pad/a3.wav", sine_wav(44100, 4410, 220)) // a style file's paths are from its folder
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
	testing.expect(t, song_load(s, &bank, &s.findings, nil, &host))
	paths := make([dynamic]string)
	for f in s.findings {
		append(&paths, f.path)
	}
	testing.expectf(t, len(s.findings) == 1 && strings.contains(s.findings[0].path, "lost"), "only the lost part: %v", paths[:])
}

// A source's files: a path whose first part names a source is fetched to
// the data directory and verified against the pins; one the pins don't
// list is a finding (until odawg pin), and only the zones a note's key
// and velocity reach are loaded.
@(test)
test_source_pins :: proc(t: ^testing.T) {
	root := scratch_root("sources")
	defer os.remove_all(root)
	data, _ := filepath.join({root, "data"}, context.temp_allocator)
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	// the source's files already fetched (no network in a test): its folder
	// in the data directory holds them, stamped with their SHA-256
	src := spec.Source_Spec{name = "lib", url = "https://example.invalid/lib/"}
	dir := source_dir(data, &src)
	soft, loud := sine_wav(44100, 4410, 220), sine_wav(44100, 4410, 440)
	sfz := "<region> sample=a3_soft.wav pitch_keycenter=57 hivel=64 lorand=0 hirand=0.5 ampeg_release=0.3 amp_velcurve_64=1\n<region> sample=a3_loud.wav pitch_keycenter=57 lovel=65\n"
	pins := make([dynamic]string)
	for f in ([?]struct {
			name: string,
			data: []u8,
		}{{"lib.sfz", transmute([]u8)sfz}, {"a3_soft.wav", soft}, {"a3_loud.wav", loud}}) {
		write(t, dir, f.name, f.data)
		path, _ := filepath.join({dir, f.name}, context.temp_allocator)
		sha, _ := hash_file(path)
		_ = os.write_entire_file(stamp_path(path), sha)
		if f.name != "a3_loud.wav" { // not pinned yet
			append(&pins, fmt.tprintf("%s %d %s", sha, len(f.data), f.name))
		}
	}
	write(t, root, "lib.pins", transmute([]u8)strings.join(pins[:], "\n"))
	findings := make(base.Findings)
	sp := new(spec.Spec)
	testing.expect(t, spec.spec_from_json(`{ sources: { lib: { url: "https://example.invalid/lib/", licence: "CC0-1.0", pins: "lib.pins" } },
		sections: [ { name: "a", duration: "1m" } ],
		parts: { soft: { instrument: { name: "Sampler", set: "lib/lib.sfz" }, play: [ { name: "a", notes: "A3", velocity: 0.3 } ] } } }`, sp, &findings))
	bank: device.Bank
	defer device.bank_destroy(&bank)
	host := Bank_Host{root = root, fetched = data}
	files := make([dynamic]string)
	testing.expectf(t, bank_declare_spec(&bank, sp, &findings, &host, &files), "%v", findings[:])
	testing.expectf(t, !has_code(findings, "unsupported_opcode"), "lorand, hirand, ampeg_release and amp_velcurve_N are read: %v", findings[:])
	testing.expect(t, len(files) == 1 && files[0] == "lib.pins") // the fetched files aren't the song's own
	set, found := device.bank_set_from_name(&bank, "lib/lib.sfz")
	testing.expect(t, found)
	zs := set_row(&bank, set).zones
	s := new(song.Song)
	testing.expect(t, song.song_from_spec(sp, s, &bank))
	needs := make([dynamic]device.Sample_Need)
	song.sample_needs(s, &needs)
	// a soft A3 reaches the soft zone only: the loud one (unpinned) isn't needed
	testing.expect(t, bank_load_at(&bank, data, needs[:], &findings, nil, host = &host))
	testing.expect(t, bank.zones[zs.first].sample >= 0 && bank.zones[zs.first + 1].sample < 0)
	// a loud one reaches the unpinned file: a finding, until it is pinned
	loud_need := device.Sample_Need{set = needs[0].set}
	append(&loud_need.zones, 1)
	testing.expect(t, !bank_load_at(&bank, data, {loud_need}, &findings, nil, host = &host))
	testing.expect(t, has_code(findings, "asset_unavailable"))
	// odawg pin: fetched (here: found fetched) and its pin kept for writing
	host.pinning = true
	testing.expect(t, bank_load_at(&bank, data, {loud_need}, &findings, nil, host = &host))
	f := bank.files[bank.zone_file[zs.first + 1]]
	testing.expect(t, f.sha256 != "" && f.size == i64(len(loud)) && strings.has_suffix(f.url, "lib/a3_loud.wav"))
	// the pins the host writes: the new file merged in, sorted
	updates := pins_update(&bank, sp, &host, &findings, context.temp_allocator)
	testing.expect_value(t, len(updates), 1)
	if len(updates) == 1 {
		u := updates[0]
		testing.expect(t, u.source == "lib" && u.pins_path == "lib.pins" && u.total == 3 && u.added == 1)
		rows := pins_from_text(u.text)
		testing.expect(t, len(rows) == 3 && rows[0].path == "a3_loud.wav" && rows[0].sha256 == f.sha256)
	}
	// a licence odawg doesn't allow: a finding, nothing fetched
	clear(&findings)
	nc := new(spec.Spec)
	testing.expect(t, spec.spec_from_json(`{ sources: { lib: { url: "https://example.invalid/lib/", licence: "CC-BY-NC-4.0", pins: "lib.pins" } },
		sections: [ { name: "a", duration: "1m" } ],
		parts: { soft: { instrument: { name: "Sampler", set: "lib/lib.sfz" }, play: [ { name: "a", notes: "A3" } ] } } }`, nc, &findings))
	other: device.Bank
	defer device.bank_destroy(&other)
	testing.expect(t, !bank_declare_spec(&other, nc, &findings, &host))
	testing.expect(t, has_code(findings, "licence_not_allowed"))
}

// Pins as text and back.
@(test)
test_pins_text :: proc(t: ^testing.T) {
	rows := pins_from_text("# comment\n\nabc 12 notes/a 1.wav\n  def\t34\tb.wav  \nbad line\n")
	testing.expect_value(t, len(rows), 2)
	if len(rows) == 2 {
		testing.expect(t, rows[0] == Pin_Row{"abc", 12, "notes/a 1.wav"} && rows[1] == Pin_Row{"def", 34, "b.wav"})
		back := pins_from_text(pins_text(rows))
		testing.expect(t, len(back) == 2 && back[0] == rows[0] && back[1] == rows[1])
	}
}

// A pad given a list is a round robin on that pad (each a zone of its own
// at the pad's key, records keeping their own velocities); tambourine is a
// pad (General MIDI 54).
@(test)
test_pad_list :: proc(t: ^testing.T) {
	root := scratch_root("pad_list")
	defer os.remove_all(root)
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	for name in ([?]string{"clap1.wav", "clap2.wav", "tamb.wav", "tamb_hit.wav"}) {
		write(t, root, name, sine_wav(44100, 441, 1000))
	}
	findings := make(base.Findings)
	sp := new(spec.Spec)
	testing.expect(t, spec.spec_from_json(`{ sets: { perc: { pads: { clap: [ "clap1.wav", "clap2.wav" ],
		tambourine: [ { file: "tamb.wav", hi_velocity: 90 }, { file: "tamb_hit.wav", lo_velocity: 91 } ] } } },
		sections: [ { name: "a", duration: "1m" } ],
		parts: { p: { instrument: { name: "Sampler", set: "perc" }, play: [ { name: "a", steps: { clap: "x...", tambourine: "..xX" } } ] } } }`, sp, &findings))
	testing.expectf(t, len(findings) == 0, "%v", findings[:])
	bank: device.Bank
	defer device.bank_destroy(&bank)
	host := Bank_Host{root = root}
	testing.expect(t, bank_declare_spec(&bank, sp, &findings, &host))
	set, _ := device.bank_set_from_name(&bank, spec.asset_key(sp, "perc"))
	zs := bank.zones[set_row(&bank, set).zones.first:][:set_row(&bank, set).zones.count]
	testing.expect_value(t, len(zs), 4)
	claps, tambs := 0, 0
	for z in zs {
		testing.expect(t, z.one_shot && z.lo_key == z.hi_key)
		switch z.lo_key {
		case 39:
			claps += 1
		case 54:
			tambs += 1
		}
	}
	testing.expect(t, claps == 2 && tambs == 2)
	// the two claps alternate (one group); the tambourines are layers by velocity
	clap_zones := make([dynamic]device.Zone)
	for z in zs {
		if z.lo_key == 39 {
			append(&clap_zones, z)
		}
	}
	testing.expect(t, clap_zones[0].group == clap_zones[1].group && clap_zones[0].sequence != clap_zones[1].sequence)
}

// Shared data never names a path out of where it is read from: a source's
// file with `..` (in a zone, an SFZ or its pins), a backslash or a drive is
// refused before anything is fetched, and a source's url is https, its
// name a plain folder name, its pins a plain path.
@(test)
test_source_paths :: proc(t: ^testing.T) {
	root := scratch_root("source_paths")
	defer os.remove_all(root)
	data, _ := filepath.join({root, "data"}, context.temp_allocator)
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	for p in ([?]string{"a.wav", "dir/a b.wav", "Shaker, Small/x.wav"}) {
		testing.expectf(t, spec.plain_path(p), "%q is plain", p)
	}
	for p in ([?]string{"", "/etc/x", "../x", "a/../../x", "a/./b", "a//b", "c:x", "a\\b", "a/b/..", "x\n"}) {
		testing.expectf(t, !spec.plain_path(p), "%q is refused", p)
	}
	sha := "0000000000000000000000000000000000000000000000000000000000000000"
	write(t, root, "lib.pins", transmute([]u8)fmt.tprintf("%s 3 ok.wav\n%s 3 ../../escape.wav\n", sha, sha))
	src :: `"lib": { "url": "https://example.invalid/lib/", "licence": "CC0-1.0", "pins": "lib.pins" }`
	findings := make(base.Findings)
	sp := new(spec.Spec)
	testing.expect(t, spec.spec_from_json(fmt.tprintf(`{{ "sources": {{ %s }}, "sets": {{ "kit": {{ "pads": {{ "kick": "lib/../../escape.wav" }} }} }},
		"sections": [ {{ "name": "a", "duration": "1m" }} ],
		"parts": {{ "d": {{ "instrument": {{ "name": "Sampler", "set": "kit" }}, "play": [ {{ "name": "a", "steps": {{ "kick": "x..." }} }} ] }} }} }}`, src), sp, &findings))
	bank: device.Bank
	defer device.bank_destroy(&bank)
	host := Bank_Host{root = root, fetched = data, pinning = true} // even pinning fetches nothing out of the source
	testing.expect(t, !bank_declare_spec(&bank, sp, &findings, &host))
	bad := 0
	for f in findings {
		bad += f.code == "bad_value" ? 1 : 0
	}
	testing.expectf(t, bad == 2, "the pins line and the zone are refused: %v", findings[:]) // ../../escape.wav in the pins, lib/../../escape.wav in the set
	for p in ([?]string{"escape.wav", "../escape.wav"}) {
		out, _ := filepath.join({data, "sources", p}, context.temp_allocator)
		testing.expectf(t, !os.exists(out), "nothing at %s", out)
	}
	// an SFZ fetched from a source plays that source's files only (here
	// already fetched: its pin and stamp in the data directory)
	clear(&findings)
	lib := spec.Source_Spec{name = "lib", url = "https://example.invalid/lib/"}
	sfz := "<region> sample=../../../escape.wav\n"
	write(t, source_dir(data, &lib), "evil.sfz", transmute([]u8)sfz)
	sfz_path, _ := filepath.join({source_dir(data, &lib), "evil.sfz"}, context.temp_allocator)
	sfz_sha, _ := hash_file(sfz_path)
	_ = os.write_entire_file(stamp_path(sfz_path), sfz_sha)
	write(t, root, "lib.pins", transmute([]u8)fmt.tprintf("%s %d evil.sfz\n", sfz_sha, len(sfz)))
	evil := new(spec.Spec)
	testing.expect(t, spec.spec_from_json(fmt.tprintf(`{{ "sources": {{ %s }}, "sections": [ {{ "name": "a", "duration": "1m" }} ],
		"parts": {{ "d": {{ "instrument": {{ "name": "Sampler", "set": "lib/evil.sfz" }}, "play": [ {{ "name": "a", "notes": "C4" }} ] }} }} }}`, src), evil, &findings))
	other: device.Bank
	defer device.bank_destroy(&other)
	host.pinning = false
	testing.expect(t, !bank_declare_spec(&other, evil, &findings, &host))
	testing.expectf(t, has_code(findings, "bad_value"), "the sample outside the source is refused: %v", findings[:])
	// a url that isn't https, a name that isn't a folder's, pins out of the folder
	for bad_source in ([?]string{
		`"lib": { "url": "file:///etc/", "licence": "CC0-1.0", "pins": "lib.pins" }`,
		`"../lib": { "url": "https://example.invalid/lib/", "licence": "CC0-1.0", "pins": "lib.pins" }`,
		`"lib": { "url": "https://example.invalid/lib/", "licence": "CC0-1.0", "pins": "../lib.pins" }`,
	}) {
		clear(&findings)
		x := new(spec.Spec)
		spec.spec_from_json(fmt.tprintf(`{{ "sources": {{ %s }}, "sections": [ {{ "name": "a", "duration": "1m" }} ] }}`, bad_source), x, &findings)
		testing.expectf(t, len(x.sources) == 0 && has_code(findings, "bad_value"), "%s refused: %v", bad_source, findings[:])
	}
}

// A song naming a file that can't be read, beside one that can: every file
// is read once (the one that fails reported, the rest handed to the spec),
// and the reading ends; it doesn't ask for the same files again forever.
@(test)
test_spec_files_end :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	root := scratch_root("spec_files")
	defer os.remove_all(root)
	write(t, root, "instruments/mine.json", transmute([]u8)string(`{ "pad": { "nodes": { "out": { "class": "Osc" } } } }`))
	s := new(spec.Spec)
	findings := make(base.Findings)
	testing.expect(t, spec.spec_from_json(`{ instruments: "instruments/mine.json", sections: [ { name: "a", duration: "1m" } ],
		parts: { a: { instrument: "nowhere/x.json" }, b: { instrument: "pad" } } }`, s, &findings))
	host := Bank_Host{root = root}
	testing.expect(t, !spec_read_files(s, &findings, &host))
	testing.expect_value(t, len(s.instrument_files), 2)
	missing := 0
	for f in findings {
		missing += f.code == "missing_file" ? 1 : 0
	}
	testing.expect_value(t, missing, 1)
}

// A song's own part plays an SFZ from a source its style brings: the path's
// source is found in the song's styles too, as the style's own parts find it.
@(test)
test_style_source_for_song_part :: proc(t: ^testing.T) {
	root := scratch_root("style_source")
	defer os.remove_all(root)
	data, _ := filepath.join({root, "data"}, context.temp_allocator)
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	src := spec.Source_Spec{name = "lib", url = "https://example.invalid/lib/"}
	dir := source_dir(data, &src)
	sfz := "<region> sample=a3.wav pitch_keycenter=57\n"
	pins := make([dynamic]string)
	for f in ([?]struct {
			name: string,
			data: []u8,
		}{{"lib.sfz", transmute([]u8)sfz}, {"a3.wav", sine_wav(44100, 4410, 220)}}) {
		write(t, dir, f.name, f.data)
		path, _ := filepath.join({dir, f.name}, context.temp_allocator)
		sha, _ := hash_file(path)
		_ = os.write_entire_file(stamp_path(path), sha)
		append(&pins, fmt.tprintf("%s %d %s", sha, len(f.data), f.name))
	}
	write(t, root, "styles/lib.pins", transmute([]u8)strings.join(pins[:], "\n"))
	findings := make(base.Findings)
	sp := new(spec.Spec)
	testing.expect(t, spec.spec_from_json(`{ sections: [ { name: "a", duration: "1m", style: "styles/band.json" } ],
		parts: { own: { instrument: { name: "lib/lib.sfz", ampeg_release: 0.05 }, play: [ { name: "a", notes: "A3" } ] } } }`, sp, &findings))
	testing.expect(t, spec.spec_add_style_text(sp, "styles/band.json", `{ sources: { lib: { url: "https://example.invalid/lib/", licence: "CC0-1.0", pins: "lib.pins" } } }`, &findings))
	bank: device.Bank
	defer device.bank_destroy(&bank)
	host := Bank_Host{root = root, fetched = data}
	testing.expectf(t, bank_declare_spec(&bank, sp, &findings, &host), "%v", findings[:])
	testing.expect(t, !has_code(findings, "missing_file"))
	_, found := device.bank_set_from_name(&bank, "lib/lib.sfz")
	testing.expect(t, found)
	s := new(song.Song)
	testing.expect(t, song.song_from_spec(sp, s, &bank))
	testing.expectf(t, song.part_index(s, "own") >= 0 && s.tracks[0].instrument >= 0, "%v", s.findings[:])
}

// A set's samples are the same loaded side by side as one at a time, by every
// way they reach the bank: decoded at RATE, resampled, cut short, a host's
// lent as they are, a host's at another rate. What is decoded is the bank's
// chunk, freed with it. A file whose scratch passes what a thread keeps leaves
// nothing in what follows it.
@(test)
test_load_on_a_pool :: proc(t: ^testing.T) {
	root := scratch_root("pool")
	defer os.remove_all(root)
	whole := sine_wav(48000, 9600, 220)
	write(t, root, "at_rate.wav", whole)
	write(t, root, "other.wav", sine_wav(44100, 4410, 330))
	write(t, root, "cut.wav", whole[:len(whole) / 2])
	write(t, root, "lent.wav", whole)
	write(t, root, "host_other.wav", whole)
	// the file, its floats, then those at RATE: over 10 bytes a frame in scratch
	BIG_FRAMES :: SCRATCH_KEPT / 8
	#assert(BIG_FRAMES * 10 > SCRATCH_KEPT)
	write(t, root, "big.wav", sine_wav(44100, BIG_FRAMES, 110))
	Result :: struct {
		frames:   i64,
		channels: u8,
		format:   device.Sample_Format,
		values:   u64,
	}
	Host_Audio :: struct {
		lent, other: []f32,
	}
	audio := Host_Audio{make([]f32, 4800), make([]f32, 2205)}
	defer delete(audio.lent)
	defer delete(audio.other)
	for i in 0 ..< len(audio.lent) {
		audio.lent[i] = f32(i % 100) / 200
	}
	for i in 0 ..< len(audio.other) {
		audio.other[i] = f32(i % 50) / 100
	}
	load :: proc(t: ^testing.T, root: string, audio: ^Host_Audio, threads: int, big: bool) -> []Result {
		// the bank on this test's allocator, which sees any free it didn't make
		bank: device.Bank
		device.bank_init(&bank)
		defer device.bank_destroy(&bank)
		arena: virtual.Arena
		_ = virtual.arena_init_growing(&arena)
		defer virtual.arena_destroy(&arena)
		out := make([]Result, big ? 6 : 5)
		context.allocator = virtual.arena_allocator(&arena)
		findings := make(base.Findings)
		sp := new(spec.Spec)
		text := strings.concatenate({`{ bpm: 120, chords: "C", sections: [ { name: "a", duration: "1m" } ],
			sets: { tones: { zones: [ `, big ? `{ file: "big.wav", root: "C1" }, ` : "", `{ file: "at_rate.wav", root: "C2" }, { file: "other.wav", root: "C3" }, { file: "cut.wav", root: "C4" },
			                          { file: "lent.wav", root: "C5" }, { file: "host_other.wav", root: "C6" } ] } },
			parts: { p: { instrument: { name: "Sampler", set: "tones" }, play: [ { name: "a", notes: "C4" } ] } } }`})
		testing.expect(t, spec.spec_from_json(text, sp, &findings))
		host := Bank_Host {
			root = root,
			data = audio,
			read = proc(data: rawptr, path: string) -> (Host_Samples, Host_Read) {
				a := (^Host_Audio)(data)
				switch path {
				case "lent.wav":
					return {samples = a.lent, channels = 1, rate = device.RATE}, .Read
				case "host_other.wav":
					return {samples = a.other, channels = 1, rate = 22050}, .Read
				}
				return {}, .Declined
			},
		}
		pool: common.Static_Pool
		if threads > 0 {
			common.init_static_pool(&pool, threads)
			host.pool = &pool.work_pool
		}
		defer if threads > 0 {
			common.destroy_static_pool(&pool)
		}
		testing.expect(t, bank_declare_spec(&bank, sp, &findings, &host))
		set, found := device.bank_set_from_name(&bank, spec.asset_key(sp, "tones"))
		testing.expect(t, found)
		testing.expect(t, bank_load(&bank, {{set = set, keys = ~bit_set[0 ..< 128;u128]{}}}, &findings, nil, &host))
		testing.expectf(t, !has_code(findings, "asset_unavailable"), "%v", findings)
		zs := set_row(&bank, set).zones
		testing.expect_value(t, int(zs.count), len(out))
		for i in 0 ..< min(int(zs.count), len(out)) {
			z := bank.zones[int(zs.first) + i]
			testing.expect(t, z.sample >= 0)
			sm := bank.samples[z.sample]
			h: u64
			switch sm.format {
			case .I16:
				h = hash.fnv64a(slice.to_bytes(device.sample_i16(&bank, sm)))
			case .F32:
				h = hash.fnv64a(slice.to_bytes(device.sample_f32(&bank, sm)))
			}
			out[i] = {sm.frames, sm.channels, sm.format, h}
		}
		// all but the host's lent one are the bank's own
		testing.expect_value(t, len(bank.owned), len(out) - 1)
		return out
	}
	serial := load(t, root, &audio, 0, false)
	defer delete(serial)
	pooled := load(t, root, &audio, 4, false)
	defer delete(pooled)
	testing.expect(t, slice.equal(serial, pooled), "the same samples on a pool")
	testing.expect_value(t, serial[0].frames, i64(9600))
	testing.expect_value(t, serial[1].frames, i64(4800)) // 0.1 s at 44100
	testing.expect(t, serial[2].frames > 0 && serial[2].frames < 9600)
	testing.expect_value(t, serial[3].format, device.Sample_Format.F32)
	testing.expect_value(t, serial[3].frames, i64(4800))
	testing.expect_value(t, serial[4].frames, i64(4800)) // 0.1 s at 22050
	// the big file first: on one thread the rest follow it on the same arena
	after_big := load(t, root, &audio, 0, true)
	defer delete(after_big)
	after_big_pooled := load(t, root, &audio, 4, true)
	defer delete(after_big_pooled)
	testing.expect(t, slice.equal(after_big, after_big_pooled), "the same samples on a pool, with the big file")
	testing.expect(t, slice.equal(after_big[1:], serial), "what follows the big file is as if it weren't there")
	testing.expect(t, abs(after_big[0].frames - i64(BIG_FRAMES) * 48000 / 44100) <= 1)
}
