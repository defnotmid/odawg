-- The form: the file's six section lines, one a beat, each drawing its
-- block of bars under them (the song's own sections, as odawg composed
-- them), then how many notes the parts make of it.

local beat = require("beat")
local ui = require("ui")
local score = require("track")
local T = require("timeline")
local facts = require("facts")
local prog, snap = beat.prog, beat.snap

-- the lines of "sections": [ ... ] in the file
local LINES = {}
do
  local inside = false
  for _, line in ipairs(score.lines) do
    if line:match('^  "sections": %[') then inside = true
    elseif inside and line:match("^  %]") then break
    elseif inside then LINES[#LINES + 1] = (line:gsub("^%s+", ""):gsub(",%s*$", "")) end
  end
end

local BAR_W = (ui.RIGHT - ui.LEFT) / facts.BARS

local function render(f, lb)
  ui.backdrop(f, T.FORM + lb)
  ui.label(lb, 3, "the form: sections in bars")
  local bar = 0
  for i, s in ipairs(score.sections) do
    local at = ui.at((i - 1) * 0.5)
    if lb >= at then
      local p = snap(lb - at)
      group({ opacity = prog(lb, at, at + 0.15), transform = translate((1 - p) * 30, 0) }, function()
        text { LINES[i], x = ui.LEFT, y = 236 + i * 50, font = ui.MONO, size = 28, fill = ui.TEXT }
      end)
      local x, w = ui.LEFT + bar * BAR_W, s.bars * BAR_W
      local playing = score.section(f).index == i
      group({ opacity = prog(lb, at, at + 0.15), transform = { scale = 0.9 + 0.1 * p, origin = { x, 640 } } },
        function()
          rect { x = x + 4, y = 600, w = w - 8, h = 110, rx = 14, fill = playing and ui.LINE or ui.PANEL,
            stroke = playing and ui.C or ui.LINE, stroke_width = 2 }
          text { s.name, x = x + 22, y = 648, font = ui.SANS, size = 34, fill = ui.TEXT }
          text { string.format("%d bars", s.bars), x = x + 22, y = 690, font = ui.MONO, size = 28, fill = ui.DIM }
        end)
    end
    bar = bar + s.bars
  end
  ui.fact(lb, 6, string.format("%d bars → %s notes on %d parts", facts.BARS, ui.thousands(facts.NOTES), facts.PARTS),
    "odawg timeline demo/media/song.json")
end

return { name = "Form", title = "THE FORM", start = T.FORM, render = render }
