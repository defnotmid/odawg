# Workflows: making videos with odawg in onimite

Six runs through the API in [API.md](API.md), as the agent would write them. After each
are the problems it hit and what changed in the API because of them.

---

## W1. A narrated explainer: the narration leads

The brief is a ~40 s explainer:

- a lo-fi intro under the voice;
- a ramp into a house drop for a feature montage;
- an explanation over a lighter groove;
- an ambient outro;
- SFX on UI cards, and the picture pumping on the kick.

```lua
-- vo.lua: the narration (onimite's say; ottis unchanged)
return {
  intro    = say("intro", "Every video needs a soundtrack. Most of them get a stock loop."),
  features = say("features", "Onimite writes the score from the same numbers as the picture."),
  outro    = say("outro", "Make it yours."),
}
```

```lua
-- score.lua: the music, sized around the lines
require("vo")                                   -- the lines exist before the song reads their lengths

return song { "score", key = "A minor", seed = 7, room = "voice",
  sections = {
    { "intro",   duration = { audio = "intro", plus = { seconds = 1 } },
                 bpm = 84, style = "styles/lofi.json", energy = 0.3, chords = "Am7 Fmaj7 C G" },
    { "build",   duration = "2m", bpm = { 84, 124 } },
    { "drop",    duration = "8m", flex = { "4m", "8m" }, bpm = 124, style = "styles/house.json", energy = 1,
                 chords = "Am F C G" },
    { "explain", duration = { audio = "features", plus = { seconds = 1 } }, energy = 0.5 },
    { "outro",   duration = { audio = "outro", plus = { seconds = 3 } },
                 bpm = 70, style = "styles/ambient.json", chords = "Fmaj7 Am7" },
  },
  parts = {
    lead = { instrument = "pluck",
      play = { { "drop@4m..drop@8m", notes = "E5 G5 A5 - G5 E5 D5 -", subdivision = "8n" } } },
  },
}
```

```lua
-- video.lua
local score = require("score")
local T = score.time

-- where each line starts: one table for the tracks and the captions
local AT = { intro = T("intro@4n"), features = T("explain"), outro = T("outro@1m") }

video { width = 1920, height = 1080, fps = 60, duration = score.duration,
  buses = { music = {}, voice = {}, sfx = { gain_db = -6 } },
  audio = {
    { "score", bus = "music", ducked = true },
    { "intro", start = AT.intro },
    { "features", start = AT.features },
    { "outro", start = AT.outro },
  } }

scene { "Intro", start = T("intro"), render = function(f)
  captions(f.global_seconds, { src = "intro", start = AT.intro, x = 160, y = 960, w = 1600 })
end }

scene { "Drop", start = T("drop"), cue = "drop",
  audio = { { sound { "impact" }, start = 0, bus = "sfx" } },
  render = function(f)
    local kick = score.pulse(f, { part = "drums", note = "kick", decay = 8 })
    local s = score.section(f)                  -- s.progress drives the montage
    -- ... scale 1 + 0.01 * kick, a card per two bars from s.bar
  end }

local CARD_IN = 0.8
scene { "Explain", start = T("explain"),
  audio = { { sound { "blip", note = score.note("5", "explain") }, start = CARD_IN, bus = "sfx" } },
  render = function(f) end }

scene { "Outro", start = T("outro"), render = function(f) end }
```

**What worked**

- **No seconds typed for music.** Every start comes from `score.time`, and every length from
  the lines.
- **The section reads like a scene.** `duration = { audio = "intro", plus = ... }` is the
  form scenes already use, so I didn't need a new word (the first draft's `fit`).
- **The kick pulse is exact**, read from the drum part's notes rather than from onsets.
- **`--track score/drums` works** without me splitting the song into clips myself.

**What I changed**

- **Load order.** score.lua needs the lines' lengths, and the lines' starts need the song.
  That isn't a cycle: say → song → placement. `require("vo")` at the top of score.lua
  states the order.
