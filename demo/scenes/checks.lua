-- The mix, checked: each part's level in LU under the mix in every section
-- it plays (odawg inspect --balance), over its role's band (the check's
-- table) and, fainter, the slack the check allows before it tells; the
-- drop's reading large, each part's dot lighting on its notes.
-- The loudness the CLI measured is the line under it.

local beat = require("beat")
local ui = require("ui")
local score = require("track")
local T = require("timeline")
local facts = require("facts")
local prog, snap = beat.prog, beat.snap

local DROP = 5 -- facts.SECTIONS[5]
assert(facts.SECTIONS[DROP] == "drop")

local TOP, ROW_H = 250, 62
local AX0, AX1, MAX_LU = 560, 1500, 26
local function x_lu(lu) return AX0 + (AX1 - AX0) * lu / MAX_LU end

local function render(f, lb)
  ui.backdrop(f, T.CHECKS + lb)
  ui.label(lb, 11, "the mix, checked")
  -- the axis
  ui.rise(lb, 0, function()
    for _, lu in ipairs { 0, 8, 16, 24 } do
      rect { x = x_lu(lu), y = TOP - 16, w = 1, h = #facts.BALANCE * ROW_H + 10, fill = ui.LINE }
      text { tostring(lu), x = x_lu(lu), y = TOP - 26, align = "center", font = ui.MONO, size = 28, fill = ui.DIM }
    end
    text { "LU under the mix", x = ui.LEFT, y = TOP - 26, font = ui.MONO, size = 28, fill = ui.DIM }
    text { "drop", x = ui.RIGHT, y = TOP - 26, align = "right", font = ui.MONO, size = 28, fill = ui.TEXT }
  end)
  for i, row in ipairs(facts.BALANCE) do
    local at = 0.5 + (i - 1) * 0.125
    if lb >= at then
      local y = TOP + (i - 1) * ROW_H + ROW_H / 2
      local col = ui.ROLE[row.role]
      local band = facts.ROLE_BAND[row.role]
      local p = snap(lb - at)
      local hit = score.pulse(f, { part = row.part, decay = 8 })
      group({ opacity = prog(lb, at, at + 0.15) }, function()
        text { row.part, x = ui.LEFT, y = y + 10, font = ui.MONO, size = 28, fill = col }
        text { row.role, x = 360, y = y + 10, font = ui.MONO, size = 28, fill = ui.DIM }
        local lo, hi = math.max(band[1] - facts.ROLE_SLACK, 0), band[2] + facts.ROLE_SLACK
        rect { x = x_lu(lo), y = y - 18, w = math.max((x_lu(hi) - x_lu(lo)) * p, 1), h = 36, rx = 8, fill = col,
          opacity = 0.08 }
        rect { x = x_lu(band[1]), y = y - 18, w = math.max((x_lu(band[2]) - x_lu(band[1])) * p, 1), h = 36, rx = 8,
          fill = col, opacity = 0.18 }
        for s = 1, #facts.SECTIONS do
          local lu = row.lu[s]
          if lu and s ~= DROP then circle { cx = x_lu(lu), cy = y, r = 6, fill = col, opacity = 0.45 * p } end
        end
        local lu = row.lu[DROP]
        if lu then
          circle { cx = x_lu(lu), cy = y, r = (11 + 5 * hit) * p + 0.1, fill = col }
          text { string.format("%.1f", lu), x = ui.RIGHT, y = y + 10, align = "right", font = ui.MONO, size = 28,
            fill = ui.TEXT }
        else
          text { "·", x = ui.RIGHT, y = y + 10, align = "right", font = ui.MONO, size = 28, fill = ui.DIM }
        end
      end)
    end
  end
  ui.fact(lb, 5, string.format("%s · %s · each part within its role's band", facts.LUFS, facts.TRUE_PEAK),
    string.format("odawg analyze --master streaming · inspect --balance (±%d LU)", facts.ROLE_SLACK))
end

return { name = "Checks", title = "THE MIX, CHECKED", start = T.CHECKS, render = render }
