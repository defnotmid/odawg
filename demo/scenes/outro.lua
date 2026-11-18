-- The dog and the wordmark over the song's spectrum, where to find it and
-- whose instruments played, fading with the song's last bar and a half.

local beat = require("beat")
local ui = require("ui")
local score = require("track")
local T = require("timeline")
local prog, snap, soft = beat.prog, beat.snap, beat.soft

-- the song fades over its last 1.5 s (video.lua): the picture with it
local FADE_FROM = score.beat(score.duration - 1.5) - T.OUTRO

local function render(f, lb)
  local b = T.OUTRO + lb
  local fade = 1 - prog(lb, FADE_FROM, T.TOTAL - T.OUTRO)
  ui.backdrop(f, b)
  group({ opacity = fade }, function()
    local bands = spectrum_centered(ui.spectrum(f, 48, score.name))
    for i, v in ipairs(bands) do
      local h = v * 200 + 6
      rect { x = ui.LEFT + (i - 1) * (ui.RIGHT - ui.LEFT) / 48 + 4, y = 960 - h, w = (ui.RIGHT - ui.LEFT) / 48 - 8,
        h = h, rx = 5, opacity = 0.55,
        fill = linear_gradient { x1 = 0, y1 = 0, x2 = 0, y2 = 1, units = "bbox", stops = { { 0, ui.C }, { 1, ui.A } } } }
    end
    ui.dog(f, 960 - 130, 130, 260, b)
    local s = 1 + 0.25 * (1 - soft(lb))
    group({ transform = { scale = s, origin = { 960, 520 } },
      shadow = { dx = 0, dy = 14, blur = 18, color = "#000000", opacity = 0.8 } }, function()
      text { "odawg", x = 960, y = 560, align = "center", font = ui.SANS, size = 170,
        fill = linear_gradient { x1 = 700, y1 = 0, x2 = 1220, y2 = 0, stops = { { 0, ui.A }, { 1, ui.C } } } }
    end)
    ui.rise(lb, 0.5, function()
      text { "github.com/defnotmid/odawg · MIT", x = 960, y = 640, align = "center", font = ui.MONO, size = 32,
        fill = ui.TEXT }
    end)
    ui.rise(lb, 1, function()
      text { "instruments: Karoryfer Samples, Versilian Studios (CC0)", x = 960, y = 700, align = "center",
        font = ui.MONO, size = 28, fill = ui.DIM }
      text { "this video: an onimite script; its song, onimite's disco", x = 960, y = 744, align = "center",
        font = ui.MONO, size = 28, fill = ui.DIM }
    end)
  end)
end

return { name = "Outro", title = "OUTRO", start = T.OUTRO, render = render }
