-- Automation: the loop's one low-pass is the arrangement, a lane of points
-- over the whole song (the file's own), drawn as the engine plays it
-- (score.automation); these two bars are its climb into the hook, the
-- cutoff counting up as it opens.

local beat = require("beat")
local ui = require("ui")
local score = require("track")
local T = require("timeline")
local prog, snap = beat.prog, beat.snap

local PATH = "buses/loop/Filter/frequency"
local X0, X1, Y0, Y1 = ui.LEFT, ui.RIGHT, 330, 690
local LO, HI = math.log(200), math.log(20000)
local function x_at(t) return X0 + (X1 - X0) * t / score.duration end
local function y_at(hz) return Y1 - (math.log(hz) - LO) / (HI - LO) * (Y1 - Y0) end

local CURVE = {}
for i = 0, 480 do
  local t = score.duration * i / 480
  CURVE[#CURVE + 1] = { x_at(t), y_at(score.automation(PATH, t)) }
end
-- the file's points
local POINTS = {}
for _, p in ipairs(score.spec.automation[PATH]) do
  POINTS[#POINTS + 1] = { x_at(score.time(p[1])), y_at(p[2]), p[1], p[2] }
end
local CODE = string.format('"%s": [ [ "%s", %d ], [ "%s", %d ], …', PATH, POINTS[1][3], POINTS[1][4], POINTS[2][3],
  POINTS[2][4])

local function render(f, lb)
  ui.backdrop(f, T.LANE + lb)
  ui.label(lb, 6, "automation: a lane on any value")
  ui.rise(lb, 0, function()
    text { CODE, x = ui.LEFT, y = 250, font = ui.MONO, size = 28, fill = ui.DIM }
  end)
  -- the grid: the sections and two levels
  for _, s in ipairs(score.sections) do
    rect { x = x_at(s.start), y = Y0, w = 2, h = Y1 - Y0, fill = ui.LINE }
    text { s.name, x = x_at(s.start) + 12, y = Y1 + 40, font = ui.MONO, size = 28, fill = ui.DIM }
  end
  for _, hz in ipairs { 300, 3000 } do
    rect { x = X0, y = y_at(hz), w = X1 - X0, h = 1, fill = ui.LINE }
    text { ui.hz(hz), x = X0 + 10, y = y_at(hz) - 12, font = ui.MONO, size = 28, fill = ui.DIM }
  end
  local draw = prog(lb, ui.at(0), 1.5)
  polyline { points = CURVE, stroke = ui.D, stroke_width = 5, fill = "none", line_join = "round", line_cap = "round",
    path_length = 1, stroke_dasharray = { 1, 1 }, stroke_dashoffset = 1 - beat.expo_out(draw) }
  for i, p in ipairs(POINTS) do
    local at = 0.3 + i * 0.08
    if lb >= at then circle { cx = p[1], cy = p[2], r = 9 * snap(lb - at) + 0.1, fill = ui.BG, stroke = ui.D, stroke_width = 3 } end
  end
  -- the playhead and the value
  local t = f.global_seconds
  local hz = score.automation(PATH, f)
  rect { x = x_at(t) - 1, y = Y0 - 10, w = 3, h = Y1 - Y0 + 20, fill = ui.TEXT }
  circle { cx = x_at(t), cy = y_at(hz), r = 14 + 4 * ui.kick(f), fill = ui.D }
  ui.rise(lb, 1, function()
    text { ui.hz(hz), x = ui.RIGHT, y = 250, align = "right", font = ui.SANS, size = 96, fill = ui.TEXT }
  end)
  ui.fact(lb, 2, "the picture reads the lane the engine plays", "score.automation(path, f): the backdrop, the lane below")
end

return { name = "Lane", title = "AUTOMATION", start = T.LANE, render = render }
