// The odawg mascot: a 32x32 pixel-art dog (a dawg) in headphones at a drum
// machine, in the family of onimite's Pip, odecs' turntable, ovg's
// chameleon and ottis' Ottis. Writes an SVG whose parts are groups a script
// shows or hides by id (onimite: svg{ overrides = { pad_1 = { visible = true } } }),
// so the dog can play along with a song's own hits:
//
//   body          outline, fur, the patch round one eye, muzzle and nose, the
//                 floppy ears, the headphones, the paws and the drum machine
//                 with its four pads unlit (on)
//   eyes_open     eyes with a shine (on)      eyes_closed  a happy blink, in the groove
//   mouth_tongue  open, the tongue out (on)   mouth_smile  a small closed smile
//   pad_1..pad_4  each pad lit, the 808's red, orange, yellow and white (off):
//                 light one on each hit (song.hits { part = "drums", note = "kick" })
//   notes         two notes rising from the headphones (off)
//
// Also writes the project logo as PNGs, scaled without smoothing:
//
//   odin run tools/mascot -- art   (art/logo.svg, logo.png 256 px, logo_32x32.png)
package mascot

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import stbi "vendor:stb/image"

W :: 32
H :: 32

Grid :: [H][W]u8 // palette keys, '.' empty

color :: proc(c: u8) -> string {
	switch c {
	case 'O': return "#2a1a14" // outline
	case 'B': return "#d79a52" // fur
	case 'D': return "#a8692f" // fur shade
	case 'H': return "#efc07e" // fur highlight
	case 'C': return "#f6e4c0" // muzzle and chest
	case 'c': return "#dcc39a" // muzzle shade
	case 'A': return "#7a4526" // ears
	case 'a': return "#5a301a" // ear shade
	case 'E': return "#1b1220" // eyes, nose
	case 'W': return "#ffffff" // shines
	case 'K': return "#ff9db4" // cheeks
	case 'M': return "#5a1f24" // mouth
	case 'T': return "#ff7a8a" // tongue
	case 't': return "#d94470" // tongue shade
	case 'P': return "#2b2d42" // headphone band
	case 'p': return "#4a4e6e" // band highlight
	case 'R': return "#d4271d" // ear cups
	case 'r': return "#a51b13" // cup shade
	case 'h': return "#ff6b5e" // cup highlight
	case 'G': return "#d4d6e4" // the machine's top
	case 'g': return "#8c8fa8" // its shade
	case 'N': return "#3a3c50" // its panel
	case 'n': return "#262838" // panel shade
	case 'L': return "#ff4b3a" // the LED
	// the pads, unlit and lit
	case '1': return "#a83a2b"
	case '2': return "#bf6a2e"
	case '3': return "#bfa13a"
	case '4': return "#b8b4a4"
	case '5': return "#ff5a44"
	case '6': return "#ffa14a"
	case '7': return "#ffe36a"
	case '8': return "#fff8e8"
	case 'S': return "#5eead4" // notes
	case 's': return "#22b8cf"
	}
	return "#ff00ff"
}

empty :: proc() -> (g: Grid) {
	for &row in g do for &p in row do p = '.'
	return
}

put :: proc(g: ^Grid, x, y: int, c: u8) {
	if 0 <= x && x < W && 0 <= y && y < H do g[y][x] = c
}

in_ellipse :: proc(x, y: int, cx, cy, rx, ry: f64) -> (bool, f64, f64) {
	u := (f64(x) + 0.5 - cx) / rx
	v := (f64(y) + 0.5 - cy) / ry
	return u * u + v * v <= 1, u, v
}

// Fills an ellipse with `base`: `shade` along the lower right rim.
fill :: proc(g: ^Grid, cx, cy, rx, ry: f64, base, shade: u8) {
	for y in 0 ..< H do for x in 0 ..< W {
		inside, u, v := in_ellipse(x, y, cx, cy, rx, ry)
		if !inside do continue
		c := base
		if u * u + v * v > 0.6 && u * 0.5 + v * 0.85 > 0.35 do c = shade
		put(g, x, y, c)
	}
}

