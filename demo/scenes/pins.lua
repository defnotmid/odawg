-- Sources, pinned: the song's four libraries as the file names them (a
-- repository at a commit, a licence, a pins file), and beside them every
-- line of their pins rolling past, each file's SHA-256 and size, checked.
-- The break: the kick out, the filter down, the hats alone.

local beat = require("beat")
local ui = require("ui")
local score = require("track")
local T = require("timeline")
local facts = require("facts")
local prog, snap = beat.prog, beat.snap

local SOURCES = {}
do
  local names = {}
  for name in pairs(score.spec.sources) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local s = score.spec.sources[name]
    local repo, commit = s.url:match("githubusercontent%.com/[^/]+/([^/]+)/(%x+)/")
    local n = 0
    for _, p in ipairs(facts.PINS) do if p.source == name then n = n + 1 end end
    SOURCES[#SOURCES + 1] = { name = name, repo = repo, commit = commit:sub(1, 7), licence = s.licence, files = n }
  end
end

local function size(bytes)
  if bytes >= 1e6 then return string.format("%.1f MB", bytes / 1e6) end
  return string.format("%.0f KB", bytes / 1e3)
end
local LINES = {}
for i, p in ipairs(facts.PINS) do
  LINES[i] = { sha = p.sha:sub(1, 8), size = size(p.size), file = p.path:match("([^/]+)$") }
end

local LIST_X, LIST_Y, LINE_H, SHOWN = 900, 236, 56, 10

local function render(f, lb)
  ui.backdrop(f, T.PINS + lb)
  ui.label(lb, 9, "sources, pinned by SHA-256")
  for i, s in ipairs(SOURCES) do
    local at = ui.at((i - 1) * 0.5)
    ui.rise(lb, at, function()
      local y = 220 + (i - 1) * 146
      ui.panel(ui.LEFT, y, 680, 126, "sources/" .. s.name, function()
        text { s.name, x = ui.LEFT + 28, y = y + 52, font = ui.SANS, size = 40, fill = ui.TEXT }
        text { s.licence, x = ui.LEFT + 652, y = y + 52, align = "right", font = ui.MONO, size = 28, fill = ui.D }
        text { string.format("%s @%s", s.repo, s.commit), x = ui.LEFT + 28, y = y + 98,
          font = ui.MONO, size = 28, fill = ui.DIM }
      end)
    end)
  end
  -- the pins rolling up: all of them over the scene, the newest at the bottom
  local done = #LINES * beat.clamp01((lb - 1) / 12)
  group({ clip = { x = LIST_X, y = LIST_Y - 40, w = ui.RIGHT - LIST_X, h = SHOWN * LINE_H } }, function()
    local last = math.floor(done)
    for i = math.max(1, last - SHOWN + 1), math.min(#LINES, last + 1) do
      local l = LINES[i]
      local y = LIST_Y + (SHOWN - 1 - (done - i + 1)) * LINE_H + LINE_H
      local checked = i <= last
      text { x = LIST_X, y = y, font = ui.MONO, size = 28, spans = {
        { l.sha .. "  ", fill = ui.DIM },
        { string.format("%7s  ", l.size), fill = ui.DIM },
        { l.file, fill = ui.TEXT },
      } }
      if checked then
        polyline { points = { { ui.RIGHT - 22, y - 10 }, { ui.RIGHT - 13, y - 1 }, { ui.RIGHT - 2, y - 20 } },
          stroke = ui.D, stroke_width = 4, fill = "none", line_cap = "round", line_join = "round" }
      end
    end
  end)
  ui.fact(lb, 6, string.format("%d files, %.1f MB: only what the notes reach", facts.PIN_FILES, facts.PIN_BYTES / 1e6),
    "media/pins/*.pins, written by odawg pin")
end

return { name = "Pins", title = "SOURCES, PINNED", start = T.PINS, render = render }
