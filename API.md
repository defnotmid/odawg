# odawg: API proposal

odawg is sound for Odin, in Tone.js's vocabulary. It is a sibling library of ovg, o3d,
oksl, odecs and ottis, built the same way:

- **A plain Odin library.** It has no Lua. onimite binds it to Lua, as it binds o3d
  (`script/view3d_api.odin`) and ottis (`script/say_api.odin`, through `speech/`).
- **One existing vocabulary.** o3d speaks three.js and ovg speaks femtovg/SVG. odawg speaks
  **Web Audio and Tone.js**, which agents and people already know. Where odawg adds
  something, it says so, the way ovg's README separates "From femtovg" from "Added in ovg".
- **Deterministic and stateless.** It has a `VERSION` that changes whenever the output for
  the same input does (like `pocket.VERSION`). Hosts own the caches: onimite's adapter
  keeps renders the way `speech/` keeps lines.
- **Data-oriented**: layers as packages
  (`base`, `tempo`, `theory`, `dsp`, `analyze`, `assets`, `spec`, `song`, `render`, `check`,
  then `tools/odawg`), imported as `deps:odawg/song` etc.; every kind (node kind,
  effect, play pattern, transition, check, mastering target, command) is a table row and
  its behaviour a rule table; flat tables with spans; `/` names. README.md lists the rules.
- **Realtime first.** The engine streams any block from anywhere, deterministically and
  independent of block size; an export is that stream partitioned (time segments × tracks)
  across cores. No caches: generated assets (a `say` line, a downloaded sample set) are
  stored, music is computed.
- **Samples download on first use** (`assets/`, like `ottis/assets`): a register table with
  each set's source, pinned SHA-256, licence and credit; never committed.

What odawg is to onimite's sound, ovg is to its pixels. onimite decides what goes where on
the video; odawg makes and mixes the sound. Usage walkthroughs are in
[WORKFLOWS.md](WORKFLOWS.md), and the decisions they settled are at the end of this file.

---

## 1. What lives where

The rule: if two clients need it, it is in odawg. If it mentions frames, scenes, captions,
cues or `say()`, it is in onimite.

| | odawg (Odin library) | onimite (Lua binding, adapter, commands) | a GUI (later) |
| --- | --- | --- | --- |
| reads | a **song spec** (data: §3) as an Odin struct or JSON | the `song{}` / `sound{}` Lua tables, which it turns into specs | `.odawg` projects |
| owns | composing (spec → project), the project document and its ops, the engine, render, time queries, analysis, checks, instruments, effects, styles (as data) | the video clock, scenes, `cue`/`inspect`, `say` and captions, track placement, the render cache, commands and MCP | the editing UI |
| sync | generic constraints: a section's `duration` (at least N s) and `start` (exactly at N s); finding moments in sound (onsets, the beat, a song's note hits, energy) | turning words, scenes and clips into those numbers; naming moments on the video (cues) and checking picture and sound land on them | — |
| sound | the whole mix (phase 2): clips, songs, sounds, buses, ducking, master, analysis, decoding, the stream the preview plays | placing tracks on the video, resolving scene-relative times to seconds | — |
| calls | — | the odawg Odin API | the odawg Odin API, and later a C ABI |

---

## 2. Conventions

### Vocabulary

Borrowed from Web Audio and Tone.js, in snake case:

- **Instruments:** `Synth`, `MonoSynth`, `FMSynth`, `AMSynth`, `DuoSynth`, `PolySynth`,
  `MembraneSynth`, `MetalSynth`, `NoiseSynth`, `PluckSynth`, `Sampler`, `Player`, with
  `oscillator = { type = "sawtooth" | "fatsawtooth", count, spread }`,
  `envelope = { attack, decay, sustain, release }`, and
  `filter = { type, frequency, q, rolloff }` plus `filter_envelope`.
- **Effects:** `Filter`, `EQ3`, `Compressor`, `Limiter`, `Gate`, `Reverb`
  (`decay`, `pre_delay`), `FeedbackDelay` and `PingPongDelay` (`delay_time`, `feedback`),
  `Chorus`, `Distortion`, `BitCrusher`, `AutoFilter`, `StereoWidener`. Every effect has
  `wet`.
- **Transport:** `bpm`, `time_signature`, `swing`, `swing_subdivision`. A tempo change
  ramps like `bpm.rampTo` does.
- **Notes:** `"C4"` = MIDI 60. `velocity` runs 0..1. A note event is
  `{ time, note, duration, velocity }`, Tone.Part's shape. A sequence is `notes` plus
  `subdivision` (Tone.Sequence). An arpeggio uses Tone.Pattern's names (`"up"`, `"down"`,
  `"upDown"`, …).
