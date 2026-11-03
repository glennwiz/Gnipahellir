#+test
package game

import "base:runtime"
import "core:bytes"
import "core:compress/gzip"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:reflect"
import "core:slice"
import "core:strings"
import "core:testing"

// testdata/save_v28.dat.gz is a real autosave, not a fixture built from today's
// structs: tools/agent_play.sh, seed 7791, at save v28, walked and mined by hand
// over the agent socket, gzip -9.  Never regenerate it: its whole worth is
// that it was written by the old build.

SAVE_V28_GOLDEN := #load("testdata/save_v28.dat.gz")

@(private="file")
golden_bytes :: proc(t: ^testing.T, buf: ^bytes.Buffer) -> []u8 {
	testing.expect(t, gzip.load_from_bytes(SAVE_V28_GOLDEN, buf) == nil, "the golden unpacks")
	raw := bytes.buffer_to_bytes(buf)
	testing.expect_value(t, len(raw), SAVE_V28_SIZE)
	return raw
}

// What that run did, read through today's live types.  A field that moved, or
// an enum value inserted ahead of one, lands here even with every size equal.
@(test)
a_real_v28_save_loads_the_run_that_wrote_it :: proc(t: ^testing.T) {
	path :: "gnipahellir_save_golden_test.dat"
	defer os.remove(path)
	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	testing.expect(t, os.write_entire_file(path, golden_bytes(t, &buf)) == nil)

	gs := turret_test_state()
	defer free(gs)
	testing.expect(t, load_game_from(gs, path), "the v28 run loads")
	testing.expect_value(t, gs.world_seed, u32(7791))
	testing.expect_value(t, gs.level_index, LEVEL_SURFACE)
	testing.expect_value(t, gs.frame, u64(717))
	testing.expect_value(t, gs.player.hp, 8)
	testing.expect_value(t, gs.player.hp_max, 10)
	testing.expect_value(t, int(gs.player.pos.x), 97)
	testing.expect_value(t, int(gs.player.pos.y), 60)
	testing.expect_value(t, gs.player.inventory.slots[0].item, Item.Wood_Log)
	testing.expect_value(t, gs.player.inventory.slots[0].count, 4)
	testing.expect_value(t, gs.player.inventory.slots[1].item, Item.Leaf)
	testing.expect_value(t, gs.player.inventory.slots[1].count, 3)
	testing.expect_value(t, gs.enemies.count, 3)
	for i in 0 ..< 3 {
		testing.expect(t, gs.enemies.active[i], "the three builders")
		testing.expect_value(t, gs.enemies.data[i].kind, Enemy_Kind.Builder)
		testing.expect_value(t, gs.enemies.data[i].hp, 6)
	}
	testing.expect_value(t, gs.levels.generated, [NUM_LEVELS]bool{true, false, false, false, false})

	terrain: [Tile_Type]int
	for tile in gs.world.terrain do terrain[tile] += 1
	testing.expect_value(t, terrain[.Stone], 4752)
	testing.expect_value(t, terrain[.Iron_Ore], 204)
	testing.expect_value(t, terrain[.Gold_Ore], 9)
	testing.expect_value(t, terrain[.Cave_Entrance], 2)
	testing.expect_value(t, terrain[.Sky_Rune_Scroll_Chest], 1)
}

// `current` stands in for the build after the next bump: the live branch stops
// answering for this file, which must then come through the frozen path.
@(test)
a_v28_save_still_reads_after_the_next_bump :: proc(t: ^testing.T) {
	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	raw := golden_bytes(t, &buf)
	sd := save_data_read(raw, SAVE_VERSION + 1)
	defer free(sd)
	testing.expect(t, sd != nil, "the frozen path takes it")
	if sd == nil do return
	testing.expect_value(t, sd.version, SAVE_VERSION)
	testing.expect_value(t, sd.world_seed, u32(7791))
	testing.expect_value(t, sd.player.inventory.slots[0].item, Item.Wood_Log)
}

