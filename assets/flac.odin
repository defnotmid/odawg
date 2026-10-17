package odawg_assets

import "core:fmt"
import flac "deps:odecs/codec/flac"

// FLAC through odecs's native decoder (deps:odecs/codec/flac): the stream
// info, then every frame decoded and interleaved as f32.
flac_decode :: proc(data: []u8, allocator := context.allocator) -> (d: Decoded, err: Error) {
	info, audio, merr := flac.parse_metadata(data)
	if merr != .None {
		return d, fmt.tprintf("flac: %v", merr)
	}
	d.rate, d.channels = info.sample_rate, info.channels
	out := make([dynamic]f32, 0, int(info.total_samples) * info.channels, allocator)
	dec: flac.Decoder
	flac.init_decoder(&dec, info)
	defer flac.destroy_decoder(&dec)
	block := make([]f32, flac.MAX_BLOCK * info.channels, context.temp_allocator)
	for at := audio; at < len(data); {
		f, used, ferr := flac.decode_frame(&dec, data[at:])
		if ferr != .None {
			return d, fmt.tprintf("flac: frame at byte %d: %v", at, ferr)
		}
		n := f.header.block_size * f.header.channels
		flac.interleave_f32(f, block[:n])
		append(&out, ..block[:n])
		at += used
	}
	d.samples = out[:]
	return d, nil
}

flac_info :: proc(data: []u8) -> (frames, channels, rate: int, ok: bool) {
	info, _, err := flac.parse_metadata(data)
	if err != .None {
		return
	}
	return int(info.total_samples), info.channels, info.sample_rate, true
}
