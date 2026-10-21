package odawg_assets

import base "../base"
import device "../device"
import "core:encoding/endian"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// ---- WAV files written by the test ---------------------------------------------------

@(private = "file")
Wav_Spec :: struct {
	format:    int, // 1 PCM, 3 float
	bits:      int,
	channels:  int,
	rate:      int,
	extensible: bool,
	loop:      [2]u32, // smpl loop start, end (inclusive); {0, 0}: none
}

// A WAV of `frames` frames whose channel c holds sin(2π hz t + c).
@(private = "file")
wav_write :: proc(spec: Wav_Spec, frames: int, hz: f64, amplitude := 0.5) -> []u8 {
	b: [dynamic]u8
	b.allocator = context.temp_allocator
	put4 :: proc(b: ^[dynamic]u8, s: string) {append(b, ..transmute([]u8)s)}
	put32 :: proc(b: ^[dynamic]u8, v: u32) {
		x: [4]u8
		endian.unchecked_put_u32le(x[:], v)
		append(b, ..x[:])
	}
	put16 :: proc(b: ^[dynamic]u8, v: u16) {
		x: [2]u8
		endian.unchecked_put_u16le(x[:], v)
		append(b, ..x[:])
	}
	width := spec.bits / 8
	align := width * spec.channels
	put4(&b, "RIFF")
	put32(&b, 0)
	put4(&b, "WAVE")
	put4(&b, "fmt ")
	put32(&b, spec.extensible ? 40 : 16)
	put16(&b, spec.extensible ? 0xfffe : u16(spec.format))
	put16(&b, u16(spec.channels))
	put32(&b, u32(spec.rate))
	put32(&b, u32(spec.rate * align))
	put16(&b, u16(align))
	put16(&b, u16(spec.bits))
	if spec.extensible {
		put16(&b, 22)
		put16(&b, u16(spec.bits))
		put32(&b, 0)
		put16(&b, u16(spec.format))
		append(&b, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71) // the KSDATAFORMAT GUID's rest
	}
	put4(&b, "LIST") // an unknown chunk of odd size, padded
	put32(&b, 3)
	append(&b, 1, 2, 3, 0)
	put4(&b, "data")
	put32(&b, u32(frames * align))
	for f in 0 ..< frames {
		for c in 0 ..< spec.channels {
			v := amplitude * math.sin(2 * math.PI * hz * f64(f) / f64(spec.rate) + f64(c))
			switch {
			case spec.format == 3 && spec.bits == 32:
				put32(&b, transmute(u32)f32(v))
			case spec.bits == 8:
				append(&b, u8(i32(math.round(v * 127)) + 128))
			case:
				q := i64(math.round(v * f64(i64(1) << uint(spec.bits - 1))))
				for k in 0 ..< width {
					append(&b, u8(q >> uint(8 * k)))
				}
			}
		}
	}
	if spec.loop != {0, 0} {
		put4(&b, "smpl")
		put32(&b, 36 + 24)
		for _ in 0 ..< 7 {
			put32(&b, 0)
		}
		put32(&b, 1) // loops
		put32(&b, 0)
		put32(&b, 0) // cue id
		put32(&b, 0) // type
		put32(&b, spec.loop[0])
		put32(&b, spec.loop[1])
		put32(&b, 0)
		put32(&b, 0)
	}
	endian.unchecked_put_u32le(b[4:], u32(len(b) - 8))
	return b[:]
}