// Every field filled, so a line missing from save_data_from_v28, or an offset
// that is wrong, shows as a byte that differs.  Only the same size can compare
// whole: a bump that moves the live struct leaves the golden tests above.
@(test)
the_frozen_v28_path_carries_every_field :: proc(t: ^testing.T) {
	when size_of(Save_Data) != SAVE_V28_SIZE { return }
	want := new(Save_Data)
	defer free(want)
	want.version = SAVE_VERSION
	mem.set(&want.level_index, 0x11, size_of(want.level_index))
	mem.set(&want.world, 0x12, size_of(want.world))
	mem.set(&want.levels, 0x13, size_of(want.levels))
	mem.set(&want.player, 0x14, size_of(want.player))
	want.player.dead = false
	mem.set(&want.enemies, 0x15, size_of(want.enemies))
	mem.set(&want.golems, 0x16, size_of(want.golems))
	mem.set(&want.sim, 0x17, size_of(want.sim))
	mem.set(&want.progression, 0x18, size_of(want.progression))
	mem.set(&want.dimension, 0x19, size_of(want.dimension))
	mem.set(&want.elapsed_time, 0x1a, size_of(want.elapsed_time))
	mem.set(&want.frame, 0x1b, size_of(want.frame))
	mem.set(&want.grave, 0x1c, size_of(want.grave))
	mem.set(&want.risen, 0x1d, size_of(want.risen))
	mem.set(&want.world_seed, 0x1e, size_of(want.world_seed))

	// The file is v28 and its grave's padding holds junk: the fields made from
	// that padding are set by the path, not read.
	file := new_clone(want^)
	defer free(file)
	file.version = 28
	got := save_data_read(mem.ptr_to_bytes(file))
	defer free(got)
	testing.expect(t, got != nil, "read")
	if got == nil do return
	testing.expect(t, mem.compare_ptrs(&got.grave.active, &file.grave.active, 1) == 0, "grave active")
	testing.expect_value(t, got.grave.tithe, file.grave.tithe)
	testing.expect_value(t, got.grave.hero, file.grave.hero)
	testing.expect(t, mem.compare_ptrs(&got.grave.seconds, &file.grave.seconds, size_of(f32)) == 0, "grave seconds")
	testing.expect_value(t, got.grave.cause, file.grave.cause)
	testing.expect_value(t, got.grave.place, file.grave.place)
	testing.expect_value(t, got.grave.tile, file.grave.tile)
	testing.expect(t, !got.grave.pending, "a v28 grave stands")
	testing.expect_value(t, got.grave.level, i32(LEVEL_SURFACE))
	got.grave, want.grave = {}, {}
	testing.expect(t, mem.compare_ptrs(got, want, size_of(Save_Data)) == 0, "every byte arrives")
}

@(test)
the_frozen_v28_path_refuses_what_the_live_one_refuses :: proc(t: ^testing.T) {
	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	raw := golden_bytes(t, &buf)
	future := SAVE_VERSION + 1

	short := raw[:SAVE_V28_SIZE - 1]
	testing.expect(t, save_data_read(short, future) == nil, "a file one byte short")
	testing.expect(t, save_data_read(raw[:2], future) == nil, "too short to hold a version")
	testing.expect(t, save_data_read(nil, future) == nil, "empty")

	raw[0] = 27
	testing.expect(t, save_data_read(raw, future) == nil, "the v28 size with another version")
	raw[0] = 28

	dead := mem.ptr_offset(raw_data(raw), SAVE_V28_PLAYER_AT + offset_of(Player, dead))
	dead[0] = 1
	testing.expect(t, save_data_read(raw, future) == nil, "a dead run does not resume")
	testing.expect(t, save_data_read(raw) == nil, "nor through the live path")
}

