-- The soundtrack: onimite's disco example, the song as it is. media/song.json
-- is examples/disco/media/song.json byte for byte but for the two paths to
-- the library rows it names (effects.json and synths.json, copied into
-- media/instruments/ from onimite's skill library, as machines/909.json and
-- the pins are from the example), so it travels alone and odawg's CLI
-- renders the same file: `build/odawg render demo/media/song.json`.
--
-- French touch, hard and electronic, B-flat minor at 126: one loop (a
-- driven synth bass with a fingered bass in it, funk guitar, saw-and-piano
-- stabs, a string pad) through a grain of distortion and one low-pass whose
-- cutoff is the arrangement, a talk-box lead, the violins and an arpeggio
-- over it, everything ducking under the 909 kick. Intro, groove, hook,
-- break, drop, outro: 40 bars. The libraries are CC0, fetched from where
-- their authors publish them, pinned by SHA-256, and only the samples the
-- notes reach.
--
-- The video reads it back for every cut and pop (timeline.lua), and its
-- scenes read the same table the song was made from (M.spec).

local file = assert(io.open(SCRIPT_DIR .. "/media/song.json"))
local text = file:read("a")
file:close()

local spec = json_decode(text)
local score = song(json_decode(text))

-- The decoded spec, for the scenes that show the song as data: its steps,
-- its rows, its sources.
score.spec = spec
-- The file's own lines, for the scene that shows it.
score.lines = {}
for line in (text .. "\n"):gmatch("(.-)\r?\n") do score.lines[#score.lines + 1] = line end

return score
