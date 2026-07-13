package game

import rl "vendor:raylib/v55"

// ─── Item Pixel Art ───────────────────────────────────────────────────────────
//
//  Every item icon is a 12x12 character grid drawn as chunky pixels — same
//  flat, no-gradient style as the tile atlas.  Table-driven: one Item_Icon per
//  Item in item_icons; tiered gear reuses a shape grid with a tier palette
//  (iron/silver/gold/runic), so a new tier is one palette line, not new art.
//
//  Grid characters resolve through the icon's palette first, then the shared
//  colors in icon_pixel:
//      B D L A a   base / dark / light / accent / accent2 (per-icon palette)
//      W h H g S s t   white, wood dark/light, gold trim, stone base/dark/light
//      .               transparent
//
//  draw_item_icon is render-side only: reads tables, never touches Game_State.

ICON_GRID :: 12

Icon_Grid :: [ICON_GRID]string

Icon_Palette :: struct {
	base, dark, light, accent, accent2: rl.Color,
}

// Shared colors (grid chars without a palette slot).
ICON_WOOD_DARK   :: rl.Color{110, 75, 45, 255}
ICON_WOOD_LIGHT  :: rl.Color{185, 145, 95, 255}
ICON_GOLD_TRIM   :: rl.Color{205, 172, 78, 255}
ICON_STONE       :: rl.Color{130, 130, 136, 255}
ICON_STONE_DARK  :: rl.Color{94, 94, 102, 255}
ICON_STONE_LIGHT :: rl.Color{168, 168, 176, 255}

// Metal tiers, echoing the old flat item_table colors so gear stays readable.
PAL_IRON   :: Icon_Palette{{150, 150, 165, 255}, {100, 100, 115, 255}, {198, 198, 212, 255}, {}, {}}
PAL_SILVER :: Icon_Palette{{205, 205, 225, 255}, {148, 148, 175, 255}, {242, 242, 252, 255}, {}, {}}
PAL_GOLD   :: Icon_Palette{{235, 195, 60, 255}, {178, 138, 28, 255}, {255, 232, 130, 255}, {}, {}}
PAL_RUNIC  :: Icon_Palette{{210, 130, 255, 255}, {148, 78, 200, 255}, {240, 195, 255, 255}, {}, {}}

// ─── Shape grids (shared between items via palettes) ─────────────────────────

SWORD_GRID :: Icon_Grid{
	"......L.....",
	"......LD....",
	"......LD....",
	"......LD....",
	"......LD....",
	"......LD....",
	"......LD....",
	".....gggg...",
	"......hh....",
	"......hh....",
	"......gg....",
	"............",
}

PICKAXE_GRID :: Icon_Grid{
	"..DBBBBBBD..",
	".BD..hh..DB.",
	".B...hh...B.",
	".D...hh...D.",
	".....hh.....",
	".....hh.....",
	".....hh.....",
	".....hh.....",
	".....hh.....",
	".....hh.....",
	"............",
	"............",
}

POTION_GRID :: Icon_Grid{
	".....hh.....",
	".....hh.....",
	"....DLLD....",
	"....DBBD....",
	"...DBBBBD...",
	"..DBBBBBBD..",
	"..DBWBBBBD..",
	"..DBBBBBBD..",
	"..DBBBBBBD..",
	"...DBBBBD...",
	"....DDDD....",
	"............",
}

// Diagonal shaft, crystal tip — the tip's accent is the wand's tier.
WAND_GRID :: Icon_Grid{
	".........LA.",
	"........LAA.",
	".......hAL..",
	"......hh....",
	".....hh.....",
	"....hh......",
	"...hh.......",
	"..hh........",
	".hh.........",
	".h..........",
	"............",
	"............",
}

WOOD_LOG_GRID :: Icon_Grid{
	"............",
	"..DDDDDDDD..",
	".DBBBBBBBBD.",
	".DBAAABBBBD.",
	".DBABABBABD.",
	".DBAAABBBBD.",
	".DBBBBBABBD.",
	".DBBBBBBBBD.",
	"..DDDDDDDD..",
	"............",
	"............",
	"............",
}

LEAF_GRID :: Icon_Grid{
	".........h..",
	"........h...",
	"....DDDh....",
	"..DBBBLB....",
	".DBBBLBBD...",
	".DBBLBBBBD..",
	".DBLBBBBBD..",
	".DLBBBBBD...",
	".LBBBBBD....",
	".BBBBDD.....",
	".BDDD.......",
	"............",
}

