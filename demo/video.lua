-- odawg in 76 seconds: an onimite script (Odin + Lua video framework,
-- https://github.com/defnotmid/onimite, which plays its songs with odawg)
-- showing the sound library over onimite's disco example, the song as it is
-- (track.lua: French touch in B-flat minor at 126). Every cut sits on the
-- song's bars and every pop on its notes (beat.lua, timeline.lua): the
-- picture pumps on the 909's kick, flashes on its crashes, and the lane
-- along the bottom is the loop's filter, read from the automation the
-- engine plays. Numbers on screen come from the song, its pins and odawg's
-- CLI (facts.lua).
--
--     onimite render demo/video.lua -o demo/demo.mp4 --qp 22

local beat = require("beat")
local ui = require("ui")
local score = require("track")
local T = require("timeline")

local SCENES = {
  require("scenes.title"),
  require("scenes.data"),
  require("scenes.form"),
  require("scenes.steps"),
  require("scenes.bass"),
  require("scenes.lane"),
  require("scenes.rows"),
  require("scenes.layers"),
  require("scenes.pins"),
  require("scenes.notes"),
  require("scenes.checks"),
  require("scenes.cli"),
  (require("scenes.outro")), -- parenthesized: require also returns the file name
}

-- Cuts that glitch for three frames: every one but the first.
local GLITCH_CUTS = {}
for i = 2, #SCENES do GLITCH_CUTS[#GLITCH_CUTS + 1] = SCENES[i].start end
cue("crash", score.hits { part = "drums", note = "crash" }, { hit = score.name })

local KICK = { part = "drums", note = "kick", decay = 9 }
local CRASH = { part = "drums", note = "crash", decay = 5 }

local function energy(f, b)
  local s = 1 + score.pulse(f, KICK) * 0.008
  local since_cut
  for _, c in ipairs(GLITCH_CUTS) do
    local fr = f.global_index - beat.beat_frame(c)
    if fr >= 0 and fr < 3 then since_cut = fr end
  end
  group({ transform = { scale = s, origin = { 960, 540 } } }, function()
    if since_cut then
      -- the picture splits in bands pushed sideways
      for i = 0, 5 do
        local dx = (beat.hash(i * 13 + since_cut * 7 + b) - 0.5) * 160 * (1 - since_cut / 3)
        group({ transform = translate(dx, 0), clip = { x = 0, y = i * 180, w = 1920, h = 180 } }, function()
          render_scenes(f)
        end)
      end
    else
      render_scenes(f)
    end
  end)
  local flash = score.pulse(f, CRASH)
  if flash > 0.01 then rect { x = 0, y = 0, w = 1920, h = 1080, fill = ui.TEXT, opacity = flash * 0.5 } end
end

-- ---- the lane: the loop's filter over the whole song --------------------------

local LANE_PATH = "buses/loop/Filter/frequency"
local LANE = { x = 60, y = 990, w = 1800, h = 40 }
local LO, HI = math.log(200), math.log(20000)
local function lane_y(hz) return LANE.y + LANE.h - (math.log(hz) - LO) / (HI - LO) * LANE.h end
local LANE_POINTS = {}
do
  local n = 360
  for i = 0, n do
    local t = score.duration * i / n
    LANE_POINTS[#LANE_POINTS + 1] = { LANE.x + LANE.w * i / n, lane_y(score.automation(LANE_PATH, t)) }
  end
end

local function lane(f, b)
  local t = f.global_seconds
  local x = LANE.x + LANE.w * math.min(t / score.duration, 1)
  for _, s in ipairs(score.sections) do
    local x0 = LANE.x + LANE.w * s.start / score.duration
    local x1 = LANE.x + LANE.w * s.stop / score.duration
    local on = t >= s.start and t < s.stop
    rect { x = x0 + 2, y = LANE.y, w = x1 - x0 - 4, h = LANE.h, rx = 6, fill = on and ui.LINE or ui.PANEL }
    text { string.upper(s.name), x = x0 + 12, y = LANE.y + 16, font = ui.MONO, size = 13,
      fill = on and ui.TEXT or ui.DIM }
  end
  -- the curve, bright up to the playhead
  polyline { points = LANE_POINTS, stroke = ui.DIM, stroke_width = 2, stroke_opacity = 0.5, fill = "none" }
  group({ clip = { x = LANE.x, y = LANE.y - 4, w = math.max(x - LANE.x, 1), h = LANE.h + 8 } }, function()
    polyline { points = LANE_POINTS, stroke = ui.D, stroke_width = 3, fill = "none", line_join = "round" }
  end)
  local hz = score.automation(LANE_PATH, f)
  rect { x = x - 1, y = LANE.y - 6, w = 2, h = LANE.h + 12, fill = ui.TEXT }
  circle { cx = x, cy = lane_y(hz), r = 5 + 3 * beat.pulse(b, 7), fill = ui.D }
  text { string.format("%s  %s", LANE_PATH, ui.hz(hz)), x = 60, y = 1064, font = ui.MONO, size = 16, fill = ui.DIM }
end

local function hud(f)
  -- a frame stands for its 60th of a second: the beat at its middle, so a
  -- scene's first frame (rounded to the frame nearest its downbeat) reads
  -- as its own bar
  local b = score.beat((f.global_index + 0.5) / beat.FPS)
  local bar, q = math.floor(b / 4) + 1, math.floor(b % 4) + 1
  local section = 1
  for i, s in ipairs(SCENES) do if f.global_index >= beat.beat_frame(s.start) then section = i end end
  local sec = score.sections[score.section(f).index]
  group({ opacity = 0.85 }, function()
    text { "ODAWG · SOUND FOR ODIN", x = 60, y = 66, font = ui.MONO, size = 16, fill = ui.DIM }
    text { string.format("%s · %d BPM   BAR %02d.%d", score.key, sec.bpm, bar, q), x = 1830, y = 66,
      align = "right", font = ui.MONO, size = 16, fill = ui.DIM }
    rect { x = 1844, y = 53, w = 14, h = 14, fill = ui.A, opacity = 0.2 + 0.8 * score.pulse(f, KICK) }
    text { string.format("%02d / %s", section, SCENES[section].title), x = 1860, y = 1064, align = "right",
      font = ui.MONO, size = 16, fill = ui.DIM }
    lane(f, beat.gbeat(f))
  end)
end

video {
  width = 1920, height = 1080, fps = beat.FPS, duration = score.duration, background = ui.BG,
  -- as examples/disco plays it: the song mixes near -24 LUFS, lifted under
  -- the limiter (audio analyze in README.md), its last bar and a half faded
  audio = { { score, fade_out = 1.5 } },
  master_gain_db = 6,
  render = function(f)
    local b = beat.gbeat(f)
    rect { x = 0, y = 0, w = 1920, h = 1080, fill = ui.BG }
    energy(f, b)
    hud(f)
  end,
}

for i, s in ipairs(SCENES) do
  local start, stop, render = s.start, (SCENES[i + 1] or { start = T.TOTAL }).start, s.render
  scene { s.name, duration = { frames = beat.beat_frame(stop) - beat.beat_frame(start) }, render = function(f)
    render(f, beat.gbeat(f) - start)
  end }
end
