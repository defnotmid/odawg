package odawg_base

import "core:math"

// The units odawg keeps its values in, a type each, so a value can't be
// taken for another unit without its conversion (a proc here). Inside, one
// unit a quantity: a level is a linear Gain; a time is Seconds in the Song
// and frames at RATE (i64: a type of its own already) in the engine; a
// pitch is a Pitch (a MIDI number) until a voice turns it into Hz. Authors and hosts write the unit natural to
// them (a level in dB); the reader, a command or the host converts once, at
// the boundary, and nothing converts per sample (a level moving evenly in
// dB is a Gain stepped by one factor a segment). The signal itself, and the
// per-sample gains that multiply it, stay f32.

// A level in decibels: what authors write (gain_db, a threshold).
Db :: distinct f64

// A linear gain: what multiplies a signal (1: as it is; 0: silence).
Gain :: distinct f64

db_to_gain :: proc "contextless" (db: Db) -> Gain {return Gain(math.pow(10, f64(db) / 20))}

gain_to_db :: proc "contextless" (g: Gain) -> Db {
	return g > 0 ? Db(20 * math.log10(f64(g))) : Db(-math.INF_F64)
}

// A time in seconds: a length (a fade, a duck's attack) or a time on a clock
// (a note's start, a section's): what authors, hosts and the Song write.
Seconds :: distinct f64

// The frame at RATE nearest a time: the engine counts frames (a song
// sample, a lane's point) as i64, a type an f64 time can't pass for.
samples_from_seconds :: proc "contextless" (t: Seconds) -> i64 {return i64(math.round(f64(t) * RATE))}

seconds_from_samples :: proc "contextless" (n: i64) -> Seconds {return Seconds(f64(n) / RATE)}

// A pitch as a MIDI note number: 60 is C4, a fraction between semitones (an
// f32, as the note table holds it): what theory reads and writes, the
// note table and a voice's note.
Pitch :: distinct f32

// A frequency in Hz.
Hz :: distinct f64

// The frequency of a pitch (69, A4, at 440 Hz).
midi_to_hz :: proc "contextless" (n: Pitch) -> Hz {return Hz(440 * math.pow(2, (f64(n) - 69) / 12))}