STONE_BLOCK_GRID :: Icon_Grid{
	"............",
	"..tttttttt..",
	".tSSSSSSSSs.",
	".tSSsSSSSSs.",
	".tSSSSSStSs.",
	".tSSSSSSSSs.",
	".tSsSSSSSSs.",
	".tSSSSStSSs.",
	".tSSSSSSSSs.",
	".ssssssssss.",
	"............",
	"............",
}

// Grass cap (B/D) over a dirt block (A/a).
GRASS_TURF_GRID :: Icon_Grid{
	"............",
	"..BBBBBBBB..",
	".BBDBBBBBBD.",
	".DBBBBDBBBD.",
	".aAAAAAAAAa.",
	".aAaAAAAaAa.",
	".aAAAAAAAAa.",
	".aAAaAAAAAa.",
	".aAAAAAaAAa.",
	".aAAAAAAAAa.",
	".aaaaaaaaaa.",
	"............",
}

// Two boards, grain (D) and nails (A).
PLANK_GRID :: Icon_Grid{
	"............",
	"............",
	".BBBBBBBBBB.",
	".BDBBBBBBAB.",
	".BBBBBDBBBB.",
	".DDDDDDDDDD.",
	".BBBBBBBBBB.",
	".BABBDBBBBB.",
	".BBBBBBBBDB.",
	"............",
	"............",
	"............",
}

// Rock chunk (B/D) with metal veins (A/a) and a sparkle.
ORE_GRID :: Icon_Grid{
	"............",
	"....DDDD....",
	"..DDBBBBDD..",
	".DBBaBBBBAD.",
	".DBAABBaBBD.",
	".DBBBWABBBD.",
	".DBaBBAABBD.",
	".DBBABBBaBD.",
	"..DBBaBBDD..",
	"...DDDDDD...",
	"............",
	"............",
}

CLOUD_STONE_GRID :: Icon_Grid{
	"............",
	"............",
	"....LLL.....",
	"..LLBBBLL...",
	".LBBBBBBBL..",
	".LBBBBBBBBL.",
	"..DBBBBBBD..",
	"...DDDDDD...",
	"............",
	"............",
	"............",
	"............",
}

CRYSTAL_GRID :: Icon_Grid{
	"......W.....",
	".....LA.....",
	".....LA.....",
	"....LLAA....",
	"....LLAA....",
	"...ALLAA....",
	"...ALLAAa...",
	"..W.LLAA.a..",
	"....LLAA.a..",
	".....AA.....",
	"............",
	"............",
}

BUCKET_GRID :: Icon_Grid{
	"............",
	".D........D.",
	"..D......D..",
	"..DDDDDDDD..",
	".DLLLLLLLLD.",
	".DBBBBBBBBD.",
	".DBBBBBBBBD.",
	"..DBBBBBBD..",
	"..DBBBBBBD..",
	"...DDDDDD...",
	"............",
	"............",
}

KEY_GRID :: Icon_Grid{
	"....BBBB....",
	"...BB..BB...",
	"...BB..BB...",
	"....BBBB....",
	".....BD.....",
	".....BD.....",
	".....BD.....",
	".....BD.BB..",
	".....BD.BB..",
	".....BBBBB..",
	"............",
	"............",
}

// Cord (h), gold setting (g), gem (A) with a shine (L).
CHARM_GRID :: Icon_Grid{
	"...h.....h..",
	"..h.......h.",
	"..h.......h.",
	"..h.......h.",
	"...h.....h..",
	"....h...h...",
	".....ggg....",
	"....gAAg....",
	"....gALAg...",
	"....gAAg....",
	".....gg.....",
	"............",
}

HELM_GRID :: Icon_Grid{
	"............",
	"............",
	"...DBBBBD...",
	"..DBLLLLBD..",
	"..BBLLLLBB..",
	"..BBBBBBBB..",
	"..BBBBBBBB..",
	"..BD.BB.DB..",
	"..BD.BB.DB..",
	"..DD.BB.DD..",
	"............",
	"............",
}

CHESTPLATE_GRID :: Icon_Grid{
	"............",
	".DBBD..DBBD.",
	".BBBBDDBBBB.",
	".BLBBBBBBLB.",
	".BBBBBBBBBB.",
	"..BBLBBLBB..",
	"..BBBBBBBB..",
	"..BBBBBBBB..",
	"...BBBBBB...",
	"...DBBBBD...",
	"............",
	"............",
}

GAUNTLETS_GRID :: Icon_Grid{
	"............",
	"..BBB..BBB..",
	"..BBBD.BBBD.",
	"..BBBD.BBBD.",
	"..LBBD.LBBD.",
	"..LBBD.LBBD.",
	"..DBBD.DBBD.",
	"..BBBB.BBBB.",
	"..DDDD.DDDD.",
	"............",
	"............",
	"............",
}

