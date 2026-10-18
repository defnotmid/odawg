package odawg_song

import "core:slice"
import "core:strings"
import base "../base"

// The song's routing as two tables. A node is a track (its voices and its
// chain), a bus (it sums what feeds it and runs its chain: a part, a return,
// one the spec names) or the master; an edge carries a node's output into
// another at a gain, as sound or as the key a sidechain listens to. Any node
// may feed any node; the engine renders them in an order computed once
// (graph_order), each after everything feeding it, so a return hears every
// send in one place and a bus sums its inputs once.
//
// Composing builds the default routing (graph_build): each track into its
// part, its sends into their returns, the parts and the returns into the
// master. Nodes are laid out tracks, parts, returns, buses, master, so a
// part's node is `len(tracks) + part`.

Node_Kind :: enum u8 {
	Track,
	Part,
	Return,
	Bus,
	Master,
}

Node :: struct {
	kind: Node_Kind,
	ref:  i32, // Track: into tracks; Part: into parts; Return: into returns; Bus: into buses
}

// A node's effects, read from what it stands for (never copied: a chain
// changed later, the master's limiter a mastering adds, is what it runs).
NODE_CHAIN := [Node_Kind]proc(s: ^Song, ref: i32) -> Span {
	.Track  = proc(s: ^Song, ref: i32) -> Span {return s.tracks[ref].chain},
	.Part   = proc(s: ^Song, ref: i32) -> Span {return {}},
	.Return = proc(s: ^Song, ref: i32) -> Span {return s.returns[ref].chain},
	.Bus    = proc(s: ^Song, ref: i32) -> Span {return s.buses[ref].chain},
	.Master = proc(s: ^Song, ref: i32) -> Span {return s.master},
}

node_chain :: proc(s: ^Song, k: int) -> Span {
	nd := s.nodes[k]
	return NODE_CHAIN[nd.kind](s, nd.ref)
}

Edge_Kind :: enum u8 {
	Audio, // summed into the node's input
	Key, // what its chain's sidechain (a compressor's key) hears
}

Edge :: struct {
	from, to: i32, // into nodes
	gain:     f32, // linear
	kind:     Edge_Kind,
}

// A bus the spec names: its effects (where it goes is a route).
Bus :: struct {
	name:  string,
	chain: Span,
}

// What the spec routes, by name (a part, a return, a bus, "master"): a
// node's output moved off the master to another (`moves`: a part's or a
// bus's `to`), sent on as well at a gain (a send to a bus), or heard as a
// key (a part's `key`: by each of its tracks' effects).
Route :: struct {
	from, to: string,
	kind:     Edge_Kind,
	gain:     f32,
	moves:    bool,
}

// Builds the default routing from the tracks, their sends and the returns
// (and the spec's buses, routed by graph_route).
graph_build :: proc(s: ^Song) {
	clear(&s.nodes)
	clear(&s.edges)
	for _, i in s.tracks {
		append(&s.nodes, Node{.Track, i32(i)})
	}
	for _, i in s.parts {
		append(&s.nodes, Node{.Part, i32(i)})
	}
	for _, i in s.returns {
		append(&s.nodes, Node{.Return, i32(i)})
	}
	for _, i in s.buses {
		append(&s.nodes, Node{.Bus, i32(i)})
	}
	append(&s.nodes, Node{.Master, 0})
	master := i32(len(s.nodes) - 1)
	for t, i in s.tracks {
		append(&s.edges, Edge{i32(i), part_node(s, int(t.part)), 1, .Audio})
		for snd in s.sends[t.sends.first:base.span_end(t.sends)] {
			append(&s.edges, Edge{i32(i), return_node(s, int(snd.ret)), snd.gain, .Audio})
		}
	}
	for _, i in s.parts {
		append(&s.edges, Edge{part_node(s, i), master, 1, .Audio})
	}
	for _, i in s.returns {
		append(&s.edges, Edge{return_node(s, i), master, 1, .Audio})
	}
	for _, i in s.buses {
		append(&s.edges, Edge{bus_node(s, i), master, 1, .Audio})
	}
	for rt in s.routes {
		from, to := node_from_name(s, rt.from), node_from_name(s, rt.to)
		if from < 0 || to < 0 {
			base.report(&s.findings, "bad_value", .Error, "routing", "routing: %q into %q: there is no part, return or bus %q", rt.from, rt.to, from < 0 ? rt.from : rt.to)
			continue
		}
		switch {
		case rt.moves:
			for &x in s.edges {
				if x.from == from && x.to == master && x.kind == .Audio {
					x.to = to
				}
			}
		case rt.kind == .Key && s.nodes[to].kind == .Part:
			// a part's effects are its tracks'
			for t, i in s.tracks {
				if int(t.part) == int(s.nodes[to].ref) {
					append(&s.edges, Edge{from, i32(i), rt.gain, .Key})
				}
			}
		case:
			append(&s.edges, Edge{from, to, rt.gain, rt.kind})
		}
	}
	graph_sort_edges(s)
	// a loop is reported once, here, where the routing is made (the engines
	// that walk it only read the song)
	_, loops := graph_order(s, context.temp_allocator)
	for i in loops {
		x := s.edges[i]
		base.report(&s.findings, "routing_loop", .Error, "routing", "routing: %s into %s closes a loop; that path is left out", node_name(s, x.from), node_name(s, x.to))
	}
}