@(test)
test_wav_decode :: proc(t: ^testing.T) {
	specs := []Wav_Spec {
		{format = 1, bits = 16, channels = 1, rate = 44100},
		{format = 1, bits = 24, channels = 2, rate = 48000, loop = {100, 899}},
		{format = 1, bits = 32, channels = 2, rate = 96000},
		{format = 3, bits = 32, channels = 2, rate = 44100, extensible = true},
		{format = 1, bits = 24, channels = 2, rate = 44100, extensible = true},
		{format = 1, bits = 8, channels = 1, rate = 22050},
	}
	for spec in specs {
		frames := 1000
		data := wav_write(spec, frames, 441)
		d, err := decode(data, context.temp_allocator)
		testing.expectf(t, err == nil, "%v: %v", spec, err)
		testing.expect_value(t, d.channels, spec.channels)
		testing.expect_value(t, d.rate, spec.rate)
		testing.expect_value(t, len(d.samples), frames * spec.channels)
		// within the format's quantization
		tolerance := spec.format == 3 ? 1e-6 : max(1.0 / f64(i64(1) << uint(spec.bits - 1)), 6e-8) // f32's own step
		worst: f64
		for f in 0 ..< frames {
			for c in 0 ..< spec.channels {
				want := 0.5 * math.sin(2 * math.PI * 441 * f64(f) / f64(spec.rate) + f64(c))
				worst = max(worst, abs(f64(d.samples[f * spec.channels + c]) - want))
			}
		}
		testing.expectf(t, worst <= tolerance, "%v: off by %v", spec, worst)
		if spec.loop != {0, 0} {
			testing.expect(t, d.loop_from == 100 && d.loop_to == 900)
		} else {
			testing.expect(t, d.loop_to <= d.loop_from)
		}
	}
	_, err := decode(transmute([]u8)string("RIFF\x04\x00\x00\x00WAVE"), context.temp_allocator)
	testing.expect(t, err != nil)
}

// ---- resampling ----------------------------------------------------------------------

@(private = "file")
sine_stereo :: proc(hz: f64, rate: int, seconds: f64) -> []f32 {
	n := int(seconds * f64(rate))
	out := make([]f32, 2 * n, context.temp_allocator)
	for i in 0 ..< n {
		v := f32(0.5 * math.sin(2 * math.PI * hz * f64(i) / f64(rate)))
		out[2 * i], out[2 * i + 1] = v, -v
	}
	return out
}

// A sine resampled to 48 kHz is the same sine at 48 kHz: in tune, at its
// level, to about -90 dB, away from the edges.
@(test)
test_resample_in_tune :: proc(t: ^testing.T) {
	for c in ([][2]f64{{44100, 1000}, {44100, 15000}, {96000, 3000}, {88200, 440}, {32000, 7000}, {22050, 5000}}) {
		rate, hz := int(c[0]), c[1]
		out := resample(sine_stereo(hz, rate, 0.5), 2, rate, context.temp_allocator)
		n := len(out) / 2
		testing.expect_value(t, n, int(math.ceil(0.5 * f64(rate) * device.RATE / f64(rate))))
		worst: f64
		for j in n / 10 ..< n * 9 / 10 {
			want := 0.5 * math.sin(2 * math.PI * hz * f64(j) / device.RATE)
			worst = max(worst, abs(f64(out[2 * j]) - want), abs(f64(out[2 * j + 1]) + want))
		}
		testing.expectf(t, worst < 0.5 * 1e-4, "%v Hz at %v: off by %v", hz, rate, worst)
	}
}

// Content above 24 kHz in a 96 kHz file doesn't fold back into the 48 kHz
// result.
@(test)
test_resample_no_aliasing :: proc(t: ^testing.T) {
	for hz in ([]f64{30000, 26000, 40000}) {
		out := resample(sine_stereo(hz, 96000, 0.25), 2, 96000, context.temp_allocator)
		n := len(out) / 2
		s: f64
		for j in n / 10 ..< n * 9 / 10 {
			s += f64(out[2 * j]) * f64(out[2 * j])
		}
		level := math.sqrt(s / f64(n * 8 / 10)) / (0.5 / math.SQRT_TWO)
		testing.expectf(t, level < 1e-4, "%v Hz folds back at %v", hz, level)
	}
}

// ---- the register --------------------------------------------------------------------