GREAVES_GRID :: Icon_Grid{
	"............",
	"..DBBD.DBBD.",
	"..BLBB.BLBB.",
	"..BLBB.BLBB.",
	"..BLBB.BLBB.",
	"..BLBB.BLBB.",
	"..BBBB.BBBB.",
	"..DBBD.DBBD.",
	"..DBBD.DBBD.",
	"............",
	"............",
	"............",
}

BOOTS_GRID :: Icon_Grid{
	"............",
	"............",
	"...BBB.BBB..",
	"...BBB.BBB..",
	"...BBB.BBB..",
	"...LBB.BBL..",
	"..DBBB.BBBD.",
	".DBBBB.BBBBD",
	".DDDDD.DDDDD",
	"............",
	"............",
	"............",
}

// Workbench: mallet resting on a plank top, two legs.
BENCH_GRID :: Icon_Grid{
	"...ss.......",
	"..ssss......",
	"....hh......",
	".HHHHHHHHHH.",
	".hHHHHHHHHh.",
	"...hh..hh...",
	"...hh..hh...",
	"...hh..hh...",
	"............",
	"............",
	"............",
	"............",
}

// Sapling (B/D) in a pot (A/a).
TREE_GROWER_GRID :: Icon_Grid{
	"............",
	"....BBB.....",
	"...BDBBB....",
	"....BBB.....",
	".....h......",
	".....h......",
	"...aAAAa....",
	"...aAAAa....",
	"....aaa.....",
	"............",
	"............",
	"............",
}

// Furnace body (B/D) with a fire window (A/a) and a gold cap.
SMELTER_GRID :: Icon_Grid{
	".....gg.....",
	"..DDDDDDDD..",
	"..DBBBBBBD..",
	"..DBBBBBBD..",
	"..DBAAAABD..",
	"..DBAaaABD..",
	"..DBAAAABD..",
	"..DBBBBBBD..",
	"..DBBBBBBD..",
	"..DDDDDDDD..",
	"............",
	"............",
}

// Blue crystal floating over a stone pedestal.
SKY_ALTAR_GRID :: Icon_Grid{
	".....AA.....",
	"....ALLA....",
	"...ALLLLA...",
	"....ALLA....",
	".....AA.....",
	"....SSSS....",
	"....SSSS....",
	"...SSSSSS...",
	"..SSSSSSSS..",
	"..ssssssss..",
	"............",
	"............",
}

// Rolled scroll (B parchment, D rolled ends) with a seal (A).
BLUEPRINT_GRID :: Icon_Grid{
	"............",
	"............",
	".DDBBBBBBDD.",
	".DBBBBBBBBD.",
	".DBBAABBBBD.",
	".DBBAABBBBD.",
	".DBBAABBBBD.",
	".DBBBBBBBBD.",
	".DDBBBBBBDD.",
	"............",
	"............",
	"............",
}

// Anvil (B/D/L dark iron) with an ember glint (A) on the face.
FORGE_GRID :: Icon_Grid{
	"............",
	"............",
	"..LLLLLLLLL.",
	"..BBBABBBBL.",
	"...DBBBBD...",
	"....DBBD....",
	"....DBBD....",
	"...DBBBBD...",
	"..DBBBBBBD..",
	"..DDDDDDDD..",
	"............",
	"............",
}

// Stone altar carved with glowing runes (A).
RUNE_ALTAR_GRID :: Icon_Grid{
	"............",
	".tttttttttt.",
	".SSSSSSSSSS.",
	"...SSSSSS...",
	"...SASSAS...",
	"...SSAASS...",
	"...SASSAS...",
	"...SSSSSS...",
	"..SSSSSSSS..",
	".ssssssssss.",
	"............",
	"............",
}

// Cast ingot: trapezoid slab, lit top edge — tier palettes color the metal.
BAR_GRID :: Icon_Grid{
	"............",
	"............",
	"............",
	"...LLLLLL...",
	"..LBBBBBBD..",
	".LBBBBBBBBD.",
	".BBBBBBBBBD.",
	".DDDDDDDDDD.",
	"............",
	"............",
	"............",
	"............",
}

// ─── Per-item icon table (grid + palette) ─────────────────────────────────────

Item_Icon :: struct {
	grid: Icon_Grid,
	pal:  Icon_Palette,
}

