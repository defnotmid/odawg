// assets: the sample sets a Sampler plays, as a register: every source a row
// (where its files come from, its licence as the source states it, the
// credit line), every set a row (its source, its zones), every zone a row
// (which file plays which keys and velocities) and every file a row (its
// pin: SHA-256 and size). Sets are downloaded into the data directory the
// first time a song uses them, verified against their pins, decoded and
// resampled into a device.Bank. The repository holds the register only, never
// audio.
//
// Licences: commercial use must be allowed. CC0 is the default; CC-BY is
// allowed with its credit line (`odawg credits`); NC, ND, SA and custom
// "free for personal use" terms are never registered. Every source's licence
// was checked at the source on the date its row gives.
package odawg_assets

import base "../base"

Licence :: enum u8 {
	CC0_1_0,
	CC_BY_3_0,
	CC_BY_4_0,
}

Licence_Row :: struct {
	spdx:            string,
	url:             string,
	credit_required: bool,
}

LICENCE_TABLE := [Licence]Licence_Row {
	.CC0_1_0   = {"CC0-1.0", "https://creativecommons.org/publicdomain/zero/1.0/", false},
	.CC_BY_3_0 = {"CC-BY-3.0", "https://creativecommons.org/licenses/by/3.0/", true},
	.CC_BY_4_0 = {"CC-BY-4.0", "https://creativecommons.org/licenses/by/4.0/", true},
}

Source :: enum u8 {
	VCSL,
	VSCO2,
	Osiris,
	Growlybass,
	Virtuosity,
}

Source_Row :: struct {
	name:    string, // its directory under the data directory
	title:   string,
	url:     string, // a file's URL is this and its (percent-encoded) path: raw files at a pinned commit
	page:    string, // the source's own page
	licence: Licence,
	credit:  string, // the line `odawg credits` prints
	quote:   string, // the licence statement, verbatim
	quoted:  string, // where the statement was read
	checked: string, // when
}

SOURCE_TABLE := [Source]Source_Row {
	.VCSL = {
		name = "vcsl",
		title = "Versilian Community Sample Library",
		url = "https://raw.githubusercontent.com/sgossner/VCSL/c1ea7bcc3c7309650ab0da9d15c9cd1fbc4a4c7e/",
		page = "https://github.com/sgossner/VCSL",
		licence = .CC0_1_0,
		credit = "Versilian Community Sample Library (VCSL) by Versilian Studios LLC, CC0 1.0",
		quote = "This collection is under a Creative Commons 0 license. Essentially it's Public Domain- you can do whatever you want with these sounds (even make commercial software), no royalties, no credit, no special terms.",
		quoted = "https://github.com/sgossner/VCSL (README.md; LICENSE is CC0 1.0 Universal)",
		checked = "2026-10-17",
	},
	.VSCO2 = {
		name = "vsco2",
		title = "VS Chamber Orchestra 2: Community Edition",
		url = "https://raw.githubusercontent.com/sgossner/VSCO-2-CE/440300901dfe9275fd84e0b7763af1f8443ae62e/",
		page = "https://github.com/sgossner/VSCO-2-CE",
		licence = .CC0_1_0,
		credit = "VS Chamber Orchestra 2: Community Edition by Versilian Studios LLC (Sam Gossner, Simon Dalzell, Elan Hickler), CC0 1.0",
		quote = "The library is under a Creative Commons 0 (i.e. public domain) license. That's right, you can download 3 GB of samples for free with no rules, no royalties, no limits on how or when you can use it",
		quoted = "http://vis.versilstudios.net/vsco-community.html (and the repository's LICENSE, CC0 1.0 Universal)",
		checked = "2026-10-17",
	},
	.Osiris = {
		name = "osiris",
		title = "Osiris Piano",
		url = "https://raw.githubusercontent.com/sfzinstruments/Osiris_Piano/18c6afccb60cff458edbf7c394571783e074e1e9/",
		page = "https://github.com/sfzinstruments/Osiris_Piano",
		licence = .CC0_1_0,
		credit = "Osiris Piano by Versilian Studios and Karoryfer Samples, CC0 1.0",
		quote = "All our free sample libraries are under a Creative Commons Zero license. Older downloads may include a less permissive license, but we changed that and now they are all CC0.",
		quoted = "https://shop.karoryfer.com/pages/free-samples (and the repository's LICENSE, CC0 1.0 Universal; beta_notes.txt: \"CC0 license added.\")",
		checked = "2026-10-17",
	},
	.Growlybass = {
		name = "growlybass",
		title = "Growlybass",
		url = "https://raw.githubusercontent.com/sfzinstruments/karoryfer.growlybass/4f483268fc66b5a6d5781d421c0d11b8d08d3fc6/",
		page = "https://github.com/sfzinstruments/karoryfer.growlybass",
		licence = .CC0_1_0,
		credit = "Growlybass by Karoryfer Samples, CC0 1.0",
		quote = "All our free sample libraries are under a Creative Commons Zero license. Older downloads may include a less permissive license, but we changed that and now they are all CC0.",
		quoted = "https://shop.karoryfer.com/pages/free-samples (and the repository's LICENSE, CC0 1.0 Universal)",
		checked = "2026-10-17",
	},
	.Virtuosity = {
		name = "virtuosity",
		title = "Virtuosity Drums",
		url = "https://raw.githubusercontent.com/sfzinstruments/virtuosity_drums/9f04cf9a734527edfbb0a4eee1f674e45bbf71bc/",
		page = "https://github.com/sfzinstruments/virtuosity_drums",
		licence = .CC0_1_0,
		credit = "Virtuosity Drums by Versilian Studios and Karoryfer Samples (drummer Austin McMahon), CC0 1.0",
		quote = "All our free sample libraries are under a Creative Commons Zero license. Older downloads may include a less permissive license, but we changed that and now they are all CC0.",
		quoted = "https://shop.karoryfer.com/pages/free-samples (and the repository's LICENSE, CC0 1.0 Universal)",
		checked = "2026-10-17",
	},
}

// A set: an instrument or a kit, named `source/instrument`, playing a run
// of ZONE_TABLE; gain_db brings its loudest sample to -6 dBFS, and
// level_db puts it where a synth preset playing the same part sits (chords,
// a bass line or a beat at the default velocity, measured beside the
// presets in LUFS), so a sampled part needs no more level than a synth one.
Set_Row :: struct {
	name:     string,
	source:   Source,
	about:    string,
	gain_db:  f32,
	level_db: f32,
	zones:    base.Span, // into ZONE_TABLE
}

// A file of the set's source answering keys and velocities (MIDI,
// inclusive), recorded at `root`; a one-shot plays to its end whatever the
// gate. Loops come from the file (a WAV's smpl chunk).
Zone_Row :: struct {
	path:        string,
	lo_key:      u8,
	hi_key:      u8,
	root:        f32,
	lo_velocity: u8,
	hi_velocity: u8,
	gain_db:     f32,
	one_shot:    bool,
}

File_Row :: struct {
	source: Source,
	path:   string,
	sha256: string,
	size:   i64,
}

set_row_from_name :: proc(name: string) -> (^Set_Row, bool) {
	for &s in SET_TABLE {
		if s.name == name {
			return &s, true
		}
	}
	return nil, false
}

file_index_from_path :: proc(source: Source, path: string) -> (i32, bool) {
	for f, i in FILE_TABLE {
		if f.source == source && f.path == path {
			return i32(i), true
		}
	}
	return -1, false
}

set_zones :: proc(s: ^Set_Row) -> []Zone_Row {
	return ZONE_TABLE[s.zones.first:base.span_end(s.zones)]
}