@(private = "file")
is_hex :: proc(s: string, n: int) -> bool {
	if len(s) != n {
		return false
	}
	for c in s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

@(test)
test_register_sanity :: proc(t: ^testing.T) {
	for l in LICENCE_TABLE {
		for bad in ([]string{"NC", "ND", "SA"}) {
			testing.expectf(t, !strings.contains(l.spdx, bad), "licence %s is not allowed", l.spdx)
		}
		testing.expect(t, strings.has_prefix(l.url, "https://creativecommons.org/"))
	}
	for src in SOURCE_TABLE {
		testing.expectf(t, src.name != "" && src.title != "" && src.credit != "" && src.quote != "" && src.quoted != "" && src.checked != "", "source %s is missing a field", src.name)
		// raw files at a pinned commit, never a branch
		testing.expectf(t, strings.has_prefix(src.url, "https://") && strings.has_suffix(src.url, "/"), "%s: url %s", src.name, src.url)
		parts := strings.split(strings.trim_suffix(src.url, "/"), "/", context.temp_allocator)
		testing.expectf(t, is_hex(parts[len(parts) - 1], 40), "%s: url %s has no pinned commit", src.name, src.url)
		testing.expect(t, strings.has_prefix(src.page, "https://"))
	}
	used := make([]bool, len(FILE_TABLE), context.temp_allocator)
	for &s, si in SET_TABLE {
		for other in SET_TABLE[si + 1:] {
			testing.expectf(t, other.name != s.name, "set %s twice", s.name)
		}
		testing.expectf(t, strings.count(s.name, "/") == 1, "set name %s is not library/instrument", s.name)
		testing.expect(t, s.zones.count > 0 && base.span_end(s.zones) <= i32(len(ZONE_TABLE)))
		zones := set_zones(&s)
		for &z, i in zones {
			f, ok := file_index_from_path(s.source, z.path)
			testing.expectf(t, ok, "%s: %s isn't pinned", s.name, z.path)
			if ok {
				used[f] = true
			}
			testing.expect(t, z.lo_key <= z.hi_key && z.lo_velocity <= z.hi_velocity && z.hi_velocity <= 127)
			// zones that overlap answer the same keys and velocities (a round robin)
			for &o in zones[i + 1:] {
				overlap := z.lo_key <= o.hi_key && o.lo_key <= z.hi_key && z.lo_velocity <= o.hi_velocity && o.lo_velocity <= z.hi_velocity
				same := z.lo_key == o.lo_key && z.hi_key == o.hi_key && z.lo_velocity == o.lo_velocity && z.hi_velocity == o.hi_velocity
				testing.expectf(t, !overlap || same, "%s: %s and %s overlap", s.name, z.path, o.path)
			}
		}
		// every velocity of every key a zone answers has a zone
		for key in 0 ..= 127 {
			answered := [128]bool{}
			any := false
			for &z in zones {
				if key >= int(z.lo_key) && key <= int(z.hi_key) {
					any = true
					for v in z.lo_velocity ..= z.hi_velocity {
						answered[v] = true
					}
				}
			}
			if any {
				for v in 1 ..= 127 {
					testing.expectf(t, answered[v], "%s: key %d velocity %d has no zone", s.name, key, v)
					if !answered[v] {
						break
					}
				}
			}
		}
	}
	for &f, i in FILE_TABLE {
		testing.expectf(t, is_hex(f.sha256, 64) && f.size > 0, "%s: bad pin", f.path)
		testing.expectf(t, used[i], "%s is pinned but no zone plays it", f.path)
		testing.expect(t, !strings.contains(f.path, "\\") && !strings.has_prefix(f.path, "/") && !strings.contains(f.path, ".."))
	}
	// a kit answers every pad a song names
	kit, ok := set_row_from_name("virtuosity/drums")
	testing.expect(t, ok)
	for pad in ([]string{"kick", "snare", "rim", "hat", "open_hat", "crash", "ride", "tom_low", "tom_mid", "tom_high"}) {
		gm, _ := device.gm_key(pad)
		key := u8(gm)
		found := false
		for z in set_zones(kit) {
			found ||= z.lo_key <= key && key <= z.hi_key && z.one_shot
		}
		testing.expectf(t, found, "the kit has no %v", pad)
	}
	// URLs keep their slashes and escape the rest
	f := File_Row{source = .VSCO2, path = "Strings/Violin Section/susVib/VlnEns_susVib_F#3_v1.wav"}
	testing.expect_value(t, file_url(&f), "https://raw.githubusercontent.com/sgossner/VSCO-2-CE/440300901dfe9275fd84e0b7763af1f8443ae62e/Strings/Violin%20Section/susVib/VlnEns_susVib_F%233_v1.wav")
}

// ---- loading into a bank (no network) ------------------------------------------------

@(private = "file")
temp_root :: proc(name: string) -> string {
	base_dir := os.get_env("TMPDIR", context.temp_allocator)
	if base_dir == "" {
		base_dir = "/tmp"
	}
	root, _ := filepath.join({base_dir, fmt.tprintf("odawg_test_%s_%d", name, os.get_pid())}, context.temp_allocator)
	os.remove_all(root)
	return root
}

// A real set's zones loaded from files the test writes (short 44.1 kHz
// sines): its samples at 48 kHz, its round-robin groups numbered.
@(test)
test_load_set :: proc(t: ^testing.T) {
	root := temp_root("load")
	defer os.remove_all(root)
	s, ok := set_row_from_name("karoryfer/growlybass")
	testing.expect(t, ok)
	frames := 2205 // 50 ms
	for &z in set_zones(s) {
		f, _ := file_index_from_path(s.source, z.path)
		path := file_path(root, &FILE_TABLE[f])
		os.make_directory_all(filepath.dir(path))
		werr := os.write_entire_file(path, wav_write({format = 1, bits = 24, channels = 1, rate = 44100}, frames, 220))
		testing.expect(t, werr == nil)
	}
	bank: device.Bank
	defer device.bank_destroy(&bank)
	findings := make(base.Findings, context.temp_allocator)
	err := declare_set(&bank, s)
	testing.expectf(t, err == nil, "%v", err)
	testing.expect(t, bank_load_at(&bank, root, {{set = 0, keys = ~bit_set[0 ..< 128;u128]{}}}, &findings, trust_disk = true))
	testing.expect_value(t, len(bank.sets), 1)
	testing.expect_value(t, int(bank.sets[0].zones.count), int(s.zones.count))
	testing.expect_value(t, len(bank.samples), int(s.zones.count)) // a file each
	for smp in bank.samples {
		// 50 ms, resampled to RATE as it loaded; its rate the recording's
		testing.expect_value(t, int(smp.frames), 2400)
		testing.expect_value(t, int(smp.rate), 44100)
		// still a 220 Hz sine: its zero crossings, a cycle's two
		values := device.sample_i16(&bank, smp)
		crossings := 0
		for i in 1 ..< len(values) {
			if (values[i - 1] < 0) != (values[i] < 0) {
				crossings += 1
			}
		}
		hz := f64(crossings) / 2 / (f64(len(values)) / device.RATE)
		testing.expectf(t, abs(hz - 220) < 15, "resampled, it plays %f Hz", hz)
	}
	// rr1 and rr2 of a note and layer: one group, places 0 and 1
	sequences := [2]int{}
	for z, i in bank.zones {
		testing.expect(t, z.sequence <= 1)
		sequences[z.sequence] += 1
		if z.sequence == 1 {
			g := bank.zones[z.group]
			testing.expect(t, int(z.group) < i && g.lo_key == z.lo_key && g.lo_velocity == z.lo_velocity && g.sequence == 0)
		}
		// the set's gain (its loudest sample at -6 dBFS) and level (where a
		// synth bass sits): -6 + 18.8 dB
		testing.expectf(t, abs(z.gain - f32(base.db_to_gain(-6 + 18.8))) < 0.01, "zone gain %f", z.gain)
	}
	testing.expect_value(t, sequences[0], sequences[1])
	// the sampler plays it
	set, found := device.bank_set_from_name(&bank, "karoryfer/growlybass")
	testing.expect(t, found)
	testing.expect(t, device.zone_for(&bank, int(set), 40, 100, 3) >= 0)
}

// Offline (no proxy answers): a set not on disk is declared (a song can
// compose against it) but its files can't be had, one finding for the set,
// not a crash; an unknown name is a finding too.
@(test)
test_bank_offline :: proc(t: ^testing.T) {
	root := temp_root("offline")
	defer os.remove_all(root)
	os.set_env("ODAWG_DATA", root)
	os.set_env("https_proxy", "http://127.0.0.1:9")
	os.set_env("HTTPS_PROXY", "http://127.0.0.1:9")
	findings := make(base.Findings, context.temp_allocator)
	bank: device.Bank
	defer device.bank_destroy(&bank)
	quiet :: proc(message: string) {}
	ok := bank_from_names(&bank, {"vcsl/upright_piano", "no/such_set"}, &findings, quiet)
	testing.expect(t, !ok)
	testing.expect_value(t, len(findings), 2)
	if len(findings) == 2 {
		testing.expect_value(t, findings[0].code, "unknown_asset")
		testing.expect_value(t, findings[1].code, "asset_unavailable")
	}
	testing.expect_value(t, len(bank.sets), 1)
	testing.expect_value(t, len(bank.samples), 0)
	credits := credits_from_names({"vcsl/upright_piano", "virtuosity/drums"}, context.temp_allocator)
	testing.expect_value(t, len(credits), 2)
	testing.expect(t, strings.contains(credits[0], "CC0-1.0"))
}

// A WAV straight to 16 bits is, value for value, the 16-bit value nearest
// its float: every format, two channels of three kept.
@(test)
test_wav_decode_i16 :: proc(t: ^testing.T) {
	specs := []Wav_Spec {
		{format = 1, bits = 16, channels = 1, rate = 44100},
		{format = 1, bits = 24, channels = 2, rate = 48000, loop = {100, 899}},
		{format = 1, bits = 32, channels = 2, rate = 96000},
		{format = 3, bits = 32, channels = 2, rate = 44100, extensible = true},
		{format = 3, bits = 64, channels = 1, rate = 44100},
		{format = 1, bits = 24, channels = 3, rate = 44100, extensible = true},
		{format = 1, bits = 8, channels = 1, rate = 22050},
	}
	for spec in specs {
		frames := 1000
		data := wav_write(spec, frames, 441)
		d, err := decode(data, context.temp_allocator)
		testing.expectf(t, err == nil, "%v: %v", spec, err)
		pcm, d16, err16 := decode_i16(data, 2, context.temp_allocator)
		testing.expectf(t, err16 == nil, "%v: %v", spec, err16)
		ch := min(spec.channels, 2)
		testing.expect_value(t, len(pcm), frames * ch)
		testing.expect(t, d16.loop_from == d.loop_from && d16.loop_to == d.loop_to && d16.rate == d.rate)
		differ := 0
		for f in 0 ..< frames {
			for c in 0 ..< ch {
				// half a step, and f32's own rounding of 32-bit integers
				x := f64(d.samples[f * spec.channels + c]) * 32768
				differ += abs(f64(pcm[f * ch + c]) - clamp(x, -32768, 32767)) > 0.5 + 1e-3 ? 1 : 0
			}
		}
		testing.expectf(t, differ == 0, "%v: %d values aren't the nearest 16-bit value", spec, differ)
	}
}