// Saves hold these as bare ordinals, so an inserted value moves every saved
// tile and item behind it with all sizes equal.  Append-only: add new names at
// the end of a row.  A new enum in a saved struct needs a row here.
@(private="file", rodata)
pinned_enums := []struct{type: typeid, names: []string}{
	{Build_Kind, {
		"Cairn", "Pillar", "Shelter", "Lair",
	}},
	{Builder_Goal, {
		"Build_Den", "Fetch_Mineral", "Encase_Den", "Hunt", "Cooldown", "Wave_Hunt",
	}},
	{Dimension_Kind, {
		"Metal", "Gold", "Runic", "Hell",
	}},
	{Enemy_Kind, {
		"Garm", "Undead", "Fire_Sprite", "Builder", "Raider", "Vargr", "Pond_Frog", "Ember_Beetle", "Rain_Wisp", "Rock_Harpy",
		"Mole", "Cave_Eel", "Magma_Crawler", "Stone_Grub",
	}},
	{Equip_Slot, {
		"None", "Weapon", "Head", "Chest", "Hands", "Legs", "Feet", "Charm", "Tool", "Charm_2",
		"Charm_3",
	}},
	{Garm_Phase, {
		"Chase", "Column", "Ring", "Flood",
	}},
	{Golem_Job, {
		"Idle", "Seek", "Mine", "Deliver", "Fetch_Build", "Place",
	}},
	{Golem_Mode, {
		"Gather", "Build", "Fight",
	}},
	{Golem_Plan, {
		"None", "Clay_Hearth", "Golem_Depot", "World_Anchor",
	}},
	{Golem_Status, {
		"Empty", "Carried", "Deployed", "Broken",
	}},
	{Item, {
		"None", "Sword", "Pickaxe", "Potion_Health", "Potion_Mana", "Mine_Wand", "Mine_Wand_Silver",
		"Mine_Wand_Gold", "Wood_Log", "Leaf", "Stone_Block", "Grass_Turf", "Plank", "Iron_Ore",
		"Silver_Ore", "Gold_Ore", "Gold_Rare_Ore", "Crafting_Bench", "Tree_Grower", "Smelter",
		"Iron_Bucket", "Hell_Key", "Rune_Scroll_A", "Rune_Scroll_B", "Rune_Scroll_C", "Sky_Rune_Scroll",
		"Sky_Altar", "Cloud_Stone", "Aether_Crystal", "Runic_Sky_Ore", "Aether_Charm", "Silver_Sword",
		"Gold_Sword", "Iron_Helm", "Silver_Helm", "Gold_Helm", "Iron_Chestplate", "Silver_Chestplate",
		"Gold_Chestplate", "Iron_Gauntlets", "Silver_Gauntlets", "Gold_Gauntlets", "Iron_Greaves",
		"Silver_Greaves", "Gold_Greaves", "Iron_Boots", "Silver_Boots", "Gold_Boots", "Dvergr_Forge",
		"Rune_Altar", "Mine_Wand_Runic", "Runic_Sword", "Runic_Helm", "Runic_Chestplate",
		"Runic_Gauntlets", "Runic_Greaves", "Runic_Boots", "Iron_Bar", "Silver_Bar", "Gold_Bar",
		"Dimension_Spawner", "Dimension_Spawner_Gold", "Emerald", "Jade", "Diamond", "Hel_Gem",
		"Auto_Miner", "Dimension_Spawner_Runic", "Silo", "Dirt", "Door", "Flower", "Flower_Seed",
		"Flower_Bed", "Barrel", "Void_Charm", "Clay", "Command_Wand", "Command_Wand_Emerald",
		"Command_Wand_Hel", "Clay_Golem", "Jade_Ring", "Sand", "Rune_Coffer", "Scroll_Of_Waters",
		"Boiler", "Steam_Engine", "Water_Bucket", "Lava_Bucket", "Magic_Lava_Bucket", "Gem_Replicator",
		"GreenBerrie", "Green_Cave_Mushroom", "Magic_Kettle", "Mana_Wheel", "Mana_Pipe", "Mossy_Stone",
		"Fire_Wand", "Rainbow_Laser", "Turret_Pillar", "Flame_Head", "Water_Head", "Earth_Head",
		"Sky_Egg",
		"Slime", "Coal", "Eel_Skin",
	}},
	{Tile_Flag, {
		"Fire", "Poison", "Corrupted", "Lit", "Placed", "Golem_Placed", "Golem_Marked", "Piped",
	}},
	{Tile_Type, {
		"Air", "Void", "Grass", "Stone", "Water", "Lava", "Magic_Lava", "Wood", "Leaves", "Iron_Ore",
		"Silver_Ore", "Gold_Ore", "Gold_Rare_Ore", "Crafting_Bench", "Tree_Grower", "Smelter",
		"Cave_Entrance", "Sky_Entrance", "Sky_Altar", "Cloud", "Cloud_Ore", "Aether_Ore",
		"Runic_Sky_Ore", "Wind_Current", "Void_Sky", "Flower", "Dvergr_Forge", "Rune_Altar",
		"Dimension_Spawner", "Dimension_Gate", "Dimension_Spawner_Gold", "Emerald_Ore", "Jade_Ore",
		"Diamond_Ore", "Hel_Gem_Ore", "Auto_Miner", "Miner_Body", "Dimension_Spawner_Runic", "Silo",
		"Dirt", "Door", "Flower_Bed", "Barrel", "Sky_Rune_Scroll_Chest", "Rune_Scroll_Chest_A",
		"Rune_Scroll_Chest_B", "Rune_Scroll_Chest_C", "Clay", "Clay_Hearth", "Golem_Depot",
		"World_Anchor", "Quick_Clay", "Sand", "Rune_Coffer", "Steam", "Boiler", "Steam_Engine",
		"Gem_Replicator", "Green_Cave_Mushroom", "Mossy_Stone", "Magic_Kettle", "Mana_Wheel",
		"Mana_Mist", "Hell_Gate", "Final_Seal", "Rainbow_Laser", "Rune_Stone", "Scoria", "Turret_Pillar",
		"Flame_Turret", "Water_Turret", "Earth_Turret", "Rainbow_Bridge", "Nest", "Cinders",
	}},
}

