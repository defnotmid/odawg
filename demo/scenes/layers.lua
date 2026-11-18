-- Layers: three of the song's rows stack a voice of its own over someone
-- else's recording (from the file: bassline, stabs, silk), each card
-- lighting on the notes of the part that plays it.

local beat = require("beat")
local ui = require("ui")
local score = require("track")
local T = require("timeline")
local prog, snap = beat.prog, beat.snap

local ROWS
for _, file in ipairs(score.spec.instruments) do
  if type(file) == "table" and file.bassline then ROWS = file end
end

-- which part plays each row
local PLAYED_BY = {}
for name, part in pairs(score.spec.parts) do
  if type(part.instrument) == "string" then PLAYED_BY[part.instrument] = name end
end

-- a layer as two lines: what it is, and where it comes from
local function describe(layer)
  local inst = layer.instrument
  local name = type(inst) == "table" and (inst.name or inst[1]) or inst
  local gain = layer.gain_db and string.format("%+g dB", layer.gain_db) or ""
  if name:match("%.sfz$") then
    local lib, file = name:match("^([^/]+)/(.+)$")
    return file, "source " .. lib, true, gain
  elseif name == "Sampler" then
    return "Sampler", "set " .. inst.set, true, gain
  end
  return name, "a row of nodes", false, gain
end

local CARDS = {}
for i, row in ipairs { "bassline", "stabs", "silk" } do
  local layers = {}
  for _, l in ipairs(ROWS[row].layers) do
    local a, b, recorded, gain = describe(l)
    layers[#layers + 1] = { a = a, b = b, recorded = recorded, gain = gain }
  end
  CARDS[i] = { row = row, part = PLAYED_BY[row], layers = layers }
end

local GAP = 40
local CARD_W = (ui.RIGHT - ui.LEFT - 2 * GAP) / 3

local function render(f, lb)
  ui.backdrop(f, T.LAYERS + lb)
  ui.label(lb, 8, "layers: a voice and a recording")
  for i, c in ipairs(CARDS) do
    local at = ui.at((i - 1) * 0.5)
    if lb >= at then
      local x = ui.LEFT + (i - 1) * (CARD_W + GAP)
      local hit = score.pulse(f, { part = c.part, decay = 6 })
      local p = snap(lb - at)
      group({ opacity = prog(lb, at, at + 0.15), transform = translate(0, (1 - p) * 60) }, function()
        ui.panel(x, 220, CARD_W, 560, "layers/" .. c.row, function()
          text { c.row, x = x + 32, y = 290, font = ui.SANS, size = 52, fill = ui.TEXT }
          text { "plays " .. c.part, x = x + 32, y = 336, font = ui.MONO, size = 28, fill = ui.DIM }
          for k, l in ipairs(c.layers) do
            local y = 380 + (k - 1) * 190
            local tint = l.recorded and ui.D or ui.B
            rect { x = x + 24, y = y, w = CARD_W - 48, h = 160, rx = 14, fill = tint, opacity = 0.08 + 0.22 * hit }
            rect { x = x + 24, y = y, w = 6, h = 160, rx = 3, fill = tint }
            text { l.recorded and "RECORDED" or "SYNTH", x = x + 50, y = y + 44, font = ui.MONO, size = 28,
              fill = tint }
            if l.gain ~= "" then text { l.gain, x = x + CARD_W - 48, y = y + 44, align = "right", font = ui.MONO, size = 28, fill = ui.DIM } end
            text { l.a, x = x + 50, y = y + 92, font = ui.MONO, size = 28, fill = ui.TEXT }
            text { l.b, x = x + 50, y = y + 134, font = ui.MONO, size = 28, fill = ui.DIM }
          end
        end)
      end)
    end
  end
  ui.fact(lb, 4, "the library's own SFZ, not samples mapped by hand", "odawg README: SFZ v1 and the common v2")
end

return { name = "Layers", title = "LAYERS", start = T.LAYERS, render = render }