- **Ducking and room.** `ducked = true` (gain under the voice, fframes' rule) and
  `room = "voice"` (the arrangement thins and opens 1–4 kHz) do different things. Both
  stay; the audio skill should recommend both for narration.
- **Snapping SFX to the grid.** A pop answering a word over a house beat is off the grid.
  Added `score.snap(t, "8n")`. A snapped sound shouldn't also carry the word's `cue`, or
  `inspect` reports the gap.

---

## W2. A music-led promo: the picture follows the music

The brief: 30 s of synthwave at 128 BPM, with a cut every two bars in the chorus and
flashes on the snare.

```lua
local score = song { "score", bpm = 128, key = "F# minor", style = "styles/synthwave.json",
  sections = {
    { "intro",  duration = "4m", energy = 0.4 },
    { "verse",  duration = "4m", energy = 0.7 },
    { "chorus", duration = "8m", energy = 1, transition = "impact" },
    { "outro",  duration = "2m", energy = 0.3, transition = "filter" },
  } }

video { width = 1080, height = 1920, fps = 60, duration = score.duration,
  buses = { music = {}, sfx = {} }, audio = { { "score", bus = "music" } } }

scene { "Intro", start = score.time("intro"), render = function(f) end }
scene { "Verse", start = score.time("verse"), render = function(f) end }
for k = 0, 3 do
  scene { "Shot" .. k, start = score.time(("chorus@%dm"):format(2 * k)), render = SHOTS[k + 1] }
end
scene { "Outro", start = score.time("outro"), render = function(f) end }

local SNARES = score.hits { part = "drums", note = "snare", range = "chorus" }
cue("snare", SNARES)                            -- inspect checks the flashes land on them
```

**What worked**

- **The structure is four lines**, and the style does the rest. The style is a file (copied
  from odawg's `examples/styles/`); it shows what it plays, if I need to override something.
- **`hits` feeds `cue` directly**, so flashes (animate keys with `cue = "snare[*]"`) are
  checked against the notes that made them.

**What I changed**

- **Bar offsets go through the song.** I first wrote
  `score.time("chorus") + 2 * k * score.seconds("1m")`. That's wrong under a tempo ramp,
  and it's how `tempo.lua`'s users already go wrong. Always resolve through the song
  (`chorus@2m`).
- **Durations need a position under a tempo map.** `seconds(d)` only works at a steady
  tempo, so it became `score.seconds(d, at)`. `at` defaults to the song's start; `d` comes
  first, so it stays `beat_clock`-compatible.

---

## W3. Two songs: a generated sting into a licensed track

The brief: a 2-bar cinematic sting at 120 BPM, then the client's licensed track (97 BPM)
coming in a bar early, cut to 40 s.

```lua
local sting = song { "sting", bpm = 120, key = "D minor",
  sections = { { "hit", duration = "2m", style = "styles/cinematic.json", energy = 1, transition = "impact" } } }

local track = song { "track", from = "licensed.mp3", start = sting.time("hit@1m"), duration = 40,
  sections = { { "verse", at = 0 }, { "chorus", at = "16m" },
               { "verse2", at = "32m", optional = true }, { "chorus2", at = "48m" } } }

local BAR = sting.seconds("1m", "hit@1m")
video { ..., duration = track.start + track.duration,
  audio = {
    { "sting", bus = "music", fade_out = BAR, curve = "equal_power" },
    { "track", bus = "music", fade_in = BAR, curve = "equal_power", ducked = true },
  } }
-- the picture over the track reads the track: track.pulse(f, 9), track.section(f)
```

**What worked**

- **No reel and no nested project.** The video's timeline is the parent, as in any editor.
  Each song keeps its own tempo. The crossfade is onimite's existing `fade_*` and `curve`.
- **`duration = 40` on a file song** cuts it at bar lines: it removes `verse2` and joins
  `chorus` to `chorus2` with a short crossfade. `odawg timeline` shows the edit.

**What I changed**

- **Section names must be unique across songs** in one video. Section names become cues,
  so onimite reports a name two songs share. The alternative, prefixing every cue, makes
  every reference longer for a rare case.
- **The licence of `licensed.mp3` is the user's business.** odawg only checks the samples
  it ships (`sample_noncommercial`).

---

## W4. Revisions on W1, which is where the time goes

| The user says | The edit | What moves | How I check |
| --- | --- | --- | --- |
| "Drop at 128" | `bpm = 128` on `drop` | later section starts, scenes, line starts, SFX, kick pulse | `onimite timeline video.lua` before and after; `inspect` stays clean |
| "Make a 30 s cut" | `duration = 30` on the song | `drop` shrinks 8m → 4m, then the tempo nudges ≤ 3 % | if it can't fit: `duration_unreachable` |
| "New narration" | the `say` text | `intro`/`explain`/`outro` regrow; everything after moves | `inspect` (`cue_drift` none) |
| "Synthwave drop" | `style = "styles/synthwave.json"` on `drop` | parts refilled; my `lead` stays | `no_events` if a style lacks the part that `pulse`/`hits` read |
| "Drums quieter" | `parts = { drums = { gain_db = -3 } }` | that part | `odawg audio analyze` per part |
| "Music too loud under her" | `ducked = { depth_db = -16 }` (existing) | gain under the voice | `onimite audio at video.lua explain@2m` |

For the 30 s cut, `duration_unreachable` lists the minimums so the fix is obvious:

```
song "score": 30.0s asked, 37.8s at least
  (intro 12.4s, build 3.4s, drop 7.7s at its flex minimum, explain 9.1s, outro 5.2s):
  shorten a line, or mark a section optional
```

**Syncing a word to a musical moment: pick one leader per moment.**

- *The voice follows the music*: "she says 'Onimite' on the drop".
  `{ "features", start = say_start(VO.features, "Onimite", T("drop")) }`.
- *The music follows the voice*: "the drop lands on her word". Place the line at a fixed
  time, then `{ "drop", start = say_cue(VO.intro, 1.0, "soundtrack") }`. odawg resizes
  `flex` sections and nudges the build's ramp to land the drop there, or reports
  `start_unreachable`.
- *The picture follows either*: `scene { start = say_cue(...) }` or `T("drop")`.

Lua evaluates eagerly, so a real cycle (the song's start depends on a line placed from the
song) can't be written: `score` isn't defined yet when the line's start is computed. The
skill doc should state the rule: per moment, decide who leads.

---

## W5. Later: hand-tuning in the DAW app (phase 3)

1. `onimite audio export video.lua --song score -o score.odawg` writes the song as a
   project. Its generated parts are loop clips anchored to sections, and each carries
   `made_by`.
2. The user edits the bass line and the mix in the GUI and saves.
3. In score.lua: `song { "score", from = "score.odawg", sections = { { "drop", duration = "4m" } } }`.
   Section overrides resize the anchored clips, so hand edits are kept. Clips the user
   edited lose `made_by` and are never regenerated. A later `style` change refills only
   the clips that still have it.
4. Without `--song`, `onimite audio export video.lua -o film.odawg` gives the whole
   soundtrack (voice and SFX as seconds-locked clips on their buses) for mixing. Bringing
   that mix back into the script is an open question; phase 3 can answer it.

---

## W6. An instrument the sets don't have

The brief: a lead doubled by a real violin, then a chamber piece on harp, flute, violin,
trumpet and cellos. None of them is a sample set. The steps are SOUND_DESIGN.md's (an
instrument the sets don't have); `examples/sfz_chamber.json` and `velvet_horizon.json`'s
`velvet_lead` are the result.

```json
"sources": {
  "vsco": {
    "url": "https://raw.githubusercontent.com/sgossner/VSCO-2-CE/6dd651d55dde97fd4028699be9d4481f26917891/",
    "page": "https://github.com/sgossner/VSCO-2-CE/tree/SFZ",
    "licence": "CC0-1.0",
    "credit": "VS Chamber Orchestra 2: Community Edition by Versilian Studios LLC ...",
    "pins": "pins/vsco.pins"
  }
},
"parts": { "violin": { "instrument": { "name": "vsco/SViolinVib.sfz", "ampeg_release": 0.5 }, ... } }
```

```
$ odawg pin examples/sfz_chamber.json
vsco: 43 pinned (32 new) in examples/pins/vsco.pins, licence CC0-1.0
```

What went wrong on the way, and what changed:

- **Mapping samples by file name.** The first attempt added six sets to odawg's register,
  their zones written from the file names. Trumpet and flute came out an octave high:
  VS Chamber Orchestra 2 names some files an octave low, and its own SFZ (on the
  repository's `SFZ` branch) maps them right. Those sets were dropped. A library's SFZ is
  played through `sources` instead, and SOUND_DESIGN.md says so.
- **An SFZ as a layer was silent.** A layer whose instrument was itself layered (an SFZ, a
  layered row) was dropped without a finding, and so was a machine. Now nested layers play
  as one table: conditions intersected, levels multiplied, each SFZ's groups its own. A
  machine as a layer is an error.
- **`odawg pin` succeeded when a fetch failed.** It printed the error but exited 0, so a
  script carried on with incomplete pins. It now exits non-zero.
- **`odawg fetch SPEC` ignored the song's sources.** It knew only the register's sets, so for
  an SFZ song it fetched none of its files and, the song naming no set, every set instead.
  Now it loads the song as a render does: what the notes reach, sources included, each
  file checked against its pin.
- **Levels.** One note at velocity 0.8 spans 17.6 dB across the five SFZ files (the cellos
  -21.8 LUFS max momentary, the flute -39.4). A part's register and velocities move it
  further: the violin needed 10 dB more than its C4 calibration where it played. Every
  part's `gain_db` was set from `odawg analyze`'s loudness per section. Levelling SFZ
  files automatically was considered and left out. A level kept with the pins would be
  per library, shared by songs; measured at the notes one song plays, re-pinning another
  would move its mix. A fixed reference key would fetch samples the song never plays. And
  either would leave the register's error: after a C4 calibration, parts still needed
  1 to 10 dB. Instead `inspect` reports `buried_part`: a part more than 15 LU under the
  mix in every section it plays, with the `gain_db` raise that puts it 12 LU under where
  it's loudest. `inspect` now measures the parts' stems as it streams, so `silent_part`
  reports from the CLI too.

---

## What the walkthroughs changed in API.md

**In odawg:**

- `score.snap(t, "8n")`.
- `score.seconds(d, at)` takes a position.
- Section `duration` and `start` take onimite's time forms.
- The `no_events` finding.
- `duration_unreachable` lists the minimums.
- From-file songs: `at` per section, and `duration` cuts at bar lines.
- An SFZ (or any layered row) can be a layer; a machine as a layer is an error (W6).
- `odawg pin` exits non-zero when a file couldn't be fetched (W6).
- `odawg fetch SPEC` fetches what the song plays, its sources' files too (W6).
- `buried_part`: a part far under the mix wherever it plays, with the raise to make (W6).

**In onimite:**

- Per-part clips appear automatically (`score/drums`).
- Section names are unique across songs.
- `say_start`.
- `audio export [--song]` (phase 3).
- The skill gains: "say → song → placement", "one leader per moment", and "resolve bar
  offsets through the song".

**Unchanged:** ottis; `say`, `say_cue` and `captions`; track fields. Every new piece of
onimite also appears through its MCP server, because the server shares the command rows.
