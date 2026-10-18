package odawg_assets

import "base:runtime"
import "core:fmt"
import flac "deps:odecs/codec/flac"
import wav "deps:odecs/codec/container/wav"

// The decoders are odecs's: WAV (deps:odecs/codec/container/wav) and FLAC
// (deps:odecs/codec/flac), each read as f32 or straight to i16.

// ---- WAV ---------------------------------------------------------------------------

// Opens a WAV held in memory: its channels, rate and first smpl loop.
@(private = "file")
wav_open :: proc(r: ^wav.Reader, data: []u8, d: ^Decoded) -> Error {
	if e := wav.open_bytes(r, data); e != .None {
		return fmt.tprintf("wav: %v", e)
	}
	d.channels, d.rate = r.format.channels, r.format.sample_rate
	if l, ok := r.loop.?; ok && l.end < r.frames && l.end + 1 - l.start >= 2 {
		d.loop_from, d.loop_to = l.start, l.end + 1 // its end is inclusive
	}
	return nil
}

// Its frames as T, at most `keep` channels of each (0: all).
@(private = "file")
wav_read :: proc(data: []u8, keep: int, $T: typeid, allocator: runtime.Allocator) -> (out: []T, d: Decoded, err: Error) {
	r: wav.Reader
	wav_open(&r, data, &d) or_return
	defer wav.close(&r)
	ch := keep > 0 ? min(keep, d.channels) : d.channels
	out = make([]T, int(r.frames) * ch, allocator)
	if r.frames > 0 {
		if _, e := wav.read(&r, 0, out, ch); e != .None {
			return nil, d, fmt.tprintf("wav: %v", e)
		}
	}
	return out, d, nil
}

wav_decode :: proc(data: []u8, allocator := context.allocator) -> (d: Decoded, err: Error) {
	samples: []f32
	samples, d, err = wav_read(data, 0, f32, allocator)
	d.samples = samples
	return
}

wav_decode_i16 :: proc(data: []u8, keep: int, allocator := context.allocator) -> (pcm: []i16, d: Decoded, err: Error) {
	return wav_read(data, keep, i16, allocator)
}

wav_info :: proc(data: []u8) -> (frames, channels, rate: int, ok: bool) {
	r: wav.Reader
	if wav.open_bytes(&r, data) != .None {
		return
	}
	defer wav.close(&r)
	return int(r.frames), r.format.channels, r.format.sample_rate, true
}

// ---- FLAC --------------------------------------------------------------------------

// The stream info, then every frame decoded and interleaved as T, at most
// `keep` channels of each (0: all).
@(private = "file")
flac_read :: proc(data: []u8, keep: int, $T: typeid, allocator: runtime.Allocator) -> (out: []T, d: Decoded, err: Error) {
	info, audio, merr := flac.parse_metadata(data)
	if merr != .None {
		return nil, d, fmt.tprintf("flac: %v", merr)
	}
	d.rate, d.channels = info.sample_rate, info.channels
	ch := keep > 0 ? min(keep, d.channels) : d.channels
	all := make([dynamic]T, 0, int(info.total_samples) * ch, allocator)
	dec: flac.Decoder
	flac.init_decoder(&dec, info)
	defer flac.destroy_decoder(&dec)
	for at := audio; at < len(data); {
		f, used, ferr := flac.decode_frame(&dec, data[at:])
		if ferr != .None {
			delete(all)
			return nil, d, fmt.tprintf("flac: frame at byte %d: %v", at, ferr)
		}
		start := len(all)
		resize(&all, start + f.header.block_size * min(ch, f.header.channels))
		flac.interleave(f, all[start:], ch)
		at += used
	}
	return all[:], d, nil
}

flac_decode :: proc(data: []u8, allocator := context.allocator) -> (d: Decoded, err: Error) {
	samples: []f32
	samples, d, err = flac_read(data, 0, f32, allocator)
	d.samples = samples
	return
}

flac_decode_i16 :: proc(data: []u8, keep: int, allocator := context.allocator) -> (pcm: []i16, d: Decoded, err: Error) {
	return flac_read(data, keep, i16, allocator)
}

flac_info :: proc(data: []u8) -> (frames, channels, rate: int, ok: bool) {
	info, _, err := flac.parse_metadata(data)
	if err != .None {
		return
	}
	return int(info.total_samples), info.channels, info.sample_rate, true
}