- **Time strings:** `"4n"`, `"8n."`, `"8t"`, `"1m"`, `"2:1:0"` (bars:quarters:sixteenths,
  0-based).

Added in odawg:

- **Structure:** sections, styles (as data), `energy`, `transition`.
- **Patterns:** step strings (`"x...x..."`), chord progressions (`"Am7 F C G"`), chord
  degrees (`degrees = "1 . 5 ."`).
- **Instruments as data:** a row of nodes over a registry of node kinds, with options
  (controls) that set or scale its fields; a machine of pads (§3.4). Tone's classes are
  built-in rows; the TR-808, TR-909, a TB-303 and `synth.lua`'s voices are example files.
- **Mixing:** `sidechain`, `room` (the arrangement makes space for another sound),
  `master` targets.
- **Checking:** checks that stand in for listening, and analysis (loudness, onsets, beat),
  moved out of onimite.

### Units and names: one rule everywhere

- **A bare number is seconds.** This holds in onimite, in Tone.js and in Web Audio. Musical
  time is always a string: `"2m"`, `"8n"`, `"drop@1m"`.
- **Levels are `gain_db`**, as on onimite's tracks and buses. This is the one place odawg
  doesn't use Tone's name (`volume`), so a script has one word for level. `pan` runs -1..1.
- **The first entry is the name**: `song { "score", ... }`, `{ "drop", duration = "8m" }`,
  `{ "Filter", type = "lowpass" }`. It works like `scene { "Intro" }` and
  `{ "music.mp3", start = 0 }`. Devices take their class this way, not as `type =`
  (view3d's style), because Tone's own `Filter` and oscillators already use `type`. In JSON
  the first entry is `"name"` or `"class"`.
- **Unknown keys warn**, through onimite's normal field checks.
- **Times on the video use onimite's forms**: seconds, `{ frame = n }`, `{ audio = "clip" }`,
  `plus`/`minus`.
- **Song positions use one grammar**, shared with onimite's CLI (which gains the Tone units:
  `frame video.lua drop@1m`):

