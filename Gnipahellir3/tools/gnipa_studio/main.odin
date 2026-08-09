package gnipa_studio

// ─── Gnipa Studio — content authoring for Gnipahellir3 ────────────────────────
//
//  Phase A: the codegen foundation.  The pure-literal content tables
//  (item_table, item_equip_slot, the icon art, recipes, unlocks, smelt rules)
//  live in src/gen_*.odin files that THIS tool owns: it reads them by
//  importing the game package and writes them by re-emitting the files.
//  Tables that reference named constants (item_stat_bonus, wand_*) stay
//  hand-owned in src — codegen would flatten the constant and silently break
//  it as a tuning knob.
//
//    gnipa_studio --extract      write src/gen_*.odin from the compiled tables
//    gnipa_studio --emit-check   re-emit and byte-compare against src; exit 1
//                                on drift (run after any hand meddling)

import "core:fmt"
import "core:os"
import "core:strings"

TOOL_DIR :: #directory
SRC_DIR :: TOOL_DIR + "../../src/"

// ─── notes.txt: the row-comment sidecar ───────────────────────────────────────

Notes :: struct {
	lines: map[string][dynamic]string,
}

notes_load :: proc(notes: ^Notes) {
	data, err := os.read_entire_file_from_path(TOOL_DIR + "notes.txt", context.allocator)
	if err != nil {
		fmt.eprintln("gnipa_studio: notes.txt missing beside the exe source; emitting without comments")
		return
	}
	for line in strings.split_lines(string(data)) {
		if len(line) == 0 || line[0] == '#' do continue
		t1 := strings.index_byte(line, '\t')
		if t1 < 0 do continue
		t2 := strings.index_byte(line[t1+1:], '\t')
		if t2 < 0 do continue
		key := fmt.aprintf("%s/%s", line[:t1], line[t1+1:][:t2])
		if key not_in notes.lines do notes.lines[key] = {}
		arr := &notes.lines[key]
		append(arr, line[t1+1+t2+1:])
	}
}

notes_write :: proc(b: ^strings.Builder, notes: ^Notes, table, key, indent: string) {
	lines, ok := notes.lines[fmt.tprintf("%s/%s", table, key)]
	if !ok do return
	for l in lines do fmt.sbprintf(b, "%s// %s\n", indent, l)
}

// ─── Emit / check ─────────────────────────────────────────────────────────────

Gen_File :: struct {
	name: string,
	emit: proc(notes: ^Notes, allocator := context.allocator) -> string,
}

gen_files := [?]Gen_File{
	{"gen_items.odin", emit_items},
	{"gen_item_icons.odin", emit_icons},
	{"gen_recipes.odin", emit_recipes},
}

main :: proc() {
	mode := len(os.args) > 1 ? os.args[1] : ""

	notes: Notes
	notes_load(&notes)

	switch mode {
	case "--extract":
		for gf in gen_files {
			path := fmt.tprintf("%s%s", SRC_DIR, gf.name)
			content := gf.emit(&notes)
			if werr := os.write_entire_file(path, transmute([]u8)content); werr != nil {
				fmt.eprintfln("gnipa_studio: FAILED to write %s", path)
				os.exit(1)
			}
			fmt.printfln("wrote %s (%d bytes)", gf.name, len(content))
		}
	case "--emit-check":
		drift := false
		for gf in gen_files {
			path := fmt.tprintf("%s%s", SRC_DIR, gf.name)
			want := gf.emit(&notes)
			have, rerr := os.read_entire_file_from_path(path, context.allocator)
			if rerr != nil {
				fmt.eprintfln("MISSING  %s (run --extract first)", gf.name)
				drift = true
				continue
			}
			// Compare CRLF-insensitively: git's autocrlf may rewrite the
			// working copy, and that alone is not drift.
			have_n, _ := strings.remove_all(string(have), "\r", context.temp_allocator)
			if have_n != want {
				fmt.eprintfln("DRIFT    %s (%d bytes on disk, %d emitted)", gf.name, len(have), len(want))
				drift = true
			} else {
				fmt.printfln("ok       %s", gf.name)
			}
		}
		if drift do os.exit(1)
	case "--shot":
		studio_run(shot = true)
	case "":
		studio_run()
	case:
		fmt.println("gnipa_studio [--extract | --emit-check | --shot]  (no args = open the studio)")
	}
}
