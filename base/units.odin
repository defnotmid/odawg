package odawg_base

import "core:math"

// The units odawg keeps its values in, a type each, so a value can't be
// taken for another unit without its conversion (a proc here). Inside, one
// unit a quantity: a level is a linear Gain. Authors and hosts write the
// unit natural to them (a level in dB); the reader, a command or the host
// converts once, at the boundary, and nothing converts per sample (a level
// moving evenly in dB is a Gain stepped by one factor a segment). The
// signal itself, and the per-sample gains that multiply it, stay f32.

// A level in decibels: what authors write (gain_db, a threshold).
Db :: distinct f64

// A linear gain: what multiplies a signal (1: as it is; 0: silence).
Gain :: distinct f64

db_to_gain :: proc "contextless" (db: Db) -> Gain {return Gain(math.pow(10, f64(db) / 20))}

gain_to_db :: proc "contextless" (g: Gain) -> Db {
	return g > 0 ? Db(20 * math.log10(f64(g))) : Db(-math.INF_F64)
}
