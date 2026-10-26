package odawg_render

import base "../base"
import spec "../spec"

// The example files (examples/), handed to a spec as a host reads them: the
// styles, the instruments and the machines at the paths a song in examples/
// names them by, and the classic instruments by name.
@(private = "file")
EXAMPLE_FILES := [?]struct {
	path, text: string,
	style:      bool,
} {
	{"styles/acid_house.json", #load("../examples/styles/acid_house.json", string), true},
	{"styles/ambient.json", #load("../examples/styles/ambient.json", string), true},
	{"styles/booty_house.json", #load("../examples/styles/booty_house.json", string), true},
	{"styles/chicago_house.json", #load("../examples/styles/chicago_house.json", string), true},
	{"styles/house.json", #load("../examples/styles/house.json", string), true},
	{"styles/lofi.json", #load("../examples/styles/lofi.json", string), true},
	{"styles/synthwave.json", #load("../examples/styles/synthwave.json", string), true},
	{"instruments/classic.json", #load("../examples/instruments/classic.json", string), false},
	{"instruments/tb303.json", #load("../examples/instruments/tb303.json", string), false},
	{"instruments/808_bass.json", #load("../examples/instruments/808_bass.json", string), false},
	{"instruments/909_bass.json", #load("../examples/instruments/909_bass.json", string), false},
	{"instruments/effects.json", #load("../examples/instruments/effects.json", string), false},
	{"machines/808.json", #load("../examples/machines/808.json", string), false},
	{"machines/909.json", #load("../examples/machines/909.json", string), false},
	{"machines/linn_80s.json", #load("../examples/machines/linn_80s.json", string), false},
	{"machines/tight_modern.json", #load("../examples/machines/tight_modern.json", string), false},
	{"machines/crunch_bap.json", #load("../examples/machines/crunch_bap.json", string), false},
	{"machines/cinematic_perc.json", #load("../examples/machines/cinematic_perc.json", string), false},
}

add_examples :: proc(s: ^spec.Spec, findings: ^base.Findings) {
	for f in EXAMPLE_FILES {
		if f.style {
			spec.spec_add_style_text(s, f.path, f.text, findings)
		} else {
			spec.spec_add_instrument_text(s, f.path, f.text, findings)
		}
	}
	append(&s.instrument_includes, "instruments/classic.json")
}

// The example songs, as their texts.
EXAMPLE_SONGS := [?]struct {
	name, text: string,
} {
	{"acid_house", #load("../examples/acid_house.json", string)},
	{"booty_house", #load("../examples/booty_house.json", string)},
	{"chicago_house", #load("../examples/chicago_house.json", string)},
	{"explainer", #load("../examples/explainer.json", string)},
	{"lofi_live", #load("../examples/lofi_live.json", string)},
	{"pop", #load("../examples/pop.json", string)},
}
