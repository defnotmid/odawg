package odawg_song

import "core:math"
import base "../base"

// Inside a build rows refer to rows by index. What names a row from outside
// one (a host, a view keeping its selection, a table kept across a recompose)
// names it by an id, which stays when the row moves. An id is made from what
// the row is: its name, or the id its spec or clip gives it (which a rename
// keeps), so every build and every machine gives the same one. Of several
// alike, the nth is its own (base.row_id). 0: none.
Node_Id :: distinct u32
Section_Id :: distinct u32
Marker_Id :: distinct u32
Device_Id :: distinct u32
Edge_Id :: distinct u32
Region_Id :: distinct u32
Lane_Id :: distinct u32
// A composed note has nothing to it but what it plays: its id is made from
// its track, its section and where in it, its pitch and its pad. Parts moving,
// the tempo, a section added before it leave it; moving the note makes another.
Note_Id :: distinct u32

// The tables a host can show, as rows: how to count them and read a row's id,
// so a view lists any of them without knowing the song's layout.
Row_Kind :: enum u8 {
	None,
	Node, // a track, a part, a return, a bus, a placed song, a voice group, the master
	Section,
	Marker,
	Chord,
	Note,
	Pad,
	Device, // an instrument or an effect
	Edge,
	Region,
	Lane, // an automation row
}

// A row from outside a build: its table, and which it is there.
Row_Ref :: struct {
	kind: Row_Kind,
	id:   u32,
}

Row_Kind_Row :: struct {
	name:  string,
	count: proc(s: ^Song) -> int,
	id:    proc(s: ^Song, row: int) -> u32,
}

ROW_KINDS := [Row_Kind]Row_Kind_Row {
	.None    = {"", proc(s: ^Song) -> int {return 0}, proc(s: ^Song, row: int) -> u32 {return 0}},
	.Node    = {"node", proc(s: ^Song) -> int {return len(s.node_ids)}, proc(s: ^Song, row: int) -> u32 {return u32(s.node_ids[row])}},
	.Section = {"section", proc(s: ^Song) -> int {return len(s.sections)}, proc(s: ^Song, row: int) -> u32 {return u32(s.sections[row].id)}},
	.Marker  = {"marker", proc(s: ^Song) -> int {return len(s.markers)}, proc(s: ^Song, row: int) -> u32 {return u32(s.markers[row].id)}},
	.Chord   = {"chord", proc(s: ^Song) -> int {return len(s.chords)}, proc(s: ^Song, row: int) -> u32 {
		// the nth of its section's
		for sec in s.sections {
			if i32(row) >= sec.chords.first && i32(row) < base.span_end(sec.chords) {
				return u32(base.hash_combine(u64(sec.id), u64(i32(row) - sec.chords.first))) | 1
			}
		}
		return 0
	}},
	.Note    = {"note", proc(s: ^Song) -> int {return len(s.note_ids)}, proc(s: ^Song, row: int) -> u32 {return u32(s.note_ids[row])}},
	.Pad     = {"pad", proc(s: ^Song) -> int {return len(s.pad_names)}, proc(s: ^Song, row: int) -> u32 {return base.name_id(s.pad_names[row])}},
	.Device  = {"device", proc(s: ^Song) -> int {return len(s.device_ids)}, proc(s: ^Song, row: int) -> u32 {return u32(s.device_ids[row])}},
	.Edge    = {"edge", proc(s: ^Song) -> int {return len(s.edge_ids)}, proc(s: ^Song, row: int) -> u32 {return u32(s.edge_ids[row])}},
	.Region  = {"region", proc(s: ^Song) -> int {return len(s.region_ids)}, proc(s: ^Song, row: int) -> u32 {return u32(s.region_ids[row])}},
	.Lane    = {"lane", proc(s: ^Song) -> int {return len(s.lane_ids)}, proc(s: ^Song, row: int) -> u32 {return u32(s.lane_ids[row])}},
}

row_ref :: proc(s: ^Song, kind: Row_Kind, row: int) -> Row_Ref {
	return {kind, ROW_KINDS[kind].id(s, row)}
}