| form | meaning |
| --- | --- |
| `12.5` | seconds |
| `"drop"` | a section or marker (also a cue on the video) |
| `"drop@1m"`, `"drop@-4n"`, `"drop@0.5s"`, `"drop@2:0:0"` | an offset from it: Tone time or seconds |
| `"drop..outro"` | a range (onimite's `a..b`), to the end of section `outro` |
| `"drop@4m.."` | 4 bars into `drop` to the end of `drop`, not of the song (that's `"drop@4m..end"`) |
| `"end"` | the song's end |

- **Conversions keep `beat_clock`'s signatures**: `time(beat)`, `beat(t)`, `bar(t)`,
  `seconds(beats)`, `frame(beat, fps)`, `pulse(t, sharpness)`. Here `time` and `seconds`
  also take the strings above. A song is a drop-in for `beat_clock` and
  `examples/common/tempo.lua`.

---

## 3. The song spec (data)

The same fields in a Lua table (onimite) or JSON (the `odawg` CLI and a GUI's "new from
spec").

```lua
song { "score",
  start = 0,                         -- where it sits on the video (onimite: any time form)
  bpm = 120, time_signature = 4, key = "A minor", seed = 1, swing = 0,
  duration = nil,                    -- optional target length in seconds (§3.2)
  gain_db = -10,                     -- the whole song's level, headroom for a mix: replaces -10, isn't added to it
  from = nil,                        -- "track.mp3" | "score.odawg": a song from a file (§3.7)

  sections = {
    { "intro", duration = "8m", bpm = 84, style = "lofi", energy = 0.3, chords = "Am7 Fmaj7 C G" },
    { "build", duration = "2m", bpm = { 84, 124 }, transition = "riser" },
    { "drop",  duration = "8m", flex = { "4m", "8m" }, bpm = 124, style = "house", energy = 1 },
  },

  parts = {                          -- override or add to the style's parts, by name
    drums = { instrument = { "machines/909.json", tone = 0.55 },
      play = { { "drop", steps = { kick = "x...x...x...x...", clap = "....x.......x..." } } } },
    bass = { instrument = "sub_bass", gain_db = -8, sidechain = "drums/kick",
      play = { { "drop", degrees = "1 . . 1 . . 5 . 1 . . 1 . 8 . .", subdivision = "16n" } } },
    lead = { instrument = { "MonoSynth", oscillator = { type = "fatsawtooth", count = 3, spread = 20 } },
      effects = { { "FeedbackDelay", delay_time = "8n.", feedback = 0.3, wet = 0.25 } },
      sends = { hall = -14 },
      play = { { "drop@4m..", notes = "E5 G5 A5 - G5 E5 D5 -", subdivision = "8n" } } },
  },
  returns = { hall = { { "Reverb", decay = 3.2, pre_delay = 0.02 } } },
  markers = { { "logo", at = "drop@2m" } },
  room = nil,                        -- onimite: "voice" (a bus); odawg itself: spans of seconds
}
```

### 3.1 Sections

A section takes:

- `duration`: Tone time; seconds, rounded **up** to whole bars; or, in onimite, any duration
  form (`{ audio = "intro", plus = { seconds = 1 } }`, like a scene).
- `start`: exactly this many seconds, like a scene's `start`. odawg resizes `flex` sections
  and nudges tempi before it to land there.
- `bpm`: a number, or `{ from, to }` for a ramp.
- `time_signature`, `style`, `energy` (0..1), `chords`.
- `transition`: `"riser" | "fill" | "impact" | "pause" | "filter" | "cut" | "none"`. The
  default is picked from the change in energy. Risers and impacts play on the `fx` part,
  with its `gain_db`, `effects` and `sends` when the spec has one.
- `flex = { min, max }`, `optional`, `stretch = "tempo"`.

Fields not given carry over from the section before. Changing one section moves everything
after it.

### 3.2 Length

With `duration = 30` on the song, odawg resizes `flex` sections by whole bars, drops
`optional` ones (last first), then nudges tempo by up to ±3 % to land exactly. If the spec
can't be satisfied, that's a finding (`start_unreachable`, `duration_unreachable`), never a
silent compromise.

### 3.3 Parts and play entries

A part takes `instrument` (a row's name or file, or `{ "Class", ...its options }`: §3.4), `gain_db`,
`pan`, `effects`, `sends`, `sidechain = "part/note"`, `mute = "range"` and `play`.

A play entry is `{ range, ... }` with one of:

- `steps`: per drum voice, a string, or a list cycled per bar (`x` hit, `X` accent, `.`
  rest).
- `notes` and `subdivision`: a Tone.Sequence. A string (`-` holds) or a list
  (`{ "C4", { "E4", "G4" }, false }`).
- `degrees` and `subdivision`: chord degrees that follow the progression.
- `events`: Tone.Part events.
- `arpeggio = { pattern, interval, octaves }`.
- `chords = { voicing, rhythm }`.

Entries can also take `velocity`, `octave` and `humanize`.

### 3.4 Instruments

An instrument is data, never code: a row of nodes wired by name, read into a program where
a part plays it. A part's `instrument` is one of:

- a name: a row the spec (or its style) declares in `instruments = { name = row }` or in a
  file of rows (`instruments = "instruments/classic.json"`), else a built-in row (Tone's
  classes: `Synth`, `MonoSynth`, `FMSynth`, `AMSynth`, `MembraneSynth`, `MetalSynth`,
  `NoiseSynth`, `PluckSynth`, `Sampler`, `Player`; `odawg show instrument/MonoSynth` prints
  one, to copy);
- a file of one row: `"instruments/tb303.json"`, `"machines/909.json"` (`spec.instrument_files`
  lists what a host reads and hands back with `spec_add_instrument_text`);
- a name and changes: `{ "MonoSynth", filter = { q = 4 } }` (its options) or
  `{ "pad", nodes = { env = { release = 2 } } }` (by node).

A row:

```lua
{
  nodes = {
    osc = { "Osc", wave = "sawtooth", frequency = { by = "lfo", octaves = 0.02 } },
    env = { "Env", attack = 0.01, release = 0.3 },
    lfo = { "Lfo", rate = "4n" },
    out = { "Filter", "osc", frequency = { base = 300, by = "env", octaves = 3 }, amp = "env" },
  },
  out = "out", mono = false, portamento = 0, length = 0, note = "C4", velocity = "amp",
  options = { cutoff = "out/frequency", decay = { { "env/decay" }, { "env/release", op = "mul", scale = 2 } } },
}
```

- **Nodes** are kinds of the registry (`device.register_node`; a host adds its own the
  same way): Osc, Noise, Random, Env, Decay, Ramp, Lfo, Filter, Drive, Slew, Map, Mix, Mul,
  Comb, Sampler, Clip. Their order means nothing: a program runs them after what they read,
  and leaves out what the out doesn't hear.
- **A field** is a number, a choice, a Tone length, or what moves it: `{ base, by, octaves
  | ratio | sweep | index | amount | depth | at_most, exponent }` (a list of those). `by` is
  a node or the note's `velocity`, `accent`, `slide`, `gate`. `at_most` caps the field
  (by the source: an accent's shorter decay). Every node has `gain_db`, `pan` and `amp`.
- **Steady values:** a node reading only what holds for the note (velocity, accent, a
  Random, another such node) through a stateless kind (Map, Mul, Mix, Drive) runs one
  sample a chunk.
- **Options** are controls: a name and its targets, each `"node/field"` (set) or
  `{ path, op = set | mul | add | octaves, scale = 1, offset = 0 }` (the value x = value ×
  scale + offset sets the field to x, base × x, base + x, base × 2^x). A path may end at a
  modulator's field (`ladder/frequency/octaves`), and on a machine reach its pads
  (`pads/*/amp*/time`; a part ending `*` is a prefix). A row gives an option's value by
  its name (`cutoff = 600`); `envelope = { attack = 0.1 }` is `envelope/attack`. A control
  named as a node's field it doesn't simply set is a warning (`control_shadows_field`), a
  target reaching nothing is too (`unknown_option_target`).
- **A machine** is `{ pads = { kick = { instrument, key, choke, gain_db } } }`: each pad
  its own row; a note plays its pad by name (`steps = { kick = ... }`), else the pad at its
  pitch; a pad cuts those it chokes. The example 808 and 909 take `decay` (1: as built),
  `tone` (0.5) and `tune` (semitones), v0.0.7's DrumMachine knobs.
- **After compose**, a command sets a control by name (`Param_Set "bass/cutoff"`), else a
  node's field (`"bass/out/q"`); a change that would make a mono node stereo is refused.
- **In memory:** `device.compile_program(progs, &desc, findings)` places a `Program_Desc`
  (nodes, mods, pads, keys, controls as plain data) without JSON; spec reads rows into one.
- **A clip** is a program of one `Clip` node (`song.append_clip`, or the built-in `Player`
  row): a set played from `offset`, for the note's length, with `fade_in`, `fade_out`,
  `curve`, `mono`. A seek starts it where it is.

### 3.5 Styles

A style is a partial spec: its parts with play entries for each energy band, plus a mix
template. A band `{ 0.4, 0.7 }` runs from 0.4 up to, not including, 0.7 (a band ending at 1
includes it), so two bands that touch never both play. There's no new schema, and none ship in the library: a song's own `styles = { name = {
parts, returns, swing } }`, or files. `examples/styles/` has seven to copy: `acid_house`,
`ambient`, `booty_house`, `chicago_house`, `house`, `lofi`, `synthwave`.

A style can also be a file: a section's `style = "styles/french_disco.json"` (a name with a
`/` or ending in `.json`) is read from the song's folder, in the same shape as
`examples/styles/*.json`. `spec.style_files` lists the ones a song names, and the host hands each
one's text back with `spec.spec_add_style_text` before composing. A style the song defines
itself under `styles` wins over a file of the same name.

### 3.6 Sample sets of your own

A Sampler's `set` names a set from one of three places, tried in this order:

| source | written as | its zones |
| --- | --- | --- |
| the song's own | `sets = { my_kit = { ... } }` | pads and zones, as written |
| an SFZ file | `set = "piano/piano.sfz"` | the file's regions |
| the register | `set = "vcsl/upright_piano"` | pinned, fetched on first use |

```lua
sets = {
  kit  = { pads = { kick = "kit/kick.wav", snare = "kit/snare.wav", hat = "kit/hat.wav" },
           credit = "my kit (CC0)" },
  keys = { zones = { { file = "keys/c3.wav", root = "C3" },
                     { file = "keys/c4.wav", root = "C4", hi_velocity = 90 },
                     { file = "keys/c4_hard.wav", root = "C4", lo_velocity = 91, gain_db = -2 } },
           loop = true },                                  -- the files' own loops sustain
},
parts = { drums = { instrument = { "Sampler", set = "kit" } },
          piano = { instrument = { "Sampler", set = "keys" } } },
```

- A pad sits at its General MIDI key and plays as a one-shot. A zone answers the keys
  around its `root`: without `lo` and `hi`, each zone's keys run halfway to the next root
  above and below, within its velocity range. Zones also take `gain_db`, `one_shot` and
  `offset` (frames into the file).
- Files are read at their own rate and played at the right pitch. Nothing is resampled
  when it loads.
- SFZ reads the opcodes that place and play a sample. These are `sample`, `key`, `lokey`,
  `hikey`, `pitch_keycenter`, `lovel`, `hivel`, `volume`, `tune`, `offset`, the loop modes
  and points, and `seq_position` (zones that answer the same keys and velocities take
  turns). Headers inherit as SFZ has it, from `<global>` down to `<region>`, and paths
  come after `default_path`. Any other opcode is an `unsupported_opcode` info finding.
  Release-triggered regions are left out, and the rest of the file still plays.
- A set is keyed by its content. When a file changes, its set is declared again, and the
  song's `files` list (from `bank_declare_spec`) is what a host watches.
- The samples are yours: odawg never commits or redistributes them. `credit` is what
  `odawg credits` prints.
- A path in a style file is relative to that file's folder, so a style travels with its
  files.

Samples that live elsewhere come from **sources**: a folder at a pinned URL, with each file
pinned by SHA-256 and size. A path whose first part names a source is one of its files.

```lua
sources = {
  fashionbass = { url = "https://raw.githubusercontent.com/sfzinstruments/karoryfer.fashionbass/0703973b.../",
                  licence = "CC0-1.0", credit = "Fashionbass by Karoryfer Samples",
                  page = "https://github.com/sfzinstruments/karoryfer.fashionbass",
                  pins = "fashionbass.pins" },
},
parts = { bass = { instrument = { "Sampler", set = "fashionbass/fashionbass_clean.sfz" } } },
```

- A file is fetched into the data directory the first time a note reaches it, and only the
  zones a note's key and velocity reach are loaded, round robins included. A bassline
  fetches tens of megabytes of a library, not the whole of it.
- Every fetched file is verified against its line in the pins file: `sha256 size path`.
  A file the pins don't list is a `not_pinned` finding.
- `odawg pin SPEC` fetches what the song plays and writes the pins. It trusts whatever
  the URL serves the first time. Pin from the author's own published pins (or hashes)
  when they have them, read the licence, and look over the new lines before committing
  them.
- Treat a song's or a style's `sources` like code you run: they decide what is downloaded
  onto your machine. What odawg enforces:
  - a source's url is `https://`;
  - its name is a plain folder name (`a-z`, `0-9`, `_`, `-`);
  - its pins are a plain path beside the spec;
  - every file it names, in a zone, an SFZ or the pins, is a plain path inside the source
    (no `..`, `.`, backslash, colon or leading `/`), and an SFZ fetched from a source plays
    only that source's files.

  Anything else is a `bad_value` finding, and nothing is fetched or written.
- A licence must allow commercial use: CC0-1.0, CC-BY-3.0 or CC-BY-4.0. Anything else is a
  `licence_not_allowed` finding, and nothing is fetched.
- A style file can bring its own sources and sets, so a style, its mappings and its pins
  can be shared as one folder.

### 3.7 From a file

`from = "track.mp3"` builds a song from audio. Tempo, beats and energy come from analysis,
and `sections = { { "verse", at = 0 }, { "chorus", at = "16m" } }` names spans in the file's
own bars. `duration` cuts it at bar lines with short crossfades, removing `optional`
sections.

`from = "score.odawg"` opens a project a GUI saved. Its sections still resize.

### 3.8 Routing

A song is a graph of nodes: each track (its voices and effects), each part (its tracks
summed), each return, each bus the spec names, and the master. Edges carry sound from one
node into another at a gain, or carry a key, which is what a node's compressor or gate
listens to. Every node renders once per block, after everything that feeds it. A return
hears all of its sends in one place, and a bus sums its inputs once.

Without routing, the default graph applies. Each track goes into its part and its sends go
into their returns, then the parts and the returns go into the master. Routing is data:

```lua
buses = { glue = { effects = { { "Compressor", threshold = -18, ratio = 3 } }, to = "master" } },
parts = {
  drums = { to = "glue" },                                -- into the bus instead of the master
  keys  = { sends = { hall = -12, glue = -6 } },          -- a send goes to a return or a bus
  pad   = { key = "drums",                                -- its compressor hears the drums
            effects = { { "Compressor", threshold = -30, ratio = 8, attack = 0.001 } } },
}
```

- `to` moves a part's or a bus's output off the master and onto a bus. Sends add a path at
  a gain. `key` names the part, return or bus that a node's effects' sidechains hear.
- Where paths with different latency meet, the shorter ones are delayed to match. A part
  through a lookahead limiter still lines up with one going straight to the master.
- A loop is reported as a `routing_loop` finding. The edge that closes it is left out and
  the song still plays.
- Stems are the master's inputs: the parts in `parts` order, then the returns, then the
  buses (`render.stem_count`). A part's stem is its tracks summed. Its sends to a return
  show up in that return's stem, the way a DAW draws them.
- An exact seek starts each node as far back as its own effects and everything downstream
  of it remember. A dry track feeding a reverb return pre-rolls the reverb's tail. A dry
  track feeding a dry part pre-rolls nothing.

---

## 4. onimite's Lua API

New globals, in onimite's idiom:

```lua
local score = song { "score", ... }     -- registers clip "score" (and "score/<part>"), its sections and markers as cues
local name  = sound { "whoosh", duration = 0.5 }                 -- a one-shot: a row by name, or
local blip  = sound { { "Synth", oscillator = { type = "sine" } }, note = "E6", duration = "16n" }
-- sound{} returns a clip name, content-hashed, built once however often it plays
```

The song object's functions are dot-calls, like `beat_clock`'s:

```lua
score.duration, score.start, score.sections          -- { name, start, stop, bpm, bars } in video seconds
score.time("drop@1m"), score.time(8)                  -- seconds; a beat number works as in beat_clock
score.beat(f), score.bar(f), score.frame("drop", fps)
score.seconds("2m", "drop")                          -- a length; under a tempo map give where (default: the start)
score.snap(t, "8n")                                   -- the nearest grid point
score.pulse(f, 9)                                     -- every beat, as beat_clock's
score.pulse(f, { part = "drums", note = "kick", decay = 8 })   -- from the real events
score.section(f)                                      -- { name, progress, bar, beat }
score.hits { part = "drums", note = "clap", range = "drop" }  -- seconds
score.events { part = "lead", range = "drop" }        -- { time, note, duration, velocity }
score.note("5", "drop@2m")                            -- an in-key note, for SFX
```

Tracks don't change. A song or sound is a clip name:

```lua
audio = {
  { "score", bus = "music", ducked = true },          -- start defaults to the song's start
  { sound { "impact" }, start = score.time("drop"), bus = "sfx" },
}
```

`--track score/bass`, `audio at` (which shows the notes playing) and `show song/score` work
like they do for `say/intro`. Section names become cues, so they must be unique across the
songs in one video. `audio_energy`, `audio_spectrum` and `audio_onsets` take a
song's clip name like any other clip.

Syncing speech stays in onimite. `say_cue` doesn't change. One helper is new:

```lua
say_start(line, word, t)  -- where to start `line` so `word` lands at t (the inverse of say_cue)
```

ottis needs no change.

The video gets one new field, used from phase 2: `master = "streaming" | "podcast" |
"broadcast"`. It measures the final mix, voice and SFX included, and replaces hand-tuned
`master_gain_db` plus `limiter`.

Inside onimite:

- `script/song_api.odin` binds `song{}` and `sound{}` (like `view3d_api.odin`), and
  `std.lua` adds `say_start`.
- The adapter package `music/` (like `speech/`) caches renders by content and
  `odawg.VERSION` in `onimite/music/` in the user data folder.
- Renders run natively, in parallel per part. A song needs no fresh script load per clip,
  unlike `audio_add` functions.

---

## 5. odawg's Odin API

```odin
import spec "deps:odawg/spec"
import song "deps:odawg/song"
import render "deps:odawg/render"
import assets "deps:odawg/assets"
import device "deps:odawg/device"

s: spec.Spec
spec.spec_from_json(text, &s, &findings)          // onimite: spec.spec_from_value(lua_table_as_json, ...)
styles: [dynamic]string
spec.style_files(&s, &styles)                     // style files the song names: read each, then
spec.spec_add_style_text(&s, name, text, &findings)
host := assets.Bank_Host{root = folder}           // where the song's own files are; or the host's
                                                  // read (decoded, lent; .Declined: odawg reads it),
                                                  // text and stamp procs
assets.file_stamp(&host, path)                    // a file's identity, as sets are keyed by it
host.pinning = true                               // declare and load trusting new source files, then
updates := assets.pins_update(&bank, &s, &host, &findings)      // each source's pins text: the host writes
                                                  // u.text at u.pins_path (what odawg pin does)
files: [dynamic]string
assets.bank_declare_spec(&bank, &s, &findings, &host, &files)   // every set the Samplers name:
                                                  // the song's own, SFZ, the register's (rows only);
                                                  // a source's files fetched when bank_load reaches them
g: song.Song
song.song_from_spec(&s, &g, &bank)                // the form, the arrangement, the note table
needs: [dynamic]device.Sample_Need
song.sample_needs(&g, &needs)
assets.bank_load(&bank, needs[:], &findings, host = &host)   // only the zones the notes reach
song.seconds_from_position(&g, "drop@1m")         // the time grammar; beat_from_position, beats_from_range
song.pulse_from_seconds(&g, t, {part = "drums", note = "kick"}, 8)
song.notes_from_filter(&g, {part = "drums", note = "clap", range = "drop"}, &out)
e: render.Engine                                  // realtime: any block, from anywhere
render.engine_init(&e, &g); render.engine_seek(&e, at, exact = false); render.engine_process(&e, l, r)
render.export_song(&g, {from, to, stems}, sink)   // the stream on every core, to a sink in order
render.master_export(&g, opts, .Streaming, sink)  // measured, gained, limited, written
song.mix_init(&mix); song.append_song(&mix, &g, at, "score", window = w, duck = d); song.append_clip(&mix, clip); song.mix_end(&mix)

g.nodes, g.edges                                  // the routing: tracks, parts, returns, buses, master; edges by where they go
song.graph_order(&g)                              // each node after everything feeding it (loops: their edges)
g.regions                                         // where each part is triggered: { part, start, stop, source }
t: render.Table                                   // what is read at random: peaks, energy, spectrum per step
render.table_init(&t, &g, .Peaks, part, 256, 1)   // rows only where the part sounds (its regions and tails)
render.tables_build(&g, {&t, &u})                 // one streamed export fills them all
render.table_row(&t, step)                        // nil where it is silent
song.command_apply(&g, {.Pad_Gain_Step, "drums/kick", 3})   // the one place a song changes
render.table_stale(&g, &t)                        // its source changed: build it again
```

A composed song is its parts' regions: each play entry (or style entry) over the range it
was expanded in, each transition's sound. A part sounds only in its regions and their tails
(release, the effect chain's and the returns' tails, overlapping ones merged), so what is
measured of it takes that shape: a table has rows only there, none for silence. A table holds
what was measured (min and max per bucket, a frame's energy or magnitudes), never samples,
and is filled from one streamed export on every core whatever its segments.

Edits are command rows (`COMMAND_KINDS`: `Part_Gain_Set`, `Part_Pan_Set`, `Part_Mute_Set`,
`Pad_Gain_Set`, `Param_Set`, `Master_Gain_Set`, and their `_Step`s), each kind's row saying
what it touches; `command_apply` moves the versions of the part it changed and of the mix,
so tables of other parts stay good. "Make the kick louder" is `{.Pad_Gain_Step,
"drums/kick", 3}`.

### The project document (`.odawg`, JSON, stable ids)

The project contains:

- the tempo map (steps and ramps), the meter map, sections, markers;
- tracks and returns, each with devices (`class` plus params) and sends;
- clips, with `lock = "beats" | "seconds"` and `anchor = { section | marker, offset }`;
- automation per param path (`bass/filter/frequency`);
- `made_by` on generated clips, linking each back to the spec entry.

A generated part becomes **loop clips anchored to its section**, with fills anchored to the
section's end. Resizing a section is then a plain edit to the project, with no
re-composing. That's how a GUI retimes a song.

### Ops (the only way to change a project)

```odin
odawg.apply(&project, op)   // set, add, remove, move, resize_section, set_tempo, ...
odawg.undo(&project)
odawg.redo(&project)
odawg.subscribe(&project, proc)
```

### Engine

- The engine processes in blocks with sample-accurate events, so offline render, realtime
  playback and any block size all give the same samples.
- Tracks render in parallel and are summed in a fixed order.
- Realtime output is `deps:odawg/sdl`. onimite's preview plays through it in phase 3.

### CLI

`tools/odawg` uses onimite's verbs on a JSON spec or a `.odawg` project:

```sh
odawg render song.json -o x.wav
odawg timeline song.json
odawg show song.json parts/bass
odawg at song.json drop@1m
odawg inspect song.json
odawg audio analyze song.json
odawg fetch
odawg credits song.json
```

Every command takes `--json`.

---

## 6. Sound quality

1. **Samples.** A `Sampler` with multisamples, velocity layers and round robins, a
   `DrumKit`, and a fetched library (§7). This is the largest single gain.
2. **DSP.**
   - band-limited oscillators (polyBLEP, mipmapped wavetables), including `fat*` unison;
   - zero-delay-feedback filters;
   - oversampled `Distortion`;
   - smoothing on every param.
3. **Effects.** Algorithmic `Reverb` on shared `returns`, delays, `Chorus`, tape
   saturation, `EQ3` and a parametric EQ, a glue `Compressor`, and a lookahead true-peak
   `Limiter`.
4. **Playing.** `swing`, `humanize` (deterministic, from `hash`), voice leading, strums, and
   bass legato.
5. **Styles.**
   - a register map per role;
   - variation every 4 or 8 bars;
   - transitions recomputed whenever lengths change;
   - `room` (thinner parts and an EQ pocket under the voice).
6. **Mix and master.** A mix template per style, and `master` presets measured on the final
   mix.
7. **Later:** CLAP plugin hosting. Plugin renders are frozen and cached, so determinism
   holds.

Checks that stand in for listening:

| finding | what it catches |
| --- | --- |
| `true_peak`, `clipping`, `over_limited` | levels |
| `tonal_balance` | against the style's curve |
| `masking`, `mud` | parts fighting over one band |
| `mono_compat` | stereo that cancels in mono |
| `energy_arc` | the measured shape doesn't follow the declared `energy` |
| `repetition` | a bar looping too long with no variation |
| `off_key`, `note_range` | notes |
| `silent_part` | a part that makes no sound |
| `no_events` | `pulse`/`hits` read a part with nothing in that range (a style without it) |
| `start_unreachable`, `duration_unreachable` | a timing constraint that can't be met; lists each section's minimum |

There's also `odawg inspect --reference ref.mp3`, and `--previews` for a 10 s clip per
section that the user listens to.

---

## 7. Licensing (commercial use)

- **Synthesis is always clean.** What odawg's DSP makes belongs to whoever made it. The
  synthesized presets are the default.
- **The fetched library is CC0 by default.** No attribution, no restrictions.
  `odawg fetch --library cc-by` adds CC-BY packs, which need credit.
- **Excluded:** NC (non-commercial), ND (no derivatives) and SA (share-alike: unclear for
  samples inside a mixed work).
- **Every sample carries its licence, source and credit line in the pins file** (`assets/`,
  like ottis's pins).
- `odawg credits` lists what a song uses. `onimite credits` should merge that with `say`'s
  Kyutai credit into one list for the video's description.
- **`video { license = "commercial" }`, shared with `say`,** turns the warnings into errors:
  `tts_noncommercial` (cosette, jean) and `sample_noncommercial` both refuse to render.
- I'm not a lawyer. Check each pack's licence at its source before adding it to the pins.

---

## 8. Review of the first draft (`DAW-API.md`)

Kept:

- determinism and seeds;
- musical time and markers;
- stems;
- a stable `describe` (now `show`/`timeline --json`);
- a CLI.

Changed:

| Draft | Why it changed | Now |
| --- | --- | --- |
| The engine doesn't mix; onimite owns mixing and LUFS | A DAW backend has to mix, and the master target needs the voice and SFX | odawg mixes (phase 2); onimite places |
| A Lua session file is the document, rewritten by the GUI | Lua can't round-trip, and siblings don't carry Lua | A data spec, a JSON project, and onimite's binding |
| `at = 2.5` is beats in one place and seconds in another | Ambiguous | A number is seconds; musical time is a string |
| Its own names (`osc`, `comp`, `dist`) | Consistency | Tone.js / Web Audio names |
| Generators attached to tracks | Nothing to resize or restyle | Sections, play entries, anchored loop clips |
| Per-sample Lua instruments | Not realtime, and no Lua in odawg | onimite's `audio_add` clips as `Sampler`/`Player` sources |
| No data back to the picture | Agents rebuild kick times by hand | `pulse`, `hits`, `events`, `section` |

---

## 9. Phases

1. **odawg makes music for onimite.**
   - odawg: spec, compose, project, offline engine, the `synth.lua` presets, band-limited
     synths, `Sampler` with a CC0 kit and piano, `Reverb`/delay/`Compressor`/`Limiter`, four
     styles, checks, the CLI.
   - onimite: `song{}`, `sound{}`, `say_start`, and the song-to-cues link.
   - Port `why_onimite` and `onimite_saga`. Gate: the presets match the old stems, and
     every cue holds.
2. **odawg mixes for onimite.**
   - `video{ audio, buses, ducked, limiter }` builds an odawg graph, and `video { master }`
     arrives.
   - `audio analyze/at/onsets` run on odawg.
   - `room` uses the voice bus.
   - Port every example, delete `common/synth.lua`, `common/tempo.lua` and the `sfx.lua`
     helpers, and rewrite `references/audio.md`.
3. **The DAW app.**
   - Realtime transport through `odawg/sdl` (onimite's preview first), ops, undo, the C
     ABI.
   - `onimite audio export video.lua [--song score] -o x.odawg`: one song for hand-tuning
     (reopened with `from =`), or the whole soundtrack, voice and SFX included.
   - CLAP hosting, MIDI in, recording.

---

## 10. Decisions

| # | Decision | Why (WORKFLOWS.md has the walkthroughs) |
| --- | --- | --- |
| 1 | A bare number is seconds; musical time is a string; conversions keep `beat_clock`'s signatures | onimite, Tone.js and Web Audio already agree. In the walkthroughs every beat number became a string anyway. |
| 2 | The project is JSON | Agreed |
| 3 | No Lua in odawg. onimite binds it; a GUI and the CLI use the Odin API and JSON | Matches every sibling. The spec is data, so nothing in odawg needs a script. |
| 4 | odawg mixes and onimite places | `master`, `room`, ducking and export to the DAW all need the voice and SFX in the same graph as the music |
| 5 | Synthesis first; a CC0 library; CC-BY opt-in with credits; no NC/ND/SA; `license = "commercial"` | Commercial users |
| 6 | No reel and no nested projects. Each song is a clip with its own tempo, placed with onimite's existing `start`, `fade_*` and `curve`. | That's standard practice: one tempo map per project, and other songs are clips that keep their own tempo (Ableton's warp, Logic's Smart Tempo, every video editor). REAPER's subprojects are the exception. |
