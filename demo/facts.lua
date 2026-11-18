-- Every number on screen, with where it comes from. What the song and its
-- pins hold is counted from them at load (the same counts `odawg timeline`
-- and the pins files give); what a render measured was measured by odawg's
-- CLI at v0.1.0 (6d064ed) on media/song.json, 2026-11-17, and is copied here
-- with the command that prints it.

local score = require("track")

local M = {}

-- ---- counted from the song --------------------------------------------------

-- Notes per part and in all, as composed (`odawg timeline demo/media/song.json`:
-- arp 128, bass 260, drums 764, guitar 1188, pad 98, percussion 640, stabs
-- 630, talk 62, violins 16).
M.NOTES, M.PARTS, M.PART_NOTES = 0, 0, {}
for name in pairs(score.spec.parts) do
  local n = #score.events { part = name }
  M.PART_NOTES[name] = n
  M.NOTES, M.PARTS = M.NOTES + n, M.PARTS + 1
end
M.BARS = 0
for _, s in ipairs(score.sections) do M.BARS = M.BARS + s.bars end

-- ---- counted from the pins --------------------------------------------------

-- Every file the song fetches from its sources: `sha256 size path` a line,
-- written by `odawg pin` (media/pins/*.pins). 91 files, 4 of them SFZ, 95.0
-- MB; the upright piano in the stabs is odawg's own VCSL set, pinned in its
-- register (assets/), not here.
M.PINS, M.PIN_FILES, M.PIN_SFZ, M.PIN_BYTES = {}, 0, 0, 0
local names = {}
for name in pairs(score.spec.sources) do names[#names + 1] = name end
table.sort(names)
for _, name in ipairs(names) do
  local src = score.spec.sources[name]
  local file = assert(io.open(SCRIPT_DIR .. "/media/" .. src.pins))
  for line in file:lines() do
    local sha, size, path = line:match("^(%x+) (%d+) (.+)$")
    if sha then
      M.PINS[#M.PINS + 1] = { source = name, sha = sha, size = tonumber(size), path = path }
      M.PIN_FILES, M.PIN_BYTES = M.PIN_FILES + 1, M.PIN_BYTES + tonumber(size)
      if path:match("%.sfz$") then M.PIN_SFZ = M.PIN_SFZ + 1 end
    end
  end
  file:close()
end

-- ---- measured by odawg's CLI ------------------------------------------------

-- `build/odawg render demo/media/song.json -o song.wav --master streaming`
-- prints the file's length (the song and its tail), loudness and true peak.
M.RENDER_LINE = "song.wav: 78.55s, -14.0 LUFS, -1.0 dBTP"

-- `build/odawg analyze demo/media/song.json --master streaming`, its first
-- line: "French touch: -14.0 LUFS, 3.0 LU range, -1.0 dBTP".
M.LUFS, M.LRA, M.TRUE_PEAK = "-14.0 LUFS", "3.0 LU", "-1.0 dBTP"

-- `build/odawg inspect demo/media/song.json --balance`: each part's LU under
-- the mix in every section it plays (nil: no notes there), and no
-- role_balance finding (each in its role's band, with the check's 1 LU of
-- slack).
M.SECTIONS = { "intro", "groove", "hook", "break", "drop", "outro" }
M.BALANCE = {
  { part = "talk", role = "melody", lu = { nil, nil, 8.3, nil, 7.8, nil } },
  { part = "violins", role = "counter", lu = { nil, nil, 9.0, nil, nil, nil } },
  { part = "arp", role = "counter", lu = { nil, nil, nil, nil, 9.6, nil } },
  { part = "drums", role = "drums", lu = { 6.1, 6.1, 7.3, 8.6, 7.5, 6.3 } },
  { part = "bass", role = "bass", lu = { 5.8, 6.2, 8.7, 7.5, 8.3, 7.3 } },
  { part = "guitar", role = "comp", lu = { 10.0, 10.3, 12.8, 9.6, 12.3, 10.8 } },
  { part = "stabs", role = "comp", lu = { 12.5, 12.7, 8.6, nil, 9.2, 6.8 } },
  { part = "pad", role = "pad", lu = { nil, nil, 13.3, 10.3, 14.1, nil } },
  { part = "percussion", role = "texture", lu = { nil, 23.2, 17.9, nil, 18.0, 16.8 } },
}

-- Each role's band, LU under the mix (odawg check/checks.odin, ROLE_TABLE),
-- and how far outside it a part sits before it's told (ROLE_SLACK).
M.ROLE_BAND = { melody = { 0, 8 }, counter = { 4, 10 }, bass = { 3, 8 }, drums = { 2, 8 }, comp = { 6, 12 },
  pad = { 9, 15 }, texture = { 12, 25 } }
M.ROLE_SLACK = 1

return M
