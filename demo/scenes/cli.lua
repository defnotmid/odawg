-- The same file, on the command line: odawg's CLI renders demo/media/song.json
-- (the command types in over two beats) and prints what it measured, the
-- line it printed when facts.lua was written.

local beat = require("beat")
local ui = require("ui")
local T = require("timeline")
local facts = require("facts")
local prog, snap = beat.prog, beat.snap

local CMD = "odawg render demo/media/song.json -o song.wav --master streaming"
local TYPE_FROM, TYPE_TO, OUT_AT = 0.25, 2.25, 3

local function render(f, lb)
  ui.backdrop(f, T.CLI + lb)
  ui.label(lb, 12, "the same file, from the command line")
  ui.panel(ui.LEFT, 300, ui.RIGHT - ui.LEFT, 300, "terminal", function()
    local n = math.floor(#CMD * prog(lb, TYPE_FROM, TYPE_TO))
    local caret = (lb < OUT_AT and (lb * 2) % 1 < 0.5) and "▌" or ""
    text { x = ui.LEFT + 48, y = 400, font = ui.MONO, size = 32, spans = {
      { "$ ", fill = ui.D }, { CMD:sub(1, n) .. caret, fill = ui.TEXT } } }
    if lb >= OUT_AT then
      group({ opacity = prog(lb, OUT_AT, OUT_AT + 0.1) }, function()
        text { facts.RENDER_LINE, x = ui.LEFT + 48, y = 480, font = ui.MONO, size = 32, fill = ui.C }
      end)
    end
  end)
end

return { name = "CLI", title = "THE CLI", start = T.CLI, render = render }
