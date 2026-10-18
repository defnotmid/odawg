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
	{"styles/house.json", #load("../examples/styles/house.json", string), true},
	{"styles/lofi.json", #load("../examples/styles/lofi.json", string), true},
	{"instruments/classic.json", #load("../examples/instruments/classic.json", string), false},
	{"instruments/tb303.json", #load("../examples/instruments/tb303.json", string), false},
	{"instruments/808_bass.json", #load("../examples/instruments/808_bass.json", string), false},
	{"machines/808.json", #load("../examples/machines/808.json", string), false},
	{"machines/909.json", #load("../examples/machines/909.json", string), false},
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
