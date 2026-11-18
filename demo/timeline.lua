-- Where things happen, in beats from the start of the video (4 beats a
-- bar), read from the song (track.lua): the scenes cut on its bars, two or
-- four at a time, where its parts come in, so picture and sound share one
-- list.

local score = require("track")

local T = {}

-- The beat at a position in the song's grammar ("groove", "hook@4m").
local function at(pos) return score.beat(score.time(pos)) end
-- The song's hits of `note` on `part`, in beats from the start.
local function hits(part, note)
  local out = {}
  for i, t in ipairs(score.hits { part = part, note = note }) do out[i] = score.beat(t) end
  return out
end

T.TITLE = at("intro")         -- the kick alone, the loop shut behind its filter
T.DATA = at("intro@2m")
T.FORM = at("intro@4m")       -- the open hats come in
T.STEPS = at("groove")        -- the kit: hats and claps
T.BASS = at("groove@4m")
T.LANE = at("groove@6m")      -- the filter climbs to the hook
T.ROWS = at("hook")           -- the crash; the talk box sings
T.LAYERS = at("hook@4m")      -- its phrase again
T.PINS = at("break")          -- the kick drops out, the filter falls
T.NOTES = at("drop")          -- the crash; everything back, the arpeggio
T.CHECKS = at("drop@4m")
T.CLI = at("outro")
T.OUTRO = at("outro@2m")
T.TOTAL = score.beat(score.duration)

T.CRASHES = hits("drums", "crash") -- the hook's and the drop's downbeats: the flashes

return T
