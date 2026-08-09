package gnipa_studio

// Names for the shared icon shapes and tier palettes.  The emitter matches an
// icon's grid/palette against these by equality and emits the constant NAME on
// a hit, an inline literal otherwise — which is how shape sharing survives
// codegen (all four sword tiers keep pointing at one SWORD_GRID).  The studio
// also reads this to say "shared by N items" in the editor.
//
// The constants themselves live in src/gen_item_icons.odin (emitted from this
// very list), but they are ordinary package-game symbols, so referencing them
// here is never a chicken-and-egg problem.

import game "../../src"

Shape_Entry :: struct {
	name: string,
	grid: game.Icon_Grid,
}

shape_registry := [?]Shape_Entry{
	{"SWORD_GRID", game.SWORD_GRID},
	{"PICKAXE_GRID", game.PICKAXE_GRID},
	{"POTION_GRID", game.POTION_GRID},
	{"SEED_GRID", game.SEED_GRID},
	{"FLOWER_GRID", game.FLOWER_GRID},
	{"WAND_GRID", game.WAND_GRID},
	{"WOOD_LOG_GRID", game.WOOD_LOG_GRID},
	{"LEAF_GRID", game.LEAF_GRID},
	{"STONE_BLOCK_GRID", game.STONE_BLOCK_GRID},
	{"GRASS_TURF_GRID", game.GRASS_TURF_GRID},
	{"DIRT_GRID", game.DIRT_GRID},
	{"DOOR_GRID", game.DOOR_GRID},
	{"BARREL_GRID", game.BARREL_GRID},
	{"PLANK_GRID", game.PLANK_GRID},
	{"ORE_GRID", game.ORE_GRID},
	{"CLOUD_STONE_GRID", game.CLOUD_STONE_GRID},
	{"CRYSTAL_GRID", game.CRYSTAL_GRID},
	{"BUCKET_GRID", game.BUCKET_GRID},
	{"BUCKET_FULL_GRID", game.BUCKET_FULL_GRID},
	{"KEY_GRID", game.KEY_GRID},
	{"CHARM_GRID", game.CHARM_GRID},
	{"HELM_GRID", game.HELM_GRID},
	{"CHESTPLATE_GRID", game.CHESTPLATE_GRID},
	{"GAUNTLETS_GRID", game.GAUNTLETS_GRID},
	{"GREAVES_GRID", game.GREAVES_GRID},
	{"BOOTS_GRID", game.BOOTS_GRID},
	{"BENCH_GRID", game.BENCH_GRID},
	{"TREE_GROWER_GRID", game.TREE_GROWER_GRID},
	{"GEM_REPLICATOR_GRID", game.GEM_REPLICATOR_GRID},
	{"SMELTER_GRID", game.SMELTER_GRID},
	{"SKY_ALTAR_GRID", game.SKY_ALTAR_GRID},
	{"RUNE_SCROLL_GRID", game.RUNE_SCROLL_GRID},
	{"FORGE_GRID", game.FORGE_GRID},
	{"RUNE_ALTAR_GRID", game.RUNE_ALTAR_GRID},
	{"BAR_GRID", game.BAR_GRID},
}

Pal_Entry :: struct {
	name: string,
	pal:  game.Icon_Palette,
}

pal_registry := [?]Pal_Entry{
	{"PAL_IRON", game.PAL_IRON},
	{"PAL_SILVER", game.PAL_SILVER},
	{"PAL_GOLD", game.PAL_GOLD},
	{"PAL_RUNIC", game.PAL_RUNIC},
}

shape_name_for :: proc(grid: game.Icon_Grid) -> string {
	for e in shape_registry do if e.grid == grid do return e.name
	return ""
}

pal_name_for :: proc(pal: game.Icon_Palette) -> string {
	for e in pal_registry do if e.pal == pal do return e.name
	return ""
}
