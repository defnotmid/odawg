-- Patterns are strings: the groove's 909 row as the file writes it, each
-- string beside the sixteen steps it makes, the playhead walking them and
-- each cell flashing when the song plays that note (score.events: what the
-- engine plays, swing and humanize included). The clap's list is a bar
-- each.

local beat = require("beat")
local ui = require("ui")
local score = require("track")
local T = require("timeline")
local facts = require("facts")
local prog, snap = beat.prog, beat.snap

local ROWS = { "kick", "hat", "open_hat", "clap" }
local COLOUR = { kick = ui.A, clap = ui.B, open_hat = ui.C, hat = ui.TEXT }

-- the drums' entry for the groove, from the spec
local ENTRY
for _, e in ipairs(score.spec.parts.drums.play) do
  if e.range == "groove" then ENTRY = e end
end
local function steps(row, bar)
  local s = ENTRY.steps[row]
  if type(s) == "table" then return s[(bar % #s) + 1] end
  return s
end

-- when each row's notes play in the groove, in beats
local HITS = {}
for _, row in ipairs(ROWS) do HITS[row] = {} end
for _, e in ipairs(score.events { part = "drums", range = "groove" }) do
  if HITS[e.note] then table.insert(HITS[e.note], score.beat(e.time)) end
end
local function since(row, b)
  local last
  for _, h in ipairs(HITS[row]) do
    if h <= b then last = h else break end
  end
  return last and b - last or math.huge
end

local GRID_X, CELL, GAP, ROW_Y, ROW_H = 640, 62, 6, 260, 104

local function render(f, lb)
  local b = T.STEPS + lb
  ui.backdrop(f, b)
  ui.label(lb, 4, "patterns are strings")
  local bar = math.floor(lb / 4)
  local step = math.floor((lb % 4) * 4)
  for i, row in ipairs(ROWS) do
    local at = ui.at((i - 1) * 0.25)
    if lb >= at then
      local y = ROW_Y + (i - 1) * ROW_H
      local str = steps(row, bar)
      local flash = math.exp(-since(row, b) * 6)
      group({ opacity = prog(lb, at, at + 0.15), transform = translate((1 - snap(lb - at)) * 40, 0) }, function()
        text { row, x = ui.LEFT, y = y + 42, font = ui.MONO, size = 28, fill = COLOUR[row] }
        text { '"' .. str .. '"', x = 318, y = y + 42, font = ui.MONO, size = 28, fill = ui.DIM }
        for k = 1, 16 do
          local c = str:sub(k, k)
          local x = GRID_X + (k - 1) * (CELL + GAP) + math.floor((k - 1) / 4) * 8
          local here = k - 1 == step
          local on = c == "x" or c == "X"
          local ghost = c == "o"
          local fill = (on or ghost) and COLOUR[row] or ui.PANEL
          local op = on and (c == "X" and 1 or 0.8) or ghost and 0.45 or 1
          if here and (on or ghost) then op = math.min(1, op + flash * 0.6) end
          rect { x = x, y = y, w = CELL, h = CELL, rx = 10, fill = fill, opacity = op,
            stroke = here and ui.TEXT or ui.LINE, stroke_width = here and 3 or 2 }
          if c == "X" then rect { x = x + 21, y = y + 21, w = 20, h = 20, rx = 4, fill = ui.BG, opacity = 0.6 } end
        end
      end)
    end
  end
  -- the string's alphabet
  ui.rise(lb, 2, function()
    local x = ui.LEFT
    for _, c in ipairs { { "x", "a hit" }, { "X", "an accent" }, { "o", "a ghost" }, { ".", "a rest" } } do
      text { x = x, y = 720, font = ui.MONO, size = 28, spans = { { c[1] .. " ", fill = ui.C }, { c[2], fill = ui.DIM } } }
      x = x + text_width { c[1] .. " " .. c[2], font = ui.MONO, size = 28 } + 48
    end
    text { string.format("swing %.2f · humanize %.0f ms", score.spec.swing, ENTRY.humanize * 1000), x = ui.RIGHT, y = 720,
      align = "right", font = ui.MONO, size = 28, fill = ui.DIM }
  end)
  ui.fact(lb, 6, string.format("the 909 plays %s notes from strings like these", ui.thousands(facts.PART_NOTES.drums)),
    "odawg timeline · parts/drums")
end

return { name = "Steps", title = "PATTERNS", start = T.STEPS, render = render }
