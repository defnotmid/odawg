-- Palette, type, layout and the small parts the scenes share.

local beat = require("beat")
local score = require("track")

local M = {}

-- The dog's colours (art/logo.svg): its pads red, orange, yellow and white,
-- its notes teal, on the night of the club.
M.BG, M.PANEL, M.LINE = "#0d0a14", "#181320", "#2e2740"
M.TEXT, M.DIM = "#fdf4ec", "#a89cbc"
M.A, M.B, M.C, M.D = "#ff5a44", "#ffa14a", "#ffe36a", "#5eead4" -- red, orange, yellow, teal
M.E = "#c4a7ff"                                                   -- violet

M.DISPLAY, M.SANS, M.MONO = "Bebas Neue", "Space Grotesk", "JetBrains Mono"

-- Content stays inside the safe margins (8% of the width each side).
M.LEFT, M.RIGHT = 160, 1760

-- A part's colour by its role.
M.ROLE = { drums = M.A, bass = M.B, comp = M.C, pad = M.E, melody = M.D, counter = "#ff8fc7", texture = M.DIM }

-- A filled label, popping from its left edge.
function M.chip(x, y, label, fill, ink, size, pop)
  size = size or 28
  local w = text_width { label, font = M.MONO, size = size } + size * 1.4
  local h = size * 1.8
  group({ transform = { scale = pop or 1, origin = { x, y + h / 2 } } }, function()
    rect { x = x, y = y, w = w, h = h, rx = h / 2, fill = fill }
    text { label, x = x + size * 0.7, y = y + h / 2, baseline = "middle", font = M.MONO, size = size, fill = ink or M.BG }
  end)
  return w
end

-- The scene's label top left: "02 · a song is data", popping on its first beat.
-- Anything entering on a scene's first beat starts this many beats early,
-- so the cut's first frame already shows it coming in.
M.LEAD = 0.25
function M.at(at) return at <= 0 and -M.LEAD or at end

function M.label(lb, n, s)
  M.chip(M.LEFT, 118, string.format("%02d · %s", n, s), M.LINE, M.TEXT, 28, beat.snap(lb + M.LEAD))
end

-- A fact line low in the frame: what, and where the number comes from.
function M.fact(lb, at, s, source)
  if lb < at then return end
  local p = beat.snap(lb - at)
  group({ opacity = beat.prog(lb, at, at + 0.2), transform = translate(0, (1 - p) * 30) }, function()
    text { s, x = M.LEFT, y = 876, font = M.SANS, size = 40, fill = M.TEXT }
    text { source, x = M.LEFT, y = 918, font = M.MONO, size = 28, fill = M.DIM }
  end)
end

-- Something entering on a beat: rises 40 px and fades in over a fifth of a beat.
function M.rise(lb, at, fn)
  at = M.at(at)
  if lb < at then return end
  local p = beat.snap(lb - at)
  group({ opacity = beat.prog(lb, at, at + 0.2), transform = translate(0, (1 - p) * 40) }, fn)
end

-- A panel with a group box, so inspect catches what spills out of it.
function M.panel(x, y, w, h, name, fn, fill)
  group({ box = { x = x, y = y, w = w, h = h, name = name } }, function()
    rect { x = x, y = y, w = w, h = h, rx = 18, fill = fill or M.PANEL, stroke = M.LINE, stroke_width = 2 }
    if fn then fn() end
  end)
end

-- The soundtrack's spectrum at the frame as `n` levels from 0 to 1.
function M.spectrum(f, n, src)
  return audio_spectrum(f, { src = src, sample_size = 1024, smooth = 1, window = "hann", bands = n, log = true,
    levels = { -20, 26 } }) or {}
end

-- A note name ("Bb1", "F#4") as its MIDI number; nil for a pad's name.
local STEP = { C = 0, D = 2, E = 4, F = 5, G = 7, A = 9, B = 11 }
function M.midi(name)
  local l, acc, oct = tostring(name):match("^([A-G])([#b]?)(-?%d+)$")
  if not l then return nil end
  local n = STEP[l] + (acc == "#" and 1 or acc == "b" and -1 or 0)
  return n + (tonumber(oct) + 1) * 12
end

-- How open the loop is: its filter's cutoff (the lane the engine plays), 0
-- shut to 1 wide open on a log scale (examples/disco's energy).
local SHUT, OPEN = 260, 16000
function M.open(f)
  local hz = score.automation("buses/loop/Filter/frequency", f)
  return beat.clamp01(math.log(hz / SHUT) / math.log(OPEN / SHUT))
end

local KICK = { part = "drums", note = "kick", decay = 9 }
function M.kick(f) return score.pulse(f, KICK) end

-- The room behind every scene: a glow that brightens as the filter opens
-- and swells on the kick, its focus drifting with the beat.
function M.backdrop(f, b)
  local e, k = M.open(f), M.kick(f)
  local a = b * 0.3
  rect { x = 0, y = 0, w = 1920, h = 1080, fill = radial_gradient { cx = 960, cy = 520, r = 980,
    fx = 960 + math.cos(a) * 320, fy = 520 + math.sin(a) * 160,
    stops = { { 0, mix_color("#1a1226", "#3a1830", e * 0.8 + k * 0.15) }, { 0.55, "#120d1b" }, { 1, M.BG } } } }
end

-- The mascot (art/logo.svg): its pads light on the 909's notes (kick red,
-- clap orange, open hat yellow, hat white), it bobs on the kick and blinks
-- every four bars.
local PADS = { pad_1 = "kick", pad_2 = "clap", pad_3 = "open_hat", pad_4 = "hat" }
function M.dog(f, x, y, size, b)
  local o = {}
  for id, note in pairs(PADS) do
    o[id] = { visible = score.pulse(f, { part = "drums", note = note, decay = 14 }) > 0.3 }
  end
  local blink = (b % 16) > 14.5 and (b % 16) < 14.75
  o.eyes_open = { visible = not blink }
  o.eyes_closed = { visible = blink }
  o.notes = { visible = M.open(f) > 0.4, transform = translate(0, math.sin(b * math.pi / 2) * 0.6) }
  local bob = -size * 0.025 * M.kick(f)
  svg(f, { src = "dog.svg", x = x, y = y + bob, w = size, h = size, overrides = o })
end

-- 3786 as "3,786".
function M.thousands(n)
  local s = tostring(math.floor(n))
  return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

-- A note name the way a flat key writes it: "A#4" as "Bb4".
local FLAT = { ["C#"] = "Db", ["D#"] = "Eb", ["F#"] = "Gb", ["G#"] = "Ab", ["A#"] = "Bb" }
function M.flat(name)
  return (tostring(name):gsub("^([A-G]#)", FLAT))
end

-- Hz as words: "260 Hz", "2.6 kHz", "16 kHz".
function M.hz(v)
  if v >= 9950 then return string.format("%.0f kHz", v / 1000) end
  if v >= 1000 then return string.format("%.1f kHz", v / 1000) end
  return string.format("%.0f Hz", v)
end

return M
