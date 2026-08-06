package game

// ─── Equipment interaction and deliberate reclaim ────────────────────────────

RECLAIM_HOLD_TIME :: f32(0.8)

Reclaim_Block :: enum u8 {
    None,
    Need_Pickaxe,
    Wand_Equipped,
    Loaded_Smelter,
    Loaded_Silo,
    Loaded_Barrel,
    Loaded_Miner,
    Anchored_Dimension,
    Active_Ritual,
    Permanent_Monument,
}

// Normal click on equipment means "use", never "mine". E remains the broad
// nearby interaction key; this path targets the exact clicked structure.
structure_interact :: proc(gs: ^Game_State, tile: [2]i32) {
    if gs.player.dead || !in_bounds(int(tile.x), int(tile.y)) do return
    if chebyshev(tile, player_tile(&gs.player)) > BENCH_RANGE do return

    t := get_tile(&gs.world, int(tile.x), int(tile.y))
    if !is_structure_tile[t] do return

    if st := station_at_tile(&gs.world, tile.x, tile.y); st != .None {
        eq_push(&gs.events, Event{type = .Station_Interact, payload = {int_val = i32(st)}})
        return
    }

    #partial switch t {
    case .Smelter:
        eq_push(&gs.events, Event{type = .Smelter_Interact, tile = tile})
    case .Barrel:
        eq_push(&gs.events, Event{type = .Barrel_Interact, tile = tile})
    case .Silo:
        if s := silo_at(gs, gs.level_index, tile); s != nil do silo_withdraw(gs, s)
    case .Auto_Miner:
        if gs.level_index == LEVEL_DIMENSION && gs.dimension.miner.active &&
           gs.dimension.miner.base == tile {
            miner_withdraw(gs)
        }
    case .Sky_Altar:
        if gs.level_index == LEVEL_SURFACE && gs.progression.sky_altar_pos == tile {
            p := sky_gate_portal(gs)
            level_transition(gs, &p)
        } else {
            eq_push(&gs.events, Event{type = .Ritual_Request})
        }
    case .Dimension_Spawner, .Dimension_Spawner_Gold, .Dimension_Spawner_Runic:
        if gs.level_index != LEVEL_DIMENSION {
            for kind in Dimension_Kind {
                if dimension_spawner_tile[kind] == t {
                    dimension_enter(gs, tile, kind)
                    return
                }
            }
        }
    case .Tree_Grower:
        notify(gs, "The grower works while open sky waits above")
    case .Clay_Hearth:
        eq_push(&gs.events, Event{type = .Golem_Hearth_Use, tile = tile})
    case .Golem_Depot:
        if d := golem_depot_at(gs, gs.level_index, tile); d != nil do golem_depot_withdraw(gs, d)
    case .World_Anchor:
        notify(gs, "The anchor holds this manufactured world in memory")
    case:
    }
}

structure_reclaim_block :: proc(gs: ^Game_State, tile: [2]i32) -> Reclaim_Block {
    if is_wand(gs.player.equipment[.Weapon]) do return .Wand_Equipped
    if gs.player.equipment[.Tool] != .Pickaxe do return .Need_Pickaxe

    t := get_tile(&gs.world, int(tile.x), int(tile.y))
    #partial switch t {
    case .Smelter:
        sd := &gs.world.sim_data[grid_idx(int(tile.x), int(tile.y))]
        if sd.in_count > 0 || sd.fuel_count > 0 || sd.store_count > 0 do return .Loaded_Smelter
    case .Silo:
        if s := silo_at(gs, gs.level_index, tile); s != nil && silo_total(s) > 0 do return .Loaded_Silo
    case .Barrel:
        if b := barrel_at(gs, gs.level_index, tile); b != nil && barrel_total(b) > 0 do return .Loaded_Barrel
    case .Auto_Miner:
        if gs.dimension.miner.active && gs.dimension.miner.base == tile &&
           miner_haul_total(&gs.dimension.miner) > 0 {
            return .Loaded_Miner
        }
    case .Dimension_Spawner, .Dimension_Spawner_Gold, .Dimension_Spawner_Runic:
        if gs.dimension.miner.active && gs.level_index != LEVEL_DIMENSION {
            for kind in Dimension_Kind do if dimension_spawner_tile[kind] == t &&
                kind == gs.dimension.kind {
                return .Anchored_Dimension
            }
        }
    case .Sky_Altar:
        if gs.ritual.active && gs.ritual.altar == tile do return .Active_Ritual
    case .Clay_Hearth, .Golem_Depot, .World_Anchor:
        return .Permanent_Monument
    case:
    }
    return .None
}

reclaim_block_message := [Reclaim_Block]string{
    .None               = "",
    .Need_Pickaxe       = "Equip a pickaxe to reclaim equipment",
    .Wand_Equipped      = "Equip the pickaxe - a wand cannot reclaim equipment",
    .Loaded_Smelter     = "Empty the smelter before reclaiming it",
    .Loaded_Silo        = "Empty the silo before reclaiming it",
    .Loaded_Barrel      = "Empty the barrel before reclaiming it",
    .Loaded_Miner       = "Claim the miner's haul before reclaiming it",
    .Anchored_Dimension = "The working miner anchors this spawner - reclaim it first",
    .Active_Ritual      = "The altar cannot move during a ritual",
    .Permanent_Monument = "Golem monuments are bound into the world",
}

notify_reclaim_block :: proc(gs: ^Game_State, block: Reclaim_Block) {
    if block == .None do return
    notify(gs, reclaim_block_message[block])
}

// Hold Shift + mine over one adjacent structure. Any interruption resets the
// timer; only a completed hold emits the ordinary Tile_Mined event that owns
// drops, machine cleanup, gravity and sound.
update_reclaim :: proc(gs: ^Game_State) {
    r := &gs.reclaim
    if !gs.input.reclaim || gs.player.dead || gs.game_won {
        r^ = {}
        return
    }

    tile := gs.input.mouse_tile
    changed := r.target != tile
    if changed do r^ = {target = tile}

    if !in_bounds(int(tile.x), int(tile.y)) ||
       !is_structure_tile[get_tile(&gs.world, int(tile.x), int(tile.y))] ||
       chebyshev(tile, player_tile(&gs.player)) > PICK_RANGE {
        r.active = false
        r.timer = 0
        return
    }

    block := structure_reclaim_block(gs, tile)
    if block != .None {
        if !r.blocked do notify_reclaim_block(gs, block)
        r.active = false
        r.blocked = true
        r.timer = 0
        return
    }

    r.blocked = false
    r.active = true
    r.timer += gs.delta_time
    if r.timer >= RECLAIM_HOLD_TIME {
        eq_push(&gs.events, Event{type = .Structure_Reclaim, source = PLAYER_ID, tile = tile})
        r^ = {}
    }
}
