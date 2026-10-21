package odawg_assets

import "base:runtime"
import "core:bytes"
import "core:fmt"
import audio "deps:odecs/audio"

// Every file is decoded by odecs's audio (WAV, FLAC, Ogg Vorbis and Opus,
// MP3, MP4 and the rest), told apart by its contents, not its name.

// A file's first audio track as T, at most `keep` of its channels (0: all),
// with its loop: opened once, sized from its header, trimmed to the frames
// it holds.
@(private = "file")
decode_as :: proc(data: []u8, keep: int, $T: typeid, allocator: runtime.Allocator) -> (out: []T, d: Decoded, err: Error) {
	stream: bytes.Reader
	bytes.reader_init(&stream, data)
	r: audio.Reader
	if e := audio.open_stream(&r, bytes.reader_to_stream(&stream), keep); e != .None {
		return nil, d, fmt.tprintf("audio: %v", e)
	}
	defer audio.close(&r)
	if !r.present || r.samples > i64(audio.MAX_SAMPLES / r.kept) {
		return nil, d, "audio: no track it can decode"
	}
	d.channels, d.rate = r.kept, r.sample_rate
	if l, ok := r.loop.?; ok && l.end <= r.samples && l.end - l.start >= 2 {
		d.loop_from, d.loop_to = l.start, l.end
	}
	out = make([]T, int(r.samples) * r.kept, allocator)
	frames := 0
	for frames < int(r.samples) {
		n, e := audio.read(&r, out[frames * r.kept:])
		frames += n
		if e == .End_Of_Stream {
			break
		}
		if e != .None {
			delete(out, allocator)
			return nil, d, fmt.tprintf("audio: %v at frame %d", e, frames)
		}
	}
	return out[:frames * r.kept], d, nil
}

// A file as f32, every channel.
decode :: proc(data: []u8, allocator := context.allocator) -> (d: Decoded, err: Error) {
	samples: []f32
	samples, d, err = decode_as(data, 0, f32, allocator)
	d.samples = samples
	return
}

// A file's channels, rate and frames, from its header alone.
decode_info :: proc(data: []u8) -> (d: Decoded, err: Error) {
	info, e := audio.info(data)
	if e != .None || !info.present {
		return d, fmt.tprintf("audio: %v", e)
	}
	d.channels, d.rate = info.channels, info.sample_rate
	return
}

// A file as f32, at most `keep` of its channels (0: all), in the temp
// allocator: a step on the way to the bank.
decode_f32 :: proc(data: []u8, keep: int) -> (samples: []f32, d: Decoded, err: Error) {
	return decode_as(data, keep, f32, context.temp_allocator)
}

// A file straight to the bank's 16 bits, at most `keep` of its channels
// (interleaved), with no floats between for PCM and FLAC.
decode_i16 :: proc(data: []u8, keep: int, allocator := context.allocator) -> (pcm: []i16, d: Decoded, err: Error) {
	return decode_as(data, keep, i16, allocator)
}