@(rodata)
item_icons := [Item]Item_Icon{
	.None             = {},
	.Sword            = {SWORD_GRID, PAL_IRON},
	.Pickaxe          = {PICKAXE_GRID, PAL_IRON},
	.Potion_Health    = {POTION_GRID, {{220, 40, 40, 255}, {150, 22, 22, 255}, {255, 130, 130, 255}, {}, {}}},
	.Potion_Mana      = {POTION_GRID, {{55, 55, 225, 255}, {30, 30, 150, 255}, {140, 140, 255, 255}, {}, {}}},
	.Mine_Wand        = {WAND_GRID, {{}, {}, {210, 140, 240, 255}, {160, 60, 200, 255}, {}}},
	.Mine_Wand_Silver = {WAND_GRID, {{}, {}, {242, 242, 252, 255}, {205, 205, 225, 255}, {}}},
	.Mine_Wand_Gold   = {WAND_GRID, {{}, {}, {255, 232, 130, 255}, {235, 195, 60, 255}, {}}},
	.Wood_Log         = {WOOD_LOG_GRID, {{165, 120, 70, 255}, {95, 62, 36, 255}, {}, {125, 88, 48, 255}, {}}},
	.Leaf             = {LEAF_GRID, {{58, 158, 48, 255}, {34, 108, 28, 255}, {112, 208, 88, 255}, {}, {}}},
	.Stone_Block      = {STONE_BLOCK_GRID, {}},
	.Grass_Turf       = {GRASS_TURF_GRID, {{56, 168, 56, 255}, {36, 126, 36, 255}, {}, {122, 86, 54, 255}, {92, 62, 38, 255}}},
	.Plank            = {PLANK_GRID, {{180, 140, 90, 255}, {110, 80, 48, 255}, {}, {125, 125, 132, 255}, {}}},
	.Iron_Ore         = {ORE_GRID, {{130, 130, 136, 255}, {94, 94, 102, 255}, {}, {190, 128, 95, 255}, {148, 94, 68, 255}}},
	.Silver_Ore       = {ORE_GRID, {{130, 130, 136, 255}, {94, 94, 102, 255}, {}, {224, 224, 242, 255}, {168, 168, 195, 255}}},
	.Gold_Ore         = {ORE_GRID, {{130, 130, 136, 255}, {94, 94, 102, 255}, {}, {240, 200, 55, 255}, {188, 148, 32, 255}}},
	.Gold_Rare_Ore    = {ORE_GRID, {{146, 138, 118, 255}, {108, 100, 82, 255}, {}, {255, 222, 70, 255}, {212, 168, 40, 255}}},
	.Crafting_Bench   = {BENCH_GRID, {}},
	.Tree_Grower      = {TREE_GROWER_GRID, {{70, 170, 60, 255}, {40, 120, 35, 255}, {}, {150, 100, 55, 255}, {105, 70, 40, 255}}},
	.Smelter          = {SMELTER_GRID, {{105, 95, 95, 255}, {68, 60, 60, 255}, {}, {230, 120, 35, 255}, {255, 200, 60, 255}}},
	.Iron_Bucket      = {BUCKET_GRID, PAL_IRON},
	.Hell_Key         = {KEY_GRID, {{220, 30, 60, 255}, {150, 16, 38, 255}, {}, {}, {}}},
	.Blueprint_A      = {BLUEPRINT_GRID, {{226, 206, 162, 255}, {188, 164, 118, 255}, {}, {178, 60, 42, 255}, {}}},
	.Blueprint_B      = {BLUEPRINT_GRID, {{226, 206, 162, 255}, {188, 164, 118, 255}, {}, {178, 60, 42, 255}, {}}},
	.Blueprint_C      = {BLUEPRINT_GRID, {{226, 206, 162, 255}, {188, 164, 118, 255}, {}, {178, 60, 42, 255}, {}}},
	.Sky_Blueprint    = {BLUEPRINT_GRID, {{150, 195, 235, 255}, {112, 152, 196, 255}, {}, {240, 250, 255, 255}, {}}},
	.Sky_Altar        = {SKY_ALTAR_GRID, {{}, {}, {190, 230, 255, 255}, {90, 180, 255, 255}, {}}},
	.Cloud_Stone      = {CLOUD_STONE_GRID, {{225, 235, 250, 255}, {172, 186, 215, 255}, {250, 252, 255, 255}, {}, {}}},
	.Aether_Crystal   = {CRYSTAL_GRID, {{}, {}, {198, 255, 220, 255}, {110, 225, 160, 255}, {66, 168, 108, 255}}},
	.Runic_Sky_Ore    = {ORE_GRID, {{168, 168, 190, 255}, {126, 126, 150, 255}, {}, {255, 140, 255, 255}, {198, 88, 220, 255}}},
	.Aether_Charm     = {CHARM_GRID, {{}, {}, {210, 255, 230, 255}, {110, 230, 170, 255}, {}}},
	.Silver_Sword     = {SWORD_GRID, PAL_SILVER},
	.Gold_Sword       = {SWORD_GRID, PAL_GOLD},
	.Iron_Helm          = {HELM_GRID, PAL_IRON},
	.Silver_Helm        = {HELM_GRID, PAL_SILVER},
	.Gold_Helm          = {HELM_GRID, PAL_GOLD},
	.Iron_Chestplate    = {CHESTPLATE_GRID, PAL_IRON},
	.Silver_Chestplate  = {CHESTPLATE_GRID, PAL_SILVER},
	.Gold_Chestplate    = {CHESTPLATE_GRID, PAL_GOLD},
	.Iron_Gauntlets     = {GAUNTLETS_GRID, PAL_IRON},
	.Silver_Gauntlets   = {GAUNTLETS_GRID, PAL_SILVER},
	.Gold_Gauntlets     = {GAUNTLETS_GRID, PAL_GOLD},
	.Iron_Greaves       = {GREAVES_GRID, PAL_IRON},
	.Silver_Greaves     = {GREAVES_GRID, PAL_SILVER},
	.Gold_Greaves       = {GREAVES_GRID, PAL_GOLD},
	.Iron_Boots         = {BOOTS_GRID, PAL_IRON},
	.Silver_Boots       = {BOOTS_GRID, PAL_SILVER},
	.Gold_Boots         = {BOOTS_GRID, PAL_GOLD},
	.Dvergr_Forge     = {FORGE_GRID, {{105, 105, 125, 255}, {66, 66, 84, 255}, {150, 150, 172, 255}, {255, 140, 40, 255}, {}}},
	.Rune_Altar       = {RUNE_ALTAR_GRID, {{}, {}, {}, {170, 110, 235, 255}, {}}},
	.Mine_Wand_Runic  = {WAND_GRID, {{}, {}, {255, 190, 255, 255}, {230, 110, 250, 255}, {}}},
	.Runic_Sword      = {SWORD_GRID, PAL_RUNIC},
	.Runic_Helm       = {HELM_GRID, PAL_RUNIC},
	.Runic_Chestplate = {CHESTPLATE_GRID, PAL_RUNIC},
	.Runic_Gauntlets  = {GAUNTLETS_GRID, PAL_RUNIC},
	.Runic_Greaves    = {GREAVES_GRID, PAL_RUNIC},
	.Runic_Boots      = {BOOTS_GRID, PAL_RUNIC},
	.Iron_Bar         = {BAR_GRID, PAL_IRON},
	.Silver_Bar       = {BAR_GRID, PAL_SILVER},
	.Gold_Bar         = {BAR_GRID, PAL_GOLD},
}

