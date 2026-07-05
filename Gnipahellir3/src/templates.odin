package game

// ─── Structure Build Templates ────────────────────────────────────────────────
//
//  A player-built structure can require a foundation of the right blocks beneath
//  it before it can be placed.  A template is ASCII art anchored on its capstone
//  marker 'A'; every other glyph names a tile that must already be present.
//
//  There is one template per progression tier, so each blueprint raises a
//  grander altar.  To add or change one you touch only this file: extend the
//  legend in `structure_template_cell`, then draw the rows in
//  `structure_templates`.  Placement (placement.odin) and the blueprint overlay
//  (ui.odin) read these tables, so nothing else needs to change.
//
//  (Distinct from enemy.odin's Build_Template, which is the builders' den shell.)
//
//    Legend:  A capstone (Sky Altar)   S Stone   W Wood   I Silver   G Gold

Structure_Cell_Kind :: enum { Empty, Support, Capstone }

// The legend — one glyph's meaning.  Single source of truth for validating a
// build AND drawing its diagram.  `tile` is the terrain a Support cell needs.
structure_template_cell :: proc(glyph: rune) -> (tile: Tile_Type, kind: Structure_Cell_Kind) {
    switch glyph {
    case 'S': return .Stone,      .Support
    case 'W': return .Wood,       .Support
    case 'I': return .Silver_Ore, .Support
    case 'G': return .Gold_Ore,   .Support
    case 'A': return .Air,        .Capstone   // target tile; `tile` unused here
    case:     return .Air,        .Empty
    }
}

Structure_Template :: struct {
    capstone: Item,
    name:     string,
    rows:     []string,   // top-to-bottom; exactly one 'A' marks the capstone
}

// One template per progression tier — each blueprint raises a grander altar.
@(rodata)
structure_templates := [MAX_PROGRESSION_TIERS]Structure_Template{
    { // Tier A → cave 2: a humble altar of stone and wood
        capstone = .Sky_Altar,
        name     = "Stone Altar",
        rows     = {
            "  A  ",
            " WWW ",
            "SSSSS",
        },
    },
    { // Tier B → cave 3: silver and gold set upon the rock
        capstone = .Sky_Altar,
        name     = "Silver-Gold Altar",
        rows     = {
            "   A   ",
            "  GGG  ",
            " ISISI ",
            "SSSSSSS",
        },
    },
    { // Tier C → the final depths: a crown of gold
        capstone = .Sky_Altar,
        name     = "Golden Altar",
        rows     = {
            "   A   ",
            "  GGG  ",
            " GISIG ",
            "SSSSSSS",
        },
    },
}

// The template the player must build to place `item` right now: the Sky Altar is
// gated by the active tier's foundation (defaulting to tier A's).  nil if the
// item isn't a templated structure.
structure_template_for :: proc(gs: ^Game_State, item: Item) -> ^Structure_Template {
    if item != .Sky_Altar do return nil
    tier := blueprint_active_tier(gs)
    if tier < 0 do tier = 0
    return &structure_templates[tier]
}

// The 'A' cell's (col, row): the anchor every other cell is measured against.
structure_template_anchor :: proc(tpl: ^Structure_Template) -> (col, row: int) {
    for line, r in tpl.rows {
        for glyph, c in line {
            if glyph == 'A' do return c, r
        }
    }
    return 0, 0
}

// Are all the template's support tiles present for a capstone placed at world
// (ax, ay)?  On failure, reports what tile the first offending cell needs.
structure_template_satisfied :: proc(w: ^World_Grid, tpl: ^Structure_Template, ax, ay: int) -> (ok: bool, want: Tile_Type) {
    acol, arow := structure_template_anchor(tpl)
    for line, r in tpl.rows {
        for glyph, c in line {
            tile, kind := structure_template_cell(glyph)
            if kind != .Support do continue
            wx := ax + (c - acol)
            wy := ay + (r - arow)
            if !in_bounds(wx, wy) || get_tile(w, wx, wy) != tile {
                return false, tile
            }
        }
    }
    return true, .Air
}

// Does the template use this support tile anywhere?  Drives the overlay legend.
structure_template_uses :: proc(tpl: ^Structure_Template, tile: Tile_Type) -> bool {
    for line in tpl.rows {
        for glyph in line {
            t, kind := structure_template_cell(glyph)
            if kind == .Support && t == tile do return true
        }
    }
    return false
}