// Walks every type a save reaches, in field order: the enums found, and one
// line per struct field.
@(private="file")
saved_walk :: proc(ti: ^runtime.Type_Info, found: ^map[typeid]bool, seen: ^map[typeid]bool, lines: ^strings.Builder, owner := "Save_Data") {
	if ti.id in seen^ do return
	seen[ti.id] = true
	#partial switch v in ti.variant {
	case runtime.Type_Info_Named:
		if _, is_enum := v.base.variant.(runtime.Type_Info_Enum); is_enum do found[ti.id] = true
		saved_walk(v.base, found, seen, lines, v.name)
	case runtime.Type_Info_Struct:
		for i in 0 ..< v.field_count {
			fmt.sbprintfln(lines, "%s.%s %d %d %v", owner, v.names[i], v.offsets[i], v.types[i].size, v.types[i].id)
		}
		for i in 0 ..< v.field_count do saved_walk(v.types[i], found, seen, lines)
	case runtime.Type_Info_Array:
		saved_walk(v.elem, found, seen, lines)
	case runtime.Type_Info_Enumerated_Array:
		saved_walk(v.elem, found, seen, lines)
		saved_walk(v.index, found, seen, lines)
	case runtime.Type_Info_Bit_Set:
		saved_walk(v.elem, found, seen, lines)
	}
}

@(test)
saved_enum_ordinals_never_move :: proc(t: ^testing.T) {
	for row in pinned_enums {
		names  := reflect.enum_field_names(row.type)
		values := reflect.enum_field_values(row.type)
		testing.expectf(t, len(names) == len(row.names), "%v has %d values, pinned_enums has %d: a new value goes at the end of the enum and of its row", row.type, len(names), len(row.names))
		for name, i in row.names {
			if i >= len(names) do break
			testing.expectf(t, names[i] == name, "%v ordinal %d is %s, was %s: append, never insert or rename", row.type, i, names[i], name)
			testing.expectf(t, int(values[i]) == i, "%v.%s is %d, was %d", row.type, name, values[i], i)
		}
	}
}

// A row search, not delete_key on the found map: delete_key on a map keyed by
// typeid hangs the odin compiler at -o:size and above (dev-2026-10).
@(private="file")
enum_is_pinned :: proc(id: typeid, rows: type_of(pinned_enums)) -> bool {
	for row in rows do if row.type == id do return true
	return false
}

@(test)
enum_is_pinned_finds_only_its_rows :: proc(t: ^testing.T) {
	testing.expect(t, enum_is_pinned(Tile_Type, pinned_enums), "a pinned enum has its row")
	testing.expect(t, !enum_is_pinned(Save_Data, pinned_enums), "a type with no row is not pinned")
	testing.expect(t, !enum_is_pinned(Tile_Type, nil), "no rows pin nothing")
}

@(test)
every_saved_enum_is_pinned :: proc(t: ^testing.T) {
	found, seen: map[typeid]bool
	defer delete(found)
	defer delete(seen)
	lines := strings.builder_make()
	defer strings.builder_destroy(&lines)
	saved_walk(type_info_of(Save_Data), &found, &seen, &lines)
	testing.expect(t, Tile_Type in found && Item in found && Equip_Slot in found && Tile_Flag in found, "the walk reaches the enums")
	for id in found do testing.expectf(t, enum_is_pinned(id, pinned_enums), "%v is saved and has no row in pinned_enums", id)
}