// Outlines every filled pixel's empty 4-neighbours.
outline :: proc(g: ^Grid) {
	src := g^
	for y in 0 ..< H do for x in 0 ..< W {
		if src[y][x] != '.' do continue
		for d in ([4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
			nx, ny := x + d.x, y + d.y
			if 0 <= nx && nx < W && 0 <= ny && ny < H && src[ny][nx] != '.' && src[ny][nx] != 'O' {
				g[y][x] = 'O'
				break
			}
		}
	}
}

// Draws `fg` over `g`, outlining fg's shapes against everything else.
over :: proc(g: ^Grid, fg: Grid) {
	shape := fg
	outline(&shape)
	for y in 0 ..< H do for x in 0 ..< W do if shape[y][x] != '.' do g[y][x] = shape[y][x]
}

// The pads: four, four pixels wide, two rows tall, along the machine's panel.
PAD_X :: [4]int{5, 11, 17, 23}
PAD_Y :: 28

draw_body :: proc() -> Grid {
	g := empty()

	// Shoulders, cut by the machine in front, a pale chest.
	shoulders := empty()
	fill(&shoulders, 16, 27.5, 10.5, 6.5, 'B', 'D')
	for y in 0 ..< H do for x in 0 ..< W {
		if inside, _, _ := in_ellipse(x, y, 16, 29.5, 5, 6); inside && shoulders[y][x] != '.' do put(&shoulders, x, y, 'C')
	}
	over(&g, shoulders)

	// The floppy ears, hanging from under the ear cups.
	ears := empty()
	fill(&ears, 6.2, 16.8, 2.6, 5.0, 'A', 'a')
	fill(&ears, 25.8, 16.8, 2.6, 5.0, 'A', 'a')
	over(&g, ears)

	// The head: a broad skull, a dark patch round one eye, a pale muzzle
	// shaded at the jaw, a big black nose with a shine, cheeks, light on
	// the crown.
	head := empty()
	fill(&head, 16, 12, 9.0, 7.6, 'B', 'D')
	for y in 0 ..< H do for x in 0 ..< W {
		if inside, _, _ := in_ellipse(x, y, 20.2, 9.8, 2.7, 2.3); inside do put(&head, x, y, 'A')
	}
	for y in 0 ..< H do for x in 0 ..< W {
		inside, _, v := in_ellipse(x, y, 16, 15.3, 4.6, 3.5)
		if inside do put(&head, x, y, 'c' if v > 0.55 else 'C')
	}
	for p in ([?][2]int{{12, 5}, {13, 5}, {14, 5}, {10, 6}, {11, 6}, {9, 7}, {10, 7}, {8, 9}}) do put(&head, p.x, p.y, 'H')
	for p in ([?][2]int{{9, 14}, {10, 14}, {21, 14}, {22, 14}}) do put(&head, p.x, p.y, 'K')
	for p in ([?][2]int{{14, 12}, {15, 12}, {16, 12}, {17, 12}, {14, 13}, {15, 13}, {16, 13}, {17, 13}, {15, 14}, {16, 14}}) do put(&head, p.x, p.y, 'E')
	put(&head, 15, 12, 'W')
	over(&g, head)

	// The headphones: a band over the crown, a red cup over each ear.
	phones := empty()
	for y in 0 ..< 10 do for x in 0 ..< W {
		outer, u, v := in_ellipse(x, y, 16, 12, 10.8, 10.0)
		inner, _, _ := in_ellipse(x, y, 16, 12, 9.0, 8.0)
		if outer && !inner do put(&phones, x, y, 'p' if u < -0.1 && v < -0.85 else 'P')
	}
	for cx in ([2]int{4, 23}) {
		for y in 8 ..< 15 do for x in cx ..< cx + 5 {
			if (y == 8 || y == 14) && (x == cx || x == cx + 4) do continue
			c := u8('R')
			if x == cx + 4 || y == 14 do c = 'r'
			put(&phones, x, y, c)
		}
		put(&phones, cx + 1, 9, 'h')
		put(&phones, cx + 1, 10, 'h')
	}
	over(&g, phones)

	// The drum machine across the bottom: a silver top edge, a dark panel
	// with knobs, an LED and the four pads (unlit), and paws on its top.
	machine := empty()
	for y in 24 ..< H do for x in 2 ..< 30 {
		c := u8('N')
		if y == 24 do c = 'G'
		else if y == 25 do c = 'g'
		else if x == 29 || y == 31 do c = 'n'
		put(&machine, x, y, c)
	}
	for x := 5; x < 27; x += 3 do put(&machine, x, 26, 'g')
	put(&machine, 26, 26, 'L')
	unlit := [4]u8{'1', '2', '3', '4'}
	for px, i in PAD_X do for y in PAD_Y ..< PAD_Y + 2 do for x in px ..< px + 4 do put(&machine, x, y, unlit[i])
	over(&g, machine)

	paws := empty()
	for px in ([2]int{8, 21}) {
		for y in 22 ..< 25 do for x in px ..< px + 3 do put(&paws, x, y, 'B')
		put(&paws, px, 22, 'H')
		put(&paws, px + 2, 24, 'D')
		put(&paws, px + 1, 24, 'D')
	}
	over(&g, paws)
	return g
}

draw_eyes :: proc() -> (open, closed: Grid) {
	open, closed = empty(), empty()
	for ex in ([2]int{11, 19}) {
		for y in 9 ..< 11 do for x in ex ..< ex + 2 do put(&open, x, y, 'E')
		put(&open, ex, 9, 'W')
		// a happy closed eye: a small arch
		put(&closed, ex - 1, 10, 'E')
		put(&closed, ex, 9, 'E')
		put(&closed, ex + 1, 9, 'E')
		put(&closed, ex + 2, 10, 'E')
	}
	return
}

draw_mouths :: proc() -> (smile, tongue: Grid) {
	smile, tongue = empty(), empty()
	// a "w" under the nose
	for p in ([?][2]int{{13, 15}, {14, 16}, {15, 15}, {16, 15}, {17, 16}, {18, 15}}) do put(&smile, p.x, p.y, 'M')
	// open, the tongue hanging out
	for p in ([?][2]int{{13, 15}, {14, 15}, {15, 15}, {16, 15}, {17, 15}, {18, 15}, {13, 16}, {18, 16}, {14, 17}, {17, 17}}) do put(&tongue, p.x, p.y, 'M')
	for p in ([?][2]int{{14, 16}, {15, 16}, {16, 16}, {17, 16}, {15, 17}, {16, 17}, {15, 18}, {16, 18}}) do put(&tongue, p.x, p.y, 'T')
	put(&tongue, 16, 18, 't')
	put(&tongue, 16, 17, 't')
	return
}

draw_pads :: proc() -> (pads: [4]Grid) {
	lit := [4]u8{'5', '6', '7', '8'}
	for px, i in PAD_X {
		pads[i] = empty()
		for y in PAD_Y ..< PAD_Y + 2 do for x in px ..< px + 4 do put(&pads[i], x, y, lit[i])
		put(&pads[i], px, PAD_Y, 'W')
	}
	return
}

// Two eighth notes rising from the right cup.
draw_notes :: proc() -> Grid {
	g := empty()
	for y in 1 ..< 5 do put(&g, 30, y, 'S')
	put(&g, 31, 1, 'S')
	put(&g, 31, 2, 'S')
	for p in ([?][2]int{{28, 4}, {29, 4}, {28, 5}, {29, 5}}) do put(&g, p.x, p.y, 'S')
	for y in 3 ..< 6 do put(&g, 3, y, 's')
	put(&g, 4, 3, 's')
	for p in ([?][2]int{{1, 5}, {2, 5}, {1, 6}, {2, 6}}) do put(&g, p.x, p.y, 's')
	return g
}

Layer :: struct {
	name: string,
	grid: Grid,
	on:   bool,
}

svg :: proc(layers: []Layer) -> string {
	b := strings.builder_make()
	fmt.sbprintf(&b, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d" shape-rendering="crispEdges">`, W, H, W * 8, H * 8)
	strings.write_byte(&b, '\n')
	for l in layers {
		fmt.sbprintf(&b, `<g id="%s"%s>`, l.name, "" if l.on else ` display="none"`)
		for y in 0 ..< H do for x in 0 ..< W {
			c := l.grid[y][x]
			if c == '.' do continue
			fmt.sbprintf(&b, `<rect x="%d" y="%d" width="1" height="1" fill="%s"/>`, x, y, color(c))
		}
		strings.write_string(&b, "</g>\n")
	}
	strings.write_string(&b, "</svg>\n")
	return strings.to_string(b)
}

hex_byte :: proc(s: string) -> u8 {
	v: u8
	for c in transmute([]u8)s {
		v <<= 4
		switch c {
		case '0' ..= '9': v |= c - '0'
		case 'a' ..= 'f': v |= c - 'a' + 10
		}
	}
	return v
}

// The visible layers flattened, scaled by `scale` without smoothing.
png :: proc(path: string, layers: []Layer, scale: int) -> bool {
	size := W * scale
	pixels := make([]u8, size * size * 4)
	defer delete(pixels)
	for l in layers {
		if !l.on do continue
		for y in 0 ..< H do for x in 0 ..< W {
			c := l.grid[y][x]
			if c == '.' do continue
			hex := color(c)
			rgba := [4]u8{hex_byte(hex[1:3]), hex_byte(hex[3:5]), hex_byte(hex[5:7]), 255}
			for dy in 0 ..< scale do for dx in 0 ..< scale {
				i := ((y * scale + dy) * size + x * scale + dx) * 4
				pixels[i + 0], pixels[i + 1], pixels[i + 2], pixels[i + 3] = rgba[0], rgba[1], rgba[2], rgba[3]
			}
		}
	}
	return stbi.write_png(strings.clone_to_cstring(path, context.temp_allocator), i32(size), i32(size), 4, raw_data(pixels), i32(size * 4)) != 0
}

main :: proc() {
	dir := os.args[1] if len(os.args) > 1 else "art"
	eyes_open, eyes_closed := draw_eyes()
	mouth_smile, mouth_tongue := draw_mouths()
	pads := draw_pads()
	layers := []Layer {
		{"body", draw_body(), true},
		{"eyes_open", eyes_open, true},
		{"eyes_closed", eyes_closed, false},
		{"mouth_tongue", mouth_tongue, true},
		{"mouth_smile", mouth_smile, false},
		{"pad_1", pads[0], false},
		{"pad_2", pads[1], false},
		{"pad_3", pads[2], false},
		{"pad_4", pads[3], false},
		{"notes", draw_notes(), false},
	}
	join :: proc(dir, name: string) -> string {
		p, _ := filepath.join({dir, name}, context.temp_allocator)
		return p
	}
	if err := os.write_entire_file(join(dir, "logo.svg"), svg(layers)); err != nil {
		fmt.eprintfln("writing %s: %v", join(dir, "logo.svg"), err)
		os.exit(1)
	}
	if !png(join(dir, "logo.png"), layers, 8) || !png(join(dir, "logo_32x32.png"), layers, 1) {
		fmt.eprintln("writing the PNGs failed")
		os.exit(1)
	}
}
