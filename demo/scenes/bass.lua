-- Notes are strings too: the bass line as the file writes it, a token a
-- sixteenth across the frame, over the notes odawg composed from it
-- (score.events), each lighting as it plays. Two bars: the line once.

local beat = require("beat")
local ui = require("ui")
local score = require("track")
local T = require("timeline")
local prog, snap = beat.prog, beat.snap

local ENTRY
for _, e in ipairs(score.spec.parts.bass.play) do
  if e.range == "intro..groove" then ENTRY = e end
end
local TOKENS = {}
for tok in ENTRY.notes:gmatch("%S+") do
  if tok ~= "|" then TOKENS[#TOKENS + 1] = tok end
end

local CELL = (ui.RIGHT - ui.LEFT) / #TOKENS

-- the notes in these two bars: sixteenth, length in sixteenths, pitch
local NOTES, LO, HI = {}, math.huge, -math.huge
for _, e in ipairs(score.events { part = "bass", range = "groove@4m..groove@6m" }) do
  local at = (score.beat(e.time) - T.BASS) * 4
  local len = (score.beat(e.time + e.duration) - score.beat(e.time)) * 4
  local m = ui.midi(e.note)
  NOTES[#NOTES + 1] = { at = at, len = len, midi = m, name = e.note }
  LO, HI = math.min(LO, m), math.max(HI, m)
end

local ROLL_Y, ROLL_H = 420, 300

local function render(f, lb)
  ui.backdrop(f, T.BASS + lb)
  ui.label(lb, 5, "notes are strings too")
  local now = lb * 4
  ui.rise(lb, 0, function()
    text { string.format('"subdivision": "%s",  "notes":', ENTRY.subdivision), x = ui.LEFT, y = 250, font = ui.MONO,
      size = 28, fill = ui.DIM }
  end)
  for i, tok in ipairs(TOKENS) do
    local at = ui.at((i - 1) / 16) -- the tokens type in over the first two beats
    if lb >= at then
      local x = ui.LEFT + (i - 1) * CELL + CELL / 2
      local here = math.floor(now) == i - 1
      text { tok, x = x, y = 330, align = "center", font = ui.MONO, size = 28,
        fill = here and ui.B or (tok == "." or tok == "-") and ui.DIM or ui.TEXT }
    end
  end
  rect { x = ui.LEFT + 16 * CELL - 1, y = 290, w = 2, h = ROLL_Y + ROLL_H - 290, fill = ui.LINE }
  -- the roll
  for _, n in ipairs(NOTES) do
    local appear = n.at / 16
    if lb >= appear then
      local x = ui.LEFT + n.at * CELL + 3
      local y = ROLL_Y + ROLL_H - (n.midi - LO) / math.max(HI - LO, 1) * (ROLL_H - 24) - 24
      local sounding = now >= n.at and now < n.at + n.len
      local p = snap(lb - appear)
      group({ opacity = prog(lb, appear, appear + 0.1), transform = { scale = 0.9 + 0.1 * p, origin = { x, y } } },
        function()
          rect { x = x, y = y, w = math.max(n.len * CELL - 6, 6), h = 22, rx = 6, fill = ui.B,
            opacity = sounding and 1 or 0.45 }
          if sounding then
            text { ui.flat(n.name), x = x, y = y - 12, font = ui.MONO, size = 28, fill = ui.TEXT }
          end
        end)
    end
  end
  local px = ui.LEFT + now * CELL
  rect { x = px - 1, y = 290, w = 2, h = ROLL_Y + ROLL_H - 290, fill = ui.TEXT, opacity = 0.6 }
  ui.fact(lb, 2, "a note name, - holds it, . rests, | a bar", "parts/bass: a sixteenth a token")
end

return { name = "Bass", title = "NOTES", start = T.BASS, render = render }
