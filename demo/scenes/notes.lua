-- The note table: every part's notes as odawg composed them (score.events),
-- a lane a part, scrolling under the playhead. The drop: everything back,
-- the arpeggio in, the talk box's call.

local beat = require("beat")
local ui = require("ui")
local score = require("track")
local T = require("timeline")
local facts = require("facts")
local prog, snap = beat.prog, beat.snap

-- the lanes, top to bottom: the lines, then the band from the floor up
local ORDER = { "talk", "violins", "arp", "guitar", "stabs", "pad", "bass", "percussion", "drums" }

local LANES = {}
for i, part in ipairs(ORDER) do
  local notes, lo, hi, pads = {}, math.huge, -math.huge, {}
  for _, e in ipairs(score.events { part = part }) do
    local m = ui.midi(e.note)
    if not m then -- a pad of a kit: each its own row
      if not pads[e.note] then pads[#pads + 1] = e.note; pads[e.note] = #pads end
      m = pads[e.note]
    end
    local from = score.beat(e.time)
    notes[#notes + 1] = { from = from, len = score.beat(e.time + e.duration) - from, m = m, v = e.velocity or 0.8 }
    lo, hi = math.min(lo, m), math.max(hi, m)
  end
  -- a total order: table.sort isn't stable (and Lua picks its pivots at
  -- random), so notes starting together must not tie, or overlapping ones
  -- would stack differently in each of the render's Lua states
  table.sort(notes, function(a, b)
    if a.from ~= b.from then return a.from < b.from end
    if a.m ~= b.m then return a.m < b.m end
    if a.len ~= b.len then return a.len < b.len end
    return a.v < b.v
  end)
  LANES[i] = { part = part, role = score.spec.parts[part].role, notes = notes, lo = lo, hi = hi }
end

local TOP, LANE_H = 214, 68
local ROLL_X, NOW_X, PX = 400, 1080, 90 -- the roll's left edge, the playhead, pixels a beat

local function first_from(notes, b)
  local lo, hi = 1, #notes + 1
  while lo < hi do
    local mid = (lo + hi) // 2
    if notes[mid].from < b then lo = mid + 1 else hi = mid end
  end
  return lo
end

local function render(f, lb)
  local b = T.NOTES + lb
  ui.backdrop(f, b)
  ui.label(lb, 10, "every note, one table")
  local span_l, span_r = (ROLL_X - NOW_X) / PX, (ui.RIGHT - NOW_X) / PX
  for i, lane in ipairs(LANES) do
    local at = ui.at((i - 1) * 0.125)
    if lb >= at then
      local y = TOP + (i - 1) * LANE_H
      local col = ui.ROLE[lane.role] or ui.TEXT
      group({ opacity = prog(lb, at, at + 0.2) }, function()
        rect { x = ui.LEFT, y = y + LANE_H - 1, w = ui.RIGHT - ui.LEFT, h = 1, fill = ui.LINE }
        text { lane.part, x = ui.LEFT, y = y + 44, font = ui.MONO, size = 28, fill = col }
        group({ clip = { x = ROLL_X, y = y, w = ui.RIGHT - ROLL_X, h = LANE_H } }, function()
          -- notes are drawn from 8 beats back, so held notes that began earlier still show
          for k = first_from(lane.notes, b + span_l - 8), #lane.notes do
            local n = lane.notes[k]
            if n.from > b + span_r then break end
            if n.from + n.len >= b + span_l then
              local x = NOW_X + (n.from - b) * PX
              local ny = y + 8 + (1 - (n.m - lane.lo) / math.max(lane.hi - lane.lo, 1)) * (LANE_H - 28)
              local on = b >= n.from and b < n.from + math.max(n.len, 0.12)
              rect { x = x, y = ny, w = math.max(n.len * PX - 2, 5), h = 10, rx = 3, fill = col,
                opacity = on and 1 or (n.from > b and 0.35 or 0.6) * (0.5 + 0.5 * n.v) }
            end
          end
        end)
      end)
    end
  end
  rect { x = NOW_X - 1, y = TOP - 10, w = 3, h = #LANES * LANE_H + 20, fill = ui.TEXT, opacity = 0.8 }
  ui.fact(lb, 6, string.format("%s notes in one table, before a sample plays", ui.thousands(facts.NOTES)),
    "odawg timeline · the song's note table")
end

return { name = "Notes", title = "THE NOTE TABLE", start = T.NOTES, render = render }
