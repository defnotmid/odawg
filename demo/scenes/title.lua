-- The dog at its drum machine, its red pad lighting on every kick (the
-- 909's kick plays alone, the loop shut behind its filter), then the
-- wordmark slams in on the second beat and the line under it on the third.

local beat = require("beat")
local ui = require("ui")
local T = require("timeline")
local prog, snap, soft, pulse = beat.prog, beat.snap, beat.soft, beat.pulse

local SLAM, LINE, CHIP = 1, 2, 3

local function render(f, lb)
  local b = T.TITLE + lb
  ui.backdrop(f, b)

  local enter = 0.92 + 0.08 * snap(lb)
  group({ transform = { scale = enter, origin = { 960, 330 } } }, function()
    ui.dog(f, 960 - 170, 150, 340, b)
  end)

  if lb >= SLAM then
    local s = 1 + 0.3 * (1 - soft(lb - SLAM))
    group({ opacity = prog(lb, SLAM, SLAM + 0.15), transform = { scale = s, origin = { 960, 640 } },
      shadow = { dx = 0, dy = 14, blur = 18, color = "#000000", opacity = 0.7 } }, function()
      text { "ODAWG", x = 960, y = 700, align = "center", font = ui.DISPLAY, size = 240, letter_spacing = 4,
        fill = linear_gradient { x1 = 700, y1 = 0, x2 = 1220, y2 = 0,
          stops = { { 0, ui.A }, { 0.5, ui.B }, { 1, ui.C } } } }
    end)
  end
  ui.rise(lb, LINE, function()
    text { "sound for Odin", x = 960, y = 780, align = "center", font = ui.SANS, size = 52, fill = ui.TEXT }
  end)
  if lb >= CHIP then
    local label = "songs as data, in Tone.js's vocabulary"
    local w = text_width { label, font = ui.MONO, size = 28 } + 28 * 1.4
    ui.chip(960 - w / 2, 822, label, ui.LINE, ui.C, 28, snap(lb - CHIP))
  end
end

return { name = "Title", title = "SOUND FOR ODIN", start = T.TITLE, render = render }