// The row `ref` names in this build; -1: it has none.
row_from_ref :: proc(s: ^Song, ref: Row_Ref) -> int {
	if ref.id != 0 {
		k := ROW_KINDS[ref.kind]
		for row in 0 ..< k.count(s) {
			if k.id(s, row) == ref.id {
				return row
			}
		}
	}
	return -1
}

// The node `id` names in this build; -1: it has none.
node_from_id :: proc(s: ^Song, id: Node_Id) -> i32 {
	return i32(row_from_ref(s, {.Node, u32(id)}))
}

part_id :: proc(s: ^Song, part: int) -> Node_Id {return s.node_ids[part_node(s, part)]}

// The ids of what the routing and the arrangement made (a section's and a
// marker's are made with them). Once the song is built: its nodes first, what
// the rest are made from. A mix's notes (append_song's, append_clip's) come
// with their song's ids, each made its own there under its track.
ids_build :: proc(s: ^Song, mixed: bool) {
	seen := make(map[u32]u32, len(s.nodes), context.temp_allocator)
	clear(&s.node_ids)
	for k in 0 ..< len(s.nodes) {
		append(&s.node_ids, Node_Id(base.row_id(&seen, node_text(s, i32(k), true))))
	}
	// a device is its owner's: a node's chain, a track's instrument
	clear(&seen)
	clear(&s.device_ids)
	resize(&s.device_ids, len(s.devices))
	mine :: proc(s: ^Song, seen: ^map[u32]u32, d: i32, owner: Node_Id, name: string) {
		if s.device_ids[d] == 0 {
			h := base.hash_combine(u64(owner), base.hash_string(name))
			s.device_ids[d] = Device_Id(base.row_id_from_hash(seen, u32(h)))
		}
	}
	given_or_label :: proc(s: ^Song, d: i32) -> string {
		return s.device_given_ids[d] != "" ? s.device_given_ids[d] : s.labels[d]
	}
	for _, k in s.nodes {
		sp := node_chain(s, k)
		for d in s.chain[sp.first:base.span_end(sp)] {
			mine(s, &seen, d, s.node_ids[k], given_or_label(s, d))
		}
	}
	for t, ti in s.tracks {
		mine(s, &seen, t.instrument, s.node_ids[ti], "instrument")
	}
	for _, d in s.devices {
		mine(s, &seen, i32(d), 0, given_or_label(s, i32(d)))
	}
	clear(&seen)
	clear(&s.edge_ids)
	for x in s.edges {
		h := base.hash_combine(base.hash_combine(u64(s.node_ids[x.from]), u64(s.node_ids[x.to])), u64(x.kind))
		append(&s.edge_ids, Edge_Id(base.row_id_from_hash(&seen, u32(h))))
	}
	clear(&seen)
	clear(&s.region_ids)
	for r in s.regions {
		h := base.hash_combine(u64(part_id(s, int(r.part))), base.hash_string(r.source))
		append(&s.region_ids, Region_Id(base.row_id_from_hash(&seen, u32(h))))
	}
	clear(&seen)
	clear(&s.lane_ids)
	for a in s.automation {
		append(&s.lane_ids, Lane_Id(base.row_id(&seen, a.path)))
	}
	notes_seen := make(map[u32]u32, len(s.notes), context.temp_allocator)
	if !mixed {
		resize(&s.note_ids, len(s.notes))
	}
	for i in 0 ..< len(s.notes) {
		h := u64(s.node_ids[s.notes.track[i]])
		if mixed {
			h = base.hash_combine(h, u64(s.note_ids[i]))
		} else {
			sec := s.sections[section_from_beat(s, s.notes.beat[i])]
			at := i64(math.round((s.notes.beat[i] - sec.beat) * 9600)) // ticks, so a section before it can't round it
			h = base.hash_combine(h, u64(sec.id))
			h = base.hash_combine(h, transmute(u64)at)
			h = base.hash_combine(h, u64(transmute(u32)f32(s.notes.pitch[i])))
			h = base.hash_combine(h, u64(s.notes.pad[i]))
			h = base.hash_combine(h, u64(s.notes.kind[i]))
		}
		s.note_ids[i] = Note_Id(base.row_id_from_hash(&notes_seen, u32(h)))
	}
}