// ─── Drawing ─────────────────────────────────────────────────────────────────

// Resolve one grid character: the icon palette's slots first, shared colors
// second.  ok=false → transparent, draw nothing.
icon_pixel :: proc(pal: Icon_Palette, ch: u8) -> (col: rl.Color, ok: bool) {
	switch ch {
	case 'B': col = pal.base
	case 'D': col = pal.dark
	case 'L': col = pal.light
	case 'A': col = pal.accent
	case 'a': col = pal.accent2
	case 'W': col = rl.WHITE
	case 'h': col = ICON_WOOD_DARK
	case 'H': col = ICON_WOOD_LIGHT
	case 'g': col = ICON_GOLD_TRIM
	case 'S': col = ICON_STONE
	case 's': col = ICON_STONE_DARK
	case 't': col = ICON_STONE_LIGHT
	case:     return {}, false // '.' and anything unmapped
	}
	return col, col.a != 0
}

// Item icon for UI: the item's pixel grid scaled to a size x size box.
// alpha dims the whole icon (crafting results that aren't craftable yet).
// Items without art fall back to the old flat item_table color.
draw_item_icon :: proc(it: Item, x, y, size: i32, alpha: u8 = 255) {
	icon := &item_icons[it]
	if icon.grid[0] == "" {
		col := item_table[it].color
		col.a = min(col.a, alpha)
		rl.DrawRectangle(x, y, size, size, col)
		return
	}
	cell := f32(size) / ICON_GRID
	for row, gy in icon.grid {
		for gx in 0 ..< len(row) {
			col, ok := icon_pixel(icon.pal, row[gx])
			if !ok do continue
			col.a = alpha
			rl.DrawRectangleRec(
				{f32(x) + f32(gx) * cell, f32(y) + f32(gy) * cell, cell, cell},
				col,
			)
		}
	}
}