// The node a route names: a bus, a return or a part by name (in that
// order), or "master"; -1: none.
node_from_name :: proc(s: ^Song, name: string) -> i32 {
	if name == "master" {
		return master_node(s)
	}
	for b, i in s.buses {
		if b.name == name {
			return bus_node(s, i)
		}
	}
	for r, i in s.returns {
		if r.name == name {
			return return_node(s, i)
		}
	}
	for p, i in s.parts {
		if p == name {
			return part_node(s, i)
		}
	}
	return -1
}

part_node :: proc(s: ^Song, part: int) -> i32 {return i32(len(s.tracks) + part)}
return_node :: proc(s: ^Song, ret: int) -> i32 {return i32(len(s.tracks) + len(s.parts) + ret)}
bus_node :: proc(s: ^Song, bus: int) -> i32 {return i32(len(s.tracks) + len(s.parts) + len(s.returns) + bus)}
master_node :: proc(s: ^Song) -> i32 {return i32(len(s.nodes) - 1)}

// The edges by where they go, then where they come from: a node's inputs
// are one run, summed in that order every time.
graph_sort_edges :: proc(s: ^Song) {
	slice.stable_sort_by(s.edges[:], proc(a, b: Edge) -> bool {
		return a.to < b.to || (a.to == b.to && a.from < b.from)
	})
}

// The nodes in an order where each comes after every node feeding it
// (sound or key), and the edges that close a loop (into `s.edges`; left out
// of the order, a finding each): where the order stalls, the first loop
// found from the lowest unplaced node loses the edge that closes it, and the
// order goes on, so a loop costs only that edge.
graph_order :: proc(s: ^Song, allocator := context.allocator) -> (order: []i32, loops: [dynamic]int) {
	n := len(s.nodes)
	dropped := make([]bool, len(s.edges), context.temp_allocator)
	waiting := make([]int, n, context.temp_allocator) // inputs not yet ordered
	for x in s.edges {
		waiting[x.to] += 1
	}
	placed := make([]bool, n, context.temp_allocator)
	out := make([dynamic]i32, 0, n, allocator)
	loops = make([dynamic]int, allocator)
	ready := make([dynamic]i32, 0, n, context.temp_allocator)
	for k in 0 ..< n {
		if waiting[k] == 0 {
			append(&ready, i32(k))
		}
	}
	for len(out) < n {
		for len(ready) > 0 {
			// the lowest index first: the same order every time
			slice.sort(ready[:])
			k := ready[0]
			ordered_remove(&ready, 0)
			append(&out, k)
			placed[k] = true
			for x, i in s.edges {
				if x.from == k && !dropped[i] {
					waiting[x.to] -= 1
					if waiting[x.to] == 0 {
						append(&ready, x.to)
					}
				}
			}
		}
		if len(out) == n {
			break
		}
		// stalled: what is left feeds itself somewhere; cut that loop
		i := closing_edge(s, placed, dropped)
		if i < 0 {
			break // can't happen: an unplaced node always waits on a loop
		}
		dropped[i] = true
		append(&loops, i)
		x := s.edges[i]
		waiting[x.to] -= 1
		if waiting[x.to] == 0 {
			append(&ready, x.to)
		}
	}
	return out[:], loops
}

// The edge that closes the first loop a depth-first walk over the unplaced
// nodes finds (from the lowest), as an index into s.edges; -1: none.
@(private = "file")
closing_edge :: proc(s: ^Song, placed, dropped: []bool) -> int {
	Mark :: enum u8 {
		None,
		Open,
		Done,
	}
	marks := make([]Mark, len(s.nodes), context.temp_allocator)
	walk :: proc(s: ^Song, k: i32, placed, dropped: []bool, marks: []Mark) -> int {
		marks[k] = .Open
		for x, i in s.edges {
			if x.from != k || dropped[i] || placed[x.to] {
				continue
			}
			switch marks[x.to] {
			case .Open:
				return i // back to a node still open: this edge closes a loop
			case .None:
				if found := walk(s, x.to, placed, dropped, marks); found >= 0 {
					return found
				}
			case .Done:
			}
		}
		marks[k] = .Done
		return -1
	}
	for _, k in s.nodes {
		if !placed[k] && marks[k] == .None {
			if found := walk(s, i32(k), placed, dropped, marks); found >= 0 {
				return found
			}
		}
	}
	return -1
}

// A node as the spec names it: "part drums", "return hall", "bus glue",
// "track drums/house" (its part and the style it plays for), "master".
node_name :: proc(s: ^Song, k: i32, allocator := context.temp_allocator) -> string {
	nd := s.nodes[k]
	switch nd.kind {
	case .Track:
		t := s.tracks[nd.ref]
		if t.variant == "" {
			return strings.concatenate({"track ", s.parts[t.part]}, allocator)
		}
		return strings.concatenate({"track ", s.parts[t.part], "/", t.variant}, allocator)
	case .Part:
		return strings.concatenate({"part ", s.parts[nd.ref]}, allocator)
	case .Return:
		return strings.concatenate({"return ", s.returns[nd.ref].name}, allocator)
	case .Bus:
		return strings.concatenate({"bus ", s.buses[nd.ref].name}, allocator)
	case .Master:
	}
	return "master"
}
