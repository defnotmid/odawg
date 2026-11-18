-- The song is one JSON file: its top-level keys in the file's order, read
-- from the file itself, one a sixteenth (the scalars with their values, the
-- tables folded with how many they hold).

local beat = require("beat")
local ui = require("ui")
local score = require("track")
local T = require("timeline")
local prog, snap = beat.prog, beat.snap

local function count(v)
  if type(v) ~= "table" then return nil end
  local n = 0
  for _ in pairs(v) do n = n + 1 end
  return n
end

-- the file's top-level keys: two spaces in
local KEYS = {}
for _, line in ipairs(score.lines) do
  local key, rest = line:match('^  "([%w_]+)": (.*)$')
  if key then
    local v = score.spec[key]
    local folded = type(v) == "table"
    local open = rest:sub(1, 1)
    KEYS[#KEYS + 1] = {
      key = '"' .. key .. '": ',
      value = folded and (open == "[" and "[ … ]" or "{ … }") or rest:gsub(",%s*$", ""),
      n = folded and count(v) or nil,
      folded = folded,
    }
  end
end

local X, Y, COL_W, LINE_H, ROWS = 220, 286, 780, 54, math.ceil(#KEYS / 2)

local function render(f, lb)
  ui.backdrop(f, T.DATA + lb)
  ui.label(lb, 2, "a song is data")
  local h = 64 + ROWS * LINE_H
  text { "media/song.json", x = ui.RIGHT, y = 172, align = "right", font = ui.MONO, size = 28, fill = ui.DIM }
  ui.panel(ui.LEFT, 200, ui.RIGHT - ui.LEFT, h, "song.json", function()
    for i, k in ipairs(KEYS) do
      local at = ui.at((i - 1) * 0.25)
      if lb >= at then
        local col, row = (i - 1) // ROWS, (i - 1) % ROWS
        local x, y = X + col * COL_W, Y + row * LINE_H
        group({ opacity = prog(lb, at, at + 0.15), transform = translate((1 - snap(lb - at)) * 30, 0) }, function()
          text { x = x, y = y, font = ui.MONO, size = 32, spans = {
            { k.key, fill = ui.TEXT },
            { k.value, fill = k.folded and ui.D or ui.C },
          } }
          if k.n then
            text { "// " .. k.n, x = x + COL_W - 90, y = y, align = "right", font = ui.MONO, size = 32, fill = ui.DIM }
          end
        end)
      end
    end
  end)
end

return { name = "Data", title = "A SONG IS DATA", start = T.DATA, render = render }