// testdata/save_layout.txt is the name, offset, size and type of every field of
// every struct a save holds, under the SAVE_VERSION it belongs to.  Sizes cannot
// see two fields of one size trading places; this can, in the structs the golden
// run left empty too.
//
// A red here means a saved field moved.  If that was not meant, undo it.  If it
// was: bump SAVE_VERSION, give the old layout a read path, then rewrite the file
// with `odin test src -define:SAVE_LAYOUT_WRITE=true`.  That refuses to run until
// the version is bumped.  A plain rename of a field moves no byte: edit its name
// in the file by hand.
SAVE_LAYOUT_WRITE :: #config(SAVE_LAYOUT_WRITE, false)
SAVE_LAYOUT_PATH  :: "src/testdata/save_layout.txt"
SAVE_LAYOUT       :: string(#load("testdata/save_layout.txt"))

// A bump rewrites save_layout.txt, so it forgets v28.  This file does not, and
// any v28 field the live structs no longer hold where v28 wrote it must be
// converted by save_data_from_v28 and named here.  New fields are free.
SAVE_LAYOUT_V28 :: string(#load("testdata/save_layout_v28.txt"))

@(private="file", rodata)
v28_fields_converted := []string{}

@(test)
every_v28_field_stands_where_v28_wrote_it :: proc(t: ^testing.T) {
	found, seen: map[typeid]bool
	defer delete(found)
	defer delete(seen)
	lines := strings.builder_make()
	defer strings.builder_destroy(&lines)
	saved_walk(type_info_of(Save_Data), &found, &seen, &lines)
	live := strings.split_lines(strings.to_string(lines))
	defer delete(live)
	frozen := strings.split_lines(SAVE_LAYOUT_V28)
	defer delete(frozen)
	testing.expect(t, strings.has_prefix(SAVE_LAYOUT_V28, "version 28\n"), "the frozen file is v28's")
	for line in frozen[1:] {
		if line == "" || slice.contains(live, line) do continue
		field := line[:strings.index_byte(line, ' ')]
		testing.expectf(t, slice.contains(v28_fields_converted, field), "v28's %s moved: convert it in save_data_from_v28, then add it to v28_fields_converted", line)
	}
}

@(test)
saved_layout_never_moves_inside_a_version :: proc(t: ^testing.T) {
	found, seen: map[typeid]bool
	defer delete(found)
	defer delete(seen)
	lines := strings.builder_make()
	defer strings.builder_destroy(&lines)
	fmt.sbprintfln(&lines, "version %d", SAVE_VERSION)
	saved_walk(type_info_of(Save_Data), &found, &seen, &lines)
	live := strings.to_string(lines)

	when SAVE_LAYOUT_WRITE {
		head := fmt.tprintfln("version %d", SAVE_VERSION)
		testing.expectf(t, !strings.has_prefix(SAVE_LAYOUT, head), "bump SAVE_VERSION first: v%d is pinned", SAVE_VERSION)
		if !strings.has_prefix(SAVE_LAYOUT, head) {
			testing.expect(t, os.write_entire_file(SAVE_LAYOUT_PATH, transmute([]u8)live) == nil, "wrote the layout")
		}
	} else {
		have := strings.split_lines(live)
		want := strings.split_lines(SAVE_LAYOUT)
		defer delete(have)
		defer delete(want)
		for i in 0 ..< max(len(have), len(want)) {
			now := i < len(have) ? have[i] : "(nothing)"
			was := i < len(want) ? want[i] : "(nothing)"
			if now == was do continue
			testing.expectf(t, false, "saved layout moved, read the note above this test:\n  now %s\n  was %s", now, was)
			break
		}
	}
}

// Cards 112 and the post-Mole merge: the cave roamers come after master's Rain_Wisp,
// Rock_Harpy and Mole, so those load as themselves, and every roamer keeps its
// kind across a save.
@(test)
roamers_keep_their_kind_across_a_save :: proc(t: ^testing.T) {
	path :: "gnipahellir_roamer_kind_scratch.dat"
	defer os.remove(path)
	testing.expect_value(t, int(Enemy_Kind.Rain_Wisp), 8)
	testing.expect_value(t, int(Enemy_Kind.Rock_Harpy), 9)
	testing.expect_value(t, int(Enemy_Kind.Mole), 10)
	testing.expect_value(t, int(Enemy_Kind.Cave_Eel), 11)
	testing.expect_value(t, int(Enemy_Kind.Magma_Crawler), 12)
	testing.expect_value(t, int(Enemy_Kind.Stone_Grub), 13)

	gs := turret_test_state()
	defer free(gs)
	gs.enemies = {}
	kinds := []Enemy_Kind{.Rain_Wisp, .Rock_Harpy, .Mole, .Cave_Eel, .Magma_Crawler, .Stone_Grub}
	for k in kinds {
		id, _ := enemy_alloc(&gs.enemies)
		gs.enemies.data[id] = Enemy{kind = k, hp = 1, hp_max = 1, pos = {f32(40 + id*10), 20}}
	}
	testing.expect(t, save_game_to(gs, path), "save written")
	gs.enemies = {}
	testing.expect(t, load_game_from(gs, path), "save loads")
	for k, i in kinds {
		testing.expect(t, gs.enemies.active[i], "slot came back")
		testing.expect_value(t, gs.enemies.data[i].kind, k)
	}
}

// ─── Monument marks across a save (card 147) ──────────────────────────────────
//
//  v30 saves the cells golems built into monuments.  Older files kept none, so
//  their loads mark every cell a level's project shows standing.

// A finished Clay Hearth at `anchor` as an old build left it: the project
// record, the cells standing, masonry .Placed.  Cell 0 stands as natural rock
// instead and cell 1 was dug out, its mark left behind: the migration counts
// neither.
@(private="file")
old_hearth :: proc(w: ^World_Grid, p: ^Golem_Project, level: int, anchor: [2]i32) {
	p^ = {active = true, complete = true, plan = .Clay_Hearth, level = level, anchor = anchor}
	for c, i in golem_plan_table[.Clay_Hearth].cells {
		idx := grid_idx(int(anchor.x + c.off.x), int(anchor.y + c.off.y))
		w.terrain[idx] = .Void if i == 1 else c.tile
		w.tile_flags[idx] = {} if is_structure_tile[c.tile] || i == 0 else {.Placed}
	}
}

@(private="file")
expect_hearth_marked :: proc(t: ^testing.T, cells: ^Monument_Cells, level: int, anchor: [2]i32, label: string) {
	for c, i in golem_plan_table[.Clay_Hearth].cells {
		want := Tile_Type.Air if i <= 1 else c.tile
		got := cells[level][grid_idx(int(anchor.x + c.off.x), int(anchor.y + c.off.y))]
		testing.expectf(t, got == want, "%s: level %d cell %v marked %v, want %v", label, level, c.off, got, want)
	}
}

HEARTH_AT :: [2]i32{60, 40}

// The golden v28 run stamped v29, with a Hearth on the surface it stands on and
// one in the stashed sky, and a v29 grave.  Offsets are v28's and v29's, frozen.
@(test)
a_v29_save_loads_with_its_monuments_marked :: proc(t: ^testing.T) {
	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	raw := golden_bytes(t, &buf)
	(^i32)(raw_data(raw))^ = 29
	golems := (^Golem_System)(&raw[4_031_072])
	surface := (^World_Grid)(&raw[16])
	sky := (^World_Grid)(&raw[476_944 + offset_of(Level_Store, worlds) + LEVEL_SKY*size_of(World_Grid)])
	old_hearth(surface, &golems.projects[LEVEL_SURFACE], LEVEL_SURFACE, HEARTH_AT)
	old_hearth(sky, &golems.projects[LEVEL_SKY], LEVEL_SKY, HEARTH_AT + {30, 0})
	(^Grave_Record)(&raw[4_048_184])^ = {active = true, pending = true, tile = {5, 6}, level = LEVEL_SKY}

	sd := save_data_read(raw)
	defer free(sd)
	testing.expect(t, sd != nil, "the v29 run loads")
	if sd == nil do return
	expect_hearth_marked(t, &sd.monument_cells, LEVEL_SURFACE, HEARTH_AT, "v29 surface")
	expect_hearth_marked(t, &sd.monument_cells, LEVEL_SKY, HEARTH_AT + {30, 0}, "v29 sky")
	testing.expect_value(t, sd.grave.level, i32(LEVEL_SKY))
	testing.expect(t, sd.grave.pending, "a v29 grave keeps its own fields")
	testing.expect_value(t, sd.world_seed, u32(7791))
}

// v28 goes the same frozen way, its grave made on the surface.
@(test)
a_v28_save_loads_with_its_monument_marked :: proc(t: ^testing.T) {
	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	raw := golden_bytes(t, &buf)
	golems := (^Golem_System)(&raw[4_031_072])
	old_hearth((^World_Grid)(&raw[16]), &golems.projects[LEVEL_SURFACE], LEVEL_SURFACE, HEARTH_AT)
	sd := save_data_read(raw)
	defer free(sd)
	testing.expect(t, sd != nil, "the v28 run loads")
	if sd == nil do return
	expect_hearth_marked(t, &sd.monument_cells, LEVEL_SURFACE, HEARTH_AT, "v28")
	testing.expect_value(t, sd.grave.level, i32(LEVEL_SURFACE))
}

// The 1024-enemy files, v24 to v27, shrink and are marked too.
@(test)
a_v27_save_loads_with_its_monument_marked :: proc(t: ^testing.T) {
	old := new(Save_Data_1024)
	defer free(old)
	old.version = 27
	old.level_index = LEVEL_SURFACE
	old_hearth(&old.world, &old.golems.projects[LEVEL_SURFACE], LEVEL_SURFACE, HEARTH_AT)
	sd := save_data_read(mem.ptr_to_bytes(old))
	defer free(sd)
	testing.expect(t, sd != nil, "the v27 run loads")
	if sd == nil do return
	expect_hearth_marked(t, &sd.monument_cells, LEVEL_SURFACE, HEARTH_AT, "v27")
}

@(test)
a_v23_save_loads_with_its_monument_marked :: proc(t: ^testing.T) {
	path :: "gnipahellir_save_v23_monument_test.dat"
	defer os.remove(path)
	old := new(Save_Data_v23)
	defer free(old)
	old.version = 23
	old.level_index = LEVEL_SURFACE
	old_hearth(&old.world, &old.golems.projects[LEVEL_SURFACE], LEVEL_SURFACE, HEARTH_AT)
	testing.expect(t, os.write_entire_file(path, mem.ptr_to_bytes(old)) == nil, "wrote a v23 save")
	gs := turret_test_state()
	defer free(gs)
	testing.expect(t, load_game_from(gs, path), "the v23 run loads")
	expect_hearth_marked(t, &gs.monument_cells, LEVEL_SURFACE, HEARTH_AT, "v23")
}

// A v30 save carries its marks as they are, and marks nothing more: ore the
// player laid in a gold cell stays the player's.
@(test)
a_v30_save_keeps_its_monument_marks :: proc(t: ^testing.T) {
	path :: "gnipahellir_save_v30_monument_test.dat"
	defer os.remove(path)
	gs := turret_test_state()
	defer free(gs)
	old_hearth(&gs.world, &gs.golems.projects[gs.level_index], gs.level_index, HEARTH_AT)
	gs.monument_cells[LEVEL_SKY][grid_idx(7, 8)] = .Cloud
	testing.expect(t, save_game_to(gs, path), "saved")
	gs.monument_cells = {}
	testing.expect(t, load_game_from(gs, path), "loads")
	testing.expect_value(t, gs.monument_cells[LEVEL_SKY][grid_idx(7, 8)], Tile_Type.Cloud)
	for c in golem_plan_table[.Clay_Hearth].cells {
		idx := grid_idx(int(HEARTH_AT.x + c.off.x), int(HEARTH_AT.y + c.off.y))
		testing.expectf(t, gs.monument_cells[gs.level_index][idx] == .Air, "v30 marks no cell its golems did not, %v", c.off)
	}
}

// A project record off the world's edge marks nothing and breaks no load.
@(test)
an_old_save_with_a_project_off_the_world_loads :: proc(t: ^testing.T) {
	old := new(Save_Data_1024)
	defer free(old)
	old.version = 27
	old.golems.projects[LEVEL_SURFACE] = {active = true, complete = true, plan = .Clay_Hearth, anchor = {GRID_W, 0}}
	old.world.terrain[grid_idx(GRID_W - 1, 0)] = .Wood
	old.world.tile_flags[grid_idx(GRID_W - 1, 0)] = {.Placed}
	sd := save_data_read(mem.ptr_to_bytes(old))
	defer free(sd)
	testing.expect(t, sd != nil, "the run loads")
	if sd == nil do return
	for row in sd.monument_cells do for m in row do testing.expect(t, m == .Air, "nothing is marked")
}
