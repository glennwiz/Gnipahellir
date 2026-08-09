package gnipa_studio

// ─── Gnipa Studio — content authoring for Gnipahellir3 ────────────────────────
//
//  The pure-literal content tables (item_table, item_equip_slot, the icon
//  art, recipes, unlocks, smelt rules) live in src/gen_*.odin files that THIS
//  tool owns: it reads them by importing the game package and writes them by
//  re-emitting the files.  Tables that reference named constants
//  (item_stat_bonus, wand_*) stay hand-owned in src — codegen would flatten
//  the constant and silently break it as a tuning knob.
//
//    gnipa_studio                open the studio window (browser / DAG / pixel editor)
//    gnipa_studio --extract      write src/gen_*.odin from the compiled tables
//    gnipa_studio --emit-check   re-emit and byte-compare against src; exit 1 on drift
//    gnipa_studio --shot         render the tabs to png and exit (headless check)
//    gnipa_studio --test-save    flip one Dirt pixel and save (write-path smoke test)

import "core:fmt"
import "core:os"
import "core:strings"
import game "../../src"

TOOL_DIR :: #directory
SRC_DIR :: TOOL_DIR + "../../src/"

g_notes: Notes

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

write_gen_file :: proc(name, content: string) -> bool {
	path := fmt.tprintf("%s%s", SRC_DIR, name)
	if werr := os.write_entire_file(path, transmute([]u8)content); werr != nil {
		fmt.eprintfln("gnipa_studio: FAILED to write %s", path)
		return false
	}
	return true
}

Gen_Out :: struct {
	name:    string,
	content: string,
}

emit_all :: proc(notes: ^Notes) -> [4]Gen_Out {
	views: [game.Item]Icon_View
	shapes: [len(shape_registry)]Shape_View
	views_from_game(&views)
	shapes_from_registry(shapes[:])
	pframes := game.player_form_frames
	recipes := game.recipe_table
	smelts := game.smelt_table
	unlock: [game.Item]game.Item
	for gate, it in game.recipe_unlock do unlock[it] = gate
	return {
		{"gen_items.odin", emit_items(notes)},
		{"gen_item_icons.odin", emit_icons(notes, &views, shapes[:])},
		{"gen_recipes.odin", emit_recipes(notes, recipes[:], &unlock, smelts[:])},
		{"gen_player_art.odin", emit_player(notes, &pframes)},
	}
}

main :: proc() {
	mode := len(os.args) > 1 ? os.args[1] : ""

	notes_load(&g_notes)

	switch mode {
	case "--extract":
		for gf in emit_all(&g_notes) {
			if !write_gen_file(gf.name, gf.content) do os.exit(1)
			fmt.printfln("wrote %s (%d bytes)", gf.name, len(gf.content))
		}
	case "--emit-check":
		drift := false
		for gf in emit_all(&g_notes) {
			path := fmt.tprintf("%s%s", SRC_DIR, gf.name)
			have, rerr := os.read_entire_file_from_path(path, context.allocator)
			if rerr != nil {
				fmt.eprintfln("MISSING  %s (run --extract first)", gf.name)
				drift = true
				continue
			}
			// Compare CRLF-insensitively: git's autocrlf may rewrite the
			// working copy, and that alone is not drift.
			have_n, _ := strings.remove_all(string(have), "\r", context.temp_allocator)
			if have_n != gf.content {
				fmt.eprintfln("DRIFT    %s (%d bytes on disk, %d emitted)", gf.name, len(have), len(gf.content))
				drift = true
			} else {
				fmt.printfln("ok       %s", gf.name)
			}
		}
		if drift do os.exit(1)
	case "--shot":
		studio_run(shot = true)
	case "--test-save":
		os.exit(test_save() ? 0 : 1)
	case "":
		studio_run()
	case:
		fmt.println("gnipa_studio [--extract | --emit-check | --shot | --test-save]  (no args = open the studio)")
	}
}
