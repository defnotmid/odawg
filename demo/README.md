# odawg demo

A 76 second showcase of odawg, music included: 1920x1080, 60 fps, 126
BPM. It is an [onimite](https://github.com/defnotmid/onimite) script (Odin +
Lua video framework, which plays its songs with odawg), not part of odawg's
build. Its music is onimite's disco example, the song as it is; the picture
shows what odawg does with it. The render, `demo.mp4`, is not in the
repository: make it with the onimite release binary
([releases](https://github.com/defnotmid/onimite/releases), v0.1.0;
`onimite update` keeps it current), from odawg's folder:

```sh
onimite render demo/video.lua -o demo/demo.mp4 --qp 22   # the render
onimite preview demo/video.lua                           # play, hot reload on save
build/odawg render demo/media/song.json -o song.wav      # the song alone, by odawg's CLI
```

The first run fetches the samples the notes reach into odawg's data folder
(`$ODAWG_DATA`, else `odawg/` in the user data folder), each checked against
its pin; after that it renders offline.

| bars | scene | what |
| --- | --- | --- |
| 1-2 | Title | the dog at its drum machine, its pads lighting on the 909's notes, then the wordmark on the second beat |
| 3-4 | Data | `media/song.json`'s top-level keys, read from the file, one a sixteenth: the scalars with their values, the tables folded with how many they hold |
| 5-8 | Form | the six section lines, each drawing its block of bars; the notes the parts make of them |
| 9-12 | Steps | the groove's 909 row: each `steps` string beside the sixteen steps it makes, flashing as the song plays them |
| 13-14 | Bass | the bass line's `notes` string a token a sixteenth, over the notes odawg composed from it |
| 15-16 | Lane | the loop's filter lane over the whole song, its points from the file, the cutoff counting up into the hook |
| 17-20 | Rows | the talk box's row as a graph: its nodes and the wires its fields name, the sound running through it on each note |
| 21-24 | Layers | the three rows that stack a voice of the song's own over a library's recording |
| 25-28 | Pins | the four sources (repository at a commit, licence) and every line of their pins rolling past |
| 29-32 | Notes | every part's notes scrolling under the playhead |
| 33-36 | Checks | each part's LU under the mix in every section, over its role's band |
| 37-38 | CLI | `odawg render` on the same file, and what it printed |
| 39-40 | Outro | the dog and the wordmark over the song's spectrum, fading with it |

Along the bottom, under every scene, runs the loop's filter lane
(`buses/loop/Filter/frequency`, the automation the engine plays, read with
`score.automation`), with the section and the cutoff now; the room behind the
scenes brightens as that filter opens. The picture pumps on the 909's kick
and flashes on its crashes, read from the song's notes (`score.pulse`).

## Facts on screen

Every number is in `facts.lua` with its source. What the song and its pins
hold is counted from them when the script loads; what a render measured was
measured by odawg's CLI at v0.1.0 (6d064ed) on `media/song.json`, 2026-11-17.

| on screen | source |
| --- | --- |
| 40 bars → 3,786 notes on 9 parts; the 909's 764 | counted from the song (`score.events`), the same as `odawg timeline demo/media/song.json` |
| the talk box's 12 nodes | counted from its row in `media/song.json` |
| 91 files, 95.0 MB | counted from `media/pins/*.pins` (`odawg pin` writes them: what the notes reach) |
| each part's LU under the mix, per section | `odawg inspect demo/media/song.json --balance` (no `role_balance` finding) |
| each role's band and the 1 LU of slack | `check/checks.odin`, `ROLE_TABLE` and `ROLE_SLACK` |
| -14.0 LUFS, -1.0 dBTP | `odawg analyze demo/media/song.json --master streaming` |
| `song.wav: 78.55s, -14.0 LUFS, -1.0 dBTP` | what `odawg render demo/media/song.json -o song.wav --master streaming` printed |

Mix in the video (`onimite audio analyze`, v0.1.0): -14.0 LUFS integrated,
-2.0 dBTP true peak under onimite's default ceiling, 2.9 LU range; the scenes
from -16.0 LUFS (title: the kick alone) to -12.8 (the hook). It plays the
song as `examples/disco/video.lua` does: `master_gain_db = 6`, the last 1.5
s faded.

## Files

`video.lua` sets up the video, the beat-synced glitch cuts, the HUD and the
filter lane; `scenes/` holds one file per scene; `track.lua` loads the song;
`timeline.lua` reads from it on which beat each scene starts; `beat.lua` is
the clock and easing on the song's beat; `facts.lua` the numbers on screen;
`ui.lua` the palette, type, the backdrop and the dog.

## The soundtrack

`media/song.json` is onimite's `examples/disco/media/song.json` (v0.1.0)
byte for byte but for two paths: the library rows it names
(`instruments/effects.json`, `instruments/synths.json`) point at copies in
`media/instruments/`, taken from onimite's skill library at the same tag,
so the song travels alone and odawg's CLI renders it from here. Its
`machines/909.json` and `pins/` are the example's.

French touch, hard and electronic, in B-flat minor at 126: one loop (a
driven synth bass with Karoryfer's fingered bass in it, funk guitar,
saw-and-piano stabs, a string pad) through a grain of distortion and one
low-pass whose cutoff is the arrangement, a talk-box lead of its own, the
violin section and an arpeggio over it, everything ducking under the 909
kick. `examples/disco/README.md` in onimite tells its parts and choices.

## Media and credits

- `dog.svg`: odawg's mascot (`art/logo.svg`), MIT like odawg.
- `song.json`, `machines/909.json`, `instruments/*.json`, `pins/`: from
  onimite v0.1.0, MIT.
- Fonts (SIL Open Font License 1.1, `media/OFL.txt` with each one's
  copyright), copied from onimite's examples: Bebas Neue, Space Grotesk,
  JetBrains Mono.
- The song's instruments, all CC0 1.0, fetched when it plays and never kept
  here, each file checked against its pin:
  [Fashionbass](https://github.com/sfzinstruments/karoryfer.fashionbass) and
  [Emilyguitar](https://github.com/sfzinstruments/karoryfer.emilyguitar) by
  Karoryfer Samples (D. Smolken);
  [VS Chamber Orchestra 2: Community Edition](https://github.com/sgossner/VSCO-2-CE)
  and the [Versilian Community Sample Library](https://github.com/sgossner/VCSL)
  by Versilian Studios (the upright piano through odawg's own VCSL set).
