-- Instruments are rows: the talk box, the song's own voice, drawn from its
-- row in the file (its nodes, their classes, the wires its `input`,
-- `inputs`, `by` and `amp` fields name). Solid wires carry sound, dashed
-- ones a control; while the talk part plays a note (score.events) the
-- sound runs through it and the note's name sits over the output.

local beat = require("beat")
local ui = require("ui")
local score = require("track")
local T = require("timeline")
local prog, snap = beat.prog, beat.snap

local ROW
for _, file in ipairs(score.spec.instruments) do
  if type(file) == "table" and file.talk then ROW = file.talk end
end

-- where each node sits: columns left to right as the sound flows
local BOX_W, BOX_H = 190, 100
local function col(i) return ui.LEFT + i * (ui.RIGHT - ui.LEFT - BOX_W) / 6 end
local AT = {
  vib = { col(0), 460 },
  saw = { col(1), 395 }, buzz = { col(1), 525 },
  voice = { col(2), 460 }, mouth = { col(2), 230 },
  f1 = { col(3), 330 }, f2 = { col(3), 460 }, f3 = { col(3), 590 },
  vowels = { col(4), 460 },
  drive = { col(5), 460 },
  out = { col(6), 460 }, env = { col(6), 650 },
}

-- Every list is built in a sorted order: pairs() walks a table in an order
-- each Lua state picks for itself, and a render builds frames in many
-- states, so wires drawn in pairs() order would overlap differently from
-- frame to frame.
local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

local NODES, WIRES = {}, {}
for _, name in ipairs(sorted_keys(ROW.nodes)) do
  local node = ROW.nodes[name]
  assert(AT[name], "rows.lua: no place for the talk box's node " .. name)
  NODES[#NODES + 1] = { name = name, class = node.class, x = AT[name][1], y = AT[name][2] }
  local function wire(from, kind) WIRES[#WIRES + 1] = { from = from, to = name, kind = kind } end
  if node.input then wire(node.input, "sound") end
  for _, i in ipairs(node.inputs or {}) do wire(i, "sound") end
  if node.amp then wire(node.amp, "control") end
  for _, field in ipairs(sorted_keys(node)) do
    local v = node[field]
    if type(v) == "table" and v.by then wire(v.by, "control") end
  end
end
table.sort(NODES, function(a, b) return a.x < b.x or (a.x == b.x and a.y < b.y) end)
-- the order they come in: left to right, a sixteenth apart
for i, n in ipairs(NODES) do n.at = ui.at((i - 1) * 0.25) end

-- a wire's path: sound leaves a box's right edge for the next one's left;
-- a control leaves its box toward the target's nearest edge
local function wire_path(w)
  local a, b = AT[w.from], AT[w.to]
  local ax, ay, bx, by
  if w.kind == "sound" or a[1] < b[1] then
    ax, ay, bx, by = a[1] + BOX_W, a[2] + BOX_H / 2, b[1], b[2] + BOX_H / 2
    if w.kind == "control" and a[2] ~= b[2] then
      ax, ay = a[1] + BOX_W, a[2] + BOX_H / 2
      bx, by = b[1], b[2] + (a[2] < b[2] and 25 or BOX_H - 25)
    end
  else -- straight up into the box above
    ax, ay, bx, by = a[1] + BOX_W / 2, a[2], b[1] + BOX_W / 2, b[2] + BOX_H
    return string.format("M%.1f %.1f L%.1f %.1f", ax, ay, bx, by)
  end
  local dx = math.max((bx - ax) * 0.5, 20)
  return string.format("M%.1f %.1f C%.1f %.1f %.1f %.1f %.1f %.1f", ax, ay, ax + dx, ay, bx - dx, by, bx, by)
end
for _, w in ipairs(WIRES) do w.d = wire_path(w) end

-- the talk's notes in the hook, in beats
local NOTES = {}
for _, e in ipairs(score.events { part = "talk", range = "hook" }) do
  NOTES[#NOTES + 1] = { from = score.beat(e.time), to = score.beat(e.time + e.duration), name = e.note }
end
local function sounding(b)
  for _, n in ipairs(NOTES) do
    if b >= n.from and b < n.to then return n end
  end
end

local function render(f, lb)
  local b = T.ROWS + lb
  ui.backdrop(f, b)
  ui.label(lb, 7, "instruments are rows")
  local note = sounding(b)
  local live = note and math.exp(-(b - note.from) * 1.5) * 0.5 + 0.5 or 0
  -- wires under the boxes
  for _, w in ipairs(WIRES) do
    local at = 0
    for _, n in ipairs(NODES) do if n.name == w.to then at = n.at + 0.1 end end
    if lb >= at then
      local op = prog(lb, at, at + 0.3)
      local sound = w.kind == "sound"
      path { d = w.d, fill = "none", stroke = sound and ui.DIM or ui.E, stroke_width = sound and 3 or 2,
        stroke_dasharray = sound and nil or { 8, 8 }, opacity = op * 0.7 }
      if note and sound then
        path { d = w.d, fill = "none", stroke = ui.D, stroke_width = 4, opacity = op * live,
          stroke_dasharray = { 14, 12 }, stroke_dashoffset = -lb * 60 }
      end
    end
  end
  for _, n in ipairs(NODES) do
    if lb >= n.at then
      local p = snap(lb - n.at)
      group({ opacity = prog(lb, n.at, n.at + 0.15), transform = { scale = 0.94 + 0.06 * p,
        origin = { n.x + BOX_W / 2, n.y + BOX_H / 2 } } }, function()
        rect { x = n.x, y = n.y, w = BOX_W, h = BOX_H, rx = 14, fill = ui.PANEL,
          stroke = note and ui.D or ui.LINE, stroke_width = 2, stroke_opacity = note and live or 1 }
        text { n.name, x = n.x + 18, y = n.y + 42, font = ui.MONO, size = 28, fill = ui.TEXT }
        text { n.class, x = n.x + 18, y = n.y + 80, font = ui.MONO, size = 28, fill = ui.DIM }
      end)
    end
  end
  -- the note playing, over the output
  if note then
    local o = AT.out
    text { ui.flat(note.name), x = o[1] + BOX_W / 2, y = o[2] - 40, align = "center", font = ui.SANS, size = 96,
      fill = ui.D, opacity = 0.4 + 0.6 * live }
  end
  ui.fact(lb, 4, string.format("the talk box: %d nodes wired by name, no code", #NODES),
    "media/song.json · instruments · talk")
end

return { name = "Rows", title = "INSTRUMENTS ARE ROWS", start = T.ROWS, render = render }
