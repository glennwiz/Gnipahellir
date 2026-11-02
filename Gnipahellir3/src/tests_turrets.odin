package game

import "core:os"
import "core:strings"
import "core:testing"

// ─── Turret patterns: every head, table-driven ────────────────────────────────
//
//  A new turret is a row here too.  pillars is written out, not read from
//  turret_table, so the pattern itself is pinned.

Turret_Head_Case :: struct {
    tile:    Tile_Type,
    item:    Item,
    gate:    Item,
    pillars: int,
}

@(rodata)
turret_heads := [?]Turret_Head_Case{
    {.Flame_Turret, .Flame_Head, .Iron_Bar, 1},
    {.Water_Turret, .Water_Head, .Iron_Bar, 1},
    {.Earth_Turret, .Earth_Head, .Iron_Bar, 1},
    {.Rainbow_Laser, .Rainbow_Laser, .Diamond, 2},
}

TT_X :: 60
TT_Y :: SURFACE_Y - 1

// A built turret in the open: pillars from the ground up, the head on top.
tt_build :: proc(gs: ^Game_State, c: Turret_Head_Case) -> (head_y: int) {
    turret_test_site(gs, TT_X, TT_Y)
    head_y = TT_Y - c.pillars
    for i in 0 ..< c.pillars do set_tile(&gs.world, TT_X, TT_Y - i, .Turret_Pillar)
    set_tile(&gs.world, TT_X, head_y, c.tile)
    return
}

tt_last_note :: proc(t: ^testing.T, gs: ^Game_State, loc := #caller_location) -> string {
    testing.expect(t, gs.notify.count > 0, "a note", loc = loc)
    if gs.notify.count == 0 do return ""
    n := &gs.notify.items[gs.notify.count - 1]
    return string(n.text[:n.len])
}

tt_craft_through_the_handler :: proc(t: ^testing.T, item, gate: Item, loc := #caller_location) {
    gs := turret_test_state()
    defer free(gs)
    turret_test_site(gs, TT_X, TT_Y)
    set_tile(&gs.world, int(gs.player.pos.x) - 1, TT_Y, .Crafting_Bench)
    idx := -1
    for r, i in recipe_table do if r.result == item do idx = i
    testing.expectf(t, idx >= 0, "%v has a recipe", item, loc = loc)
    if idx < 0 do return
    r := &recipe_table[idx]
    testing.expect_value(t, r.station, Station.Bench, loc = loc)

    // The card stays hidden until its gate is in the bag.
    update_recipe_unlocks(gs)
    testing.expectf(t, !recipe_revealed(&gs.progression, item), "%v shows too early", item, loc = loc)
    inventory_insert(&gs.player.inventory, gate, 1)
    update_recipe_unlocks(gs)
    testing.expectf(t, recipe_revealed(&gs.progression, item), "%v stays hidden", item, loc = loc)
    inventory_remove(&gs.player.inventory, gate, 1)

    // The real handler spends the ingredients and banks the part.
    for ing in r.ingredients do if ing.item != .None {
        inventory_insert(&gs.player.inventory, ing.item, ing.count)
    }
    eq_push(&gs.events, Event{type = .Craft_Request, payload = {int_val = i32(idx)}})
    process_events(gs)
    eq_clear(&gs.events)
    testing.expect_value(t, inventory_count(&gs.player.inventory, item), 1, loc = loc)
    for ing in r.ingredients do if ing.item != .None {
        testing.expect_value(t, inventory_count(&gs.player.inventory, ing.item), 0, loc = loc)
    }
}

@(test)
turret_parts_are_hidden_then_crafted_at_the_bench :: proc(t: ^testing.T) {
    tt_craft_through_the_handler(t, .Turret_Pillar, .Iron_Bar)
    for c in turret_heads do tt_craft_through_the_handler(t, c.item, c.gate)
}

// Rows a part needs to exist in the world.  Structure status is what the whole
// game asks: the pick's Shift-reclaim, wands and golems refusing, wave hunters.
tt_expect_part :: proc(t: ^testing.T, tile: Tile_Type, item: Item, loc := #caller_location) {
    testing.expectf(t, is_structure_tile[tile], "%v must be a structure", tile, loc = loc)
    testing.expectf(t, station_glow[tile].a != 0, "%v has no glow row, so it draws no icon", tile, loc = loc)
    testing.expectf(t, {.Solid, .Mineable, .Placeable} <= terrain_table[tile].flags, "%v flags", tile, loc = loc)
    testing.expect_value(t, terrain_table[tile].drop_item, item, loc = loc)
    testing.expect_value(t, item_table[item].place_tile, tile, loc = loc)
    testing.expectf(t, item_icons[item].grid[0] != "", "%v has no icon", item, loc = loc)
    testing.expectf(t, item_table[item].desc != "", "%v has no text", item, loc = loc)
}

@(test)
every_turret_part_has_its_rows :: proc(t: ^testing.T) {
    tt_expect_part(t, .Turret_Pillar, .Turret_Pillar)
    for c in turret_heads do tt_expect_part(t, c.tile, c.item)
    testing.expect(t, tile_on_tick[.Turret_Pillar] == nil, "a pillar alone does nothing")
}

@(test)
every_head_refuses_without_its_pillars_and_says_so :: proc(t: ^testing.T) {
    for c in turret_heads {
        gs := turret_test_state()
        defer free(gs)
        turret_test_site(gs, TT_X, TT_Y)
        testing.expectf(t, turret_table[c.tile].refusal != "", "%v has no refusal", c.tile)

        // Every height short of the pattern refuses with the head's own note.
        for built in 0 ..< c.pillars {
            y := TT_Y - built
            turret_test_place(gs, c.item, TT_X, y)
            testing.expect_value(t, get_tile(&gs.world, TT_X, y), Tile_Type.Air)
            testing.expect_value(t, tt_last_note(t, gs), turret_table[c.tile].refusal)
            testing.expect_value(t, inventory_count(&gs.player.inventory, c.item), 1)
            turret_test_place(gs, .Turret_Pillar, TT_X, y)
            testing.expect_value(t, get_tile(&gs.world, TT_X, y), Tile_Type.Turret_Pillar)
        }
        turret_test_place(gs, c.item, TT_X, TT_Y - c.pillars)
        testing.expect_value(t, get_tile(&gs.world, TT_X, TT_Y - c.pillars), c.tile)
        testing.expect_value(t, inventory_count(&gs.player.inventory, c.item), 0)
    }
}

// A head reaches its range and no further, shows something on the shot, and a
// short-range head stays inside the laser's reach.
@(test)
every_head_reaches_its_range_and_no_further :: proc(t: ^testing.T) {
    for c in turret_heads {
        rule := turret_table[c.tile]
        testing.expectf(t, tile_on_tick[c.tile] != nil, "%v must tick", c.tile)
        testing.expectf(t, rule.range <= LASER_RANGE, "%v outranges the laser", c.tile)
        testing.expectf(t, rule.cooldown > 0, "%v has no cooldown", c.tile)

        for inside in ([2]bool{false, true}) {
            gs := turret_test_state()
            defer free(gs)
            head_y := tt_build(gs, c)
            gs.world.sim_data[grid_idx(TT_X, head_y)].growth_timer = rule.cooldown  // charged
            reach := inside ? rule.range - 0.5 : rule.range + 0.5
            id := turret_test_enemy(gs, TT_X + 0.5 + reach, f32(head_y) + 0.5)
            update_sim(gs)  // one tick: motes counted before any hit adds blood
            motes := gs.particles.count
            process_events(gs)
            eq_clear(&gs.events)
            turret_test_run(gs, 0.1)
            touched := gs.enemies.data[id].hp < 50 || gs.enemy_status[id] != {}
            testing.expectf(t, touched == inside, "%v at %v tiles: touched %v", c.tile, reach, touched)
            testing.expectf(t, (motes > 0) == inside, "%v at %v tiles: %d motes", c.tile, reach, motes)
        }
    }
}

// Any part taken returns every part, by pick or by a raider's smash.
@(test)
every_head_comes_apart_whole :: proc(t: ^testing.T) {
    for c in turret_heads do for at in 0 ..= c.pillars do for smash in ([2]bool{false, true}) {
        gs := turret_test_state()
        defer free(gs)
        head_y := tt_build(gs, c)
        y := head_y + at
        if smash {
            smash_tile(gs, TT_X, y)
        } else {
            eq_push(&gs.events, Event{type = .Tile_Mined, source = PLAYER_ID, tile = {TT_X, i32(y)}})
            process_events(gs)
            eq_clear(&gs.events)
        }
        testing.expect_value(t, turret_ground_count(gs, c.item), 1)
        testing.expect_value(t, turret_ground_count(gs, .Turret_Pillar), c.pillars)
        for dy in 0 ..= c.pillars do testing.expect(t, !is_solid(&gs.world, TT_X, head_y + dy), "the column is clear")
    }
}

@(test)
a_held_reclaim_takes_a_fused_turret_apart :: proc(t: ^testing.T) {
    for c in turret_heads do for at in 0 ..= c.pillars {
        gs := turret_test_state()
        defer free(gs)
        head_y := tt_build(gs, c)
        gs.player.inventory.slots[MAX_INVENTORY - 2] = {.Pickaxe, 1}
        gs.player.inventory.selected = MAX_INVENTORY - 2
        gs.player.pos = {TT_X + 1, f32(head_y + at) - PLAYER_H + 1}
        gs.input.reclaim = true
        gs.input.mouse_tile = {TT_X, i32(head_y + at)}
        for _ in 0 ..< int(RECLAIM_HOLD_TIME / gs.delta_time) + 2 {
            update_reclaim(gs)
            process_events(gs)
            eq_clear(&gs.events)
        }
        testing.expect_value(t, turret_ground_count(gs, c.item), 1)
        testing.expect_value(t, turret_ground_count(gs, .Turret_Pillar), c.pillars)
    }
}

// Taking one part must clean the other cells as handle_tile_mined cleans its
// own: a new tile there inherits nothing, and what rested on the turret falls.
@(test)
a_loosened_part_leaves_a_clean_cell :: proc(t: ^testing.T) {
    for c in turret_heads do for at in 0 ..= c.pillars {
        gs := turret_test_state()
        defer free(gs)
        head_y := tt_build(gs, c)
        set_tile(&gs.world, TT_X, head_y - 1, .Wood)
        for dy in 0 ..= c.pillars {
            idx := grid_idx(TT_X, head_y + dy)
            gs.world.tile_flags[idx] += {.Placed, .Golem_Placed, .Golem_Marked}
            gs.world.sim_data[idx].growth_timer = 0.3
        }
        eq_push(&gs.events, Event{type = .Tile_Mined, source = PLAYER_ID, tile = {TT_X, i32(head_y + at)}})
        process_events(gs)
        eq_clear(&gs.events)
        for dy in 0 ..= c.pillars {
            idx := grid_idx(TT_X, head_y + dy)
            testing.expect_value(t, gs.world.tile_flags[idx] & {.Placed, .Golem_Placed, .Golem_Marked}, Tile_Flags{})
            testing.expect_value(t, gs.world.sim_data[idx], Sim_Tile_Data{})
        }
        testing.expect(t, get_tile(&gs.world, TT_X, head_y - 1) != .Wood, "what rested on the head falls")
    }
}

// The head fires once a cooldown, not every frame once charged.
@(test)
a_turret_shot_spends_its_charge :: proc(t: ^testing.T) {
    for c in turret_heads {
        gs := turret_test_state()
        defer free(gs)
        rule := turret_table[c.tile]
        head_y := tt_build(gs, c)
        sd := &gs.world.sim_data[grid_idx(TT_X, head_y)]
        sd.growth_timer = rule.cooldown
        turret_test_enemy(gs, TT_X + 2.5, f32(head_y) + 0.5)
        turret_test_run(gs, 0.25)
        testing.expectf(t, sd.growth_timer < rule.cooldown, "%v kept its charge", c.tile)
    }
}

// An idle head holds exactly one charge, it does not bank shots.
@(test)
an_idle_turret_charge_caps :: proc(t: ^testing.T) {
    for c in turret_heads {
        gs := turret_test_state()
        defer free(gs)
        rule := turret_table[c.tile]
        head_y := tt_build(gs, c)
        turret_test_run(gs, 2 * rule.cooldown)
        testing.expect_value(t, gs.world.sim_data[grid_idx(TT_X, head_y)].growth_timer, rule.cooldown)
    }
}

// A shot does what its row says and leaves the rest of the status alone: a head
// with no burn must not put out one another turret lit.
@(test)
a_shot_carries_only_its_own_effect :: proc(t: ^testing.T) {
    for c in turret_heads {
        gs := turret_test_state()
        defer free(gs)
        rule := turret_table[c.tile]
        head_y := tt_build(gs, c)
        gs.world.sim_data[grid_idx(TT_X, head_y)].growth_timer = rule.cooldown
        id := turret_test_enemy(gs, TT_X + 2.5, f32(head_y) + 0.5)
        gs.enemy_status[id].burn = 1
        gs.enemy_status[id].slow = 0.25
        update_sim(gs)
        testing.expect_value(t, gs.enemy_status[id].burn, rule.burn_time > 0 ? rule.burn_time : 1)
        testing.expect_value(t, gs.enemy_status[id].slow, rule.slow_time > 0 ? rule.slow_time : 0.25)
        hits := 0
        for {
            e := eq_pop(&gs.events) or_break
            if e.type == .Damage_Dealt do hits += 1
        }
        testing.expect_value(t, hits, rule.damage > 0 ? 1 : 0)
    }
}

// Freed without despawn_enemy, as a guttered sprite is: the sweep clears it.
@(test)
a_freed_slot_loses_its_status :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    id := turret_test_enemy(gs, 60, 40)
    gs.enemy_status[id].burn = 2
    enemy_free(&gs.enemies, id)
    update_enemy_status(gs)
    testing.expect_value(t, gs.enemy_status[id], Enemy_Status{})
}

// A long frame keeps what it overshot: the tick is a clock, not a stopwatch.
@(test)
a_burn_tick_carries_its_remainder :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    gs.delta_time = 0.25
    id := turret_test_enemy(gs, 60, 40)
    gs.enemy_status[id].burn = 5
    turret_test_run(gs, 1.25)  // 0.75 pays, 0.15 carried, 1.25 pays
    testing.expect_value(t, gs.enemies.data[id].hp, 50 - 2*FLAME_BURN_HIT)
}

// action.log is how a playtest is read: a shot and a loosened part are in it.
@(test)
the_log_names_a_shot_and_a_loosened_part :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    head_y := tt_build(gs, turret_heads[0])
    gs.world.sim_data[grid_idx(TT_X, head_y)].growth_timer = FLAME_COOLDOWN
    turret_test_enemy(gs, TT_X + 2.5, f32(head_y) + 0.5)
    turret_test_run(gs, 0.1)
    smash_tile(gs, TT_X, head_y)
    text := string(gs.debug_log.buf[:gs.debug_log.pos])
    testing.expect(t, strings.contains(text, "fires on Enemy#"), "the shot is logged")
    testing.expect(t, strings.contains(text, "comes loose"), "the loosened part is logged")
}

// The numbers Glenn's card fixed, as relations, so tuning stays free inside them.
@(test)
flame_stays_a_third_to_a_half_of_the_laser :: proc(t: ^testing.T) {
    flame := f32(FLAME_BURN_HIT) / FLAME_BURN_TICK
    laser := f32(LASER_DAMAGE) / LASER_COOLDOWN
    testing.expectf(t, flame >= laser/3 && flame <= laser/2, "flame %v, laser %v", flame, laser)
    testing.expect(t, FLAME_RANGE < LASER_RANGE, "short range")
    testing.expect(t, FLAME_BURN_TIME > FLAME_COOLDOWN, "the jet keeps a target alight between shots")
    testing.expect(t, FLAME_BURN_TIME > FLAME_BURN_TICK, "a burn lasts at least one tick")
}

@(test)
a_burn_does_not_cross_a_portal_or_a_load :: proc(t: ^testing.T) {
    path :: "gnipahellir_turret_status_scratch.dat"
    defer os.remove(path)
    gs := turret_test_state()
    defer free(gs)
    testing.expect(t, save_game_to(gs, path), "saved")

    // Whatever holds this slot after a load or on the next level is not the
    // enemy that was burning.
    gs.enemy_status[3] = {burn = 2, slow = 2}
    testing.expect(t, load_game_from(gs, path), "loaded")
    testing.expect_value(t, gs.enemy_status[3], Enemy_Status{})

    gs.enemy_status[3] = {burn = 2}
    gs.progression.sky_altar_pos = {40, 52}
    sky_portal := sky_gate_portal(gs)
    level_transition(gs, &sky_portal)
    testing.expect_value(t, gs.enemy_status[3], Enemy_Status{})
}

// Clean the moment the slot is freed: a spawn in the same frame takes it next.
@(test)
a_despawn_clears_the_slots_status_at_once :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    id := turret_test_enemy(gs, 60, 40)
    gs.enemy_status[id] = {burn = 2}
    despawn_enemy(gs, id)
    testing.expect_value(t, gs.enemy_status[id], Enemy_Status{})
}

// Every body in the game, through the real update: a slowed one covers less
// ground than the same one free.  Dropped in open air, since gravity is the one
// motion every walking kind shares whatever its brain wants.
@(test)
water_slows_every_kind_of_enemy :: proc(t: ^testing.T) {
    fall :: proc(kind: Enemy_Kind, slowed: bool) -> f32 {
        gs := turret_test_state()
        defer free(gs)
        id, _ := enemy_alloc(&gs.enemies)
        gs.enemies.data[id] = Enemy{pos = {TT_X, 5}, kind = kind, hp = 50, hp_max = 50}
        for _ in 0 ..< 4 {  // short: Garm conjures a floor under himself
            if slowed do gs.enemy_status[id].slow = WATER_SLOW_TIME
            update_enemies(gs)
        }
        return gs.enemies.data[id].pos.y - 5
    }
    for kind in Enemy_Kind {
        if kind == .Fire_Sprite do continue  // flies, pinned by the turret test
        free_d, slow_d := fall(kind, false), fall(kind, true)
        testing.expectf(t, free_d > 0, "%v falls", kind)
        testing.expectf(t, slow_d < free_d * 0.75, "%v slowed fell %v, free %v", kind, slow_d, free_d)
    }
}

// The end of a burn takes the burn and nothing else.
@(test)
a_slow_outlives_a_burn :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    id := turret_test_enemy(gs, 60, 40)
    gs.enemy_status[id] = {burn = gs.delta_time / 2, slow = 1}
    update_enemy_status(gs)
    testing.expect_value(t, gs.enemy_status[id].burn, f32(0))
    testing.expect(t, gs.enemy_status[id].slow > 0, "the slow runs on")
}

@(test)
water_hits_once_a_cooldown_and_stays_weak :: proc(t: ^testing.T) {
    c := turret_heads[1]
    gs := turret_test_state()
    defer free(gs)
    head_y := tt_build(gs, c)
    gs.world.sim_data[grid_idx(TT_X, head_y)].growth_timer = WATER_COOLDOWN
    id := turret_test_enemy(gs, TT_X + 3.5, f32(head_y) + 0.5)
    turret_test_run(gs, 2.5 * WATER_COOLDOWN)
    testing.expect_value(t, gs.enemies.data[id].hp, 50 - 3*WATER_DAMAGE)
    testing.expect(t, WATER_DAMAGE > 0, "weak, not harmless")
    testing.expect(t, WATER_RANGE < LASER_RANGE, "under the laser's reach")
    testing.expect(t, WATER_SLOW > 0 && WATER_SLOW < 1, "a slow, not a stop")
    testing.expect(t, WATER_SLOW_TIME > WATER_COOLDOWN, "a jet keeps its target slowed")
}

@(test)
earth_keeps_its_place_in_the_line :: proc(t: ^testing.T) {
    testing.expect(t, EARTH_RANGE < LASER_RANGE, "under the laser's reach")
    testing.expect(t, EARTH_RANGE > FLAME_RANGE, "a thrower, not a jet")
}

// The coordinator's rule for the text: it says where the laser goes and that it
// needs to see its target.
@(test)
the_laser_text_names_the_pillars_and_the_sight_rule :: proc(t: ^testing.T) {
    desc := item_table[.Rainbow_Laser].desc
    testing.expect(t, strings.contains(desc, "two Turret Pillars"), "the pattern")
    testing.expect(t, strings.contains(desc, "it can see"), "the sight rule")
}

// An old save's bare laser over a fused turret: taking the laser takes only the
// laser.  The fused turret below keeps its pillar and stands.
@(test)
a_bare_laser_leaves_the_turret_beneath_it_alone :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    turret_test_site(gs, TT_X, TT_Y)
    set_tile(&gs.world, TT_X, TT_Y, .Turret_Pillar)
    set_tile(&gs.world, TT_X, TT_Y - 1, .Flame_Turret)
    set_tile(&gs.world, TT_X, TT_Y - 2, .Rainbow_Laser)
    eq_push(&gs.events, Event{type = .Tile_Mined, source = PLAYER_ID, tile = {TT_X, TT_Y - 2}})
    process_events(gs)
    eq_clear(&gs.events)
    testing.expect_value(t, turret_ground_count(gs, .Rainbow_Laser), 1)
    testing.expect_value(t, turret_ground_count(gs, .Turret_Pillar), 0)
    testing.expect_value(t, get_tile(&gs.world, TT_X, TT_Y - 1), Tile_Type.Flame_Turret)
    testing.expect_value(t, get_tile(&gs.world, TT_X, TT_Y), Tile_Type.Turret_Pillar)
}

// The fall step of game_update, long enough for a pile to cross the map.
tt_let_fall :: proc(gs: ^Game_State) {
    for _ in 0 ..< GRID_H * ITEM_FALL_FRAMES {
        gs.frame += 1
        update_item_fall(gs)
    }
}

// Every part stands on solid ground and none hangs where the turret stood.
tt_expect_landed :: proc(t: ^testing.T, gs: ^Game_State, c: Turret_Head_Case, loc := #caller_location) {
    tt_let_fall(gs)
    testing.expect_value(t, turret_ground_count(gs, c.item), 1, loc = loc)
    testing.expect_value(t, turret_ground_count(gs, .Turret_Pillar), c.pillars, loc = loc)
    for y in 0 ..< GRID_H - 1 do for x in 0 ..< GRID_W {
        idx := grid_idx(x, y)
        if gs.world.items[idx] != c.item && gs.world.items[idx] != .Turret_Pillar do continue
        // A pile holds up a different pile, so a head may rest on the pillars.
        rests := is_solid(&gs.world, x, y + 1) || gs.world.items[grid_idx(x, y + 1)] != .None
        testing.expectf(t, rests, "%v at (%d,%d) hangs in the air", gs.world.items[idx], x, y, loc = loc)
    }
    for dy in 0 ..= c.pillars {
        testing.expect(t, !is_turret_tile(get_tile(&gs.world, TT_X, TT_Y - dy)), "no part stands", loc = loc)
    }
}

// A body the size of `kind` sunk into the column, as a walled-in builder ends up.
tt_embed :: proc(gs: ^Game_State, kind: Enemy_Kind, head_y: int) -> int {
    id, ok := enemy_alloc(&gs.enemies)
    if !ok do return -1
    gs.enemies.data[id] = Enemy{pos = {TT_X + 0.1, f32(head_y)}, kind = kind, hp = 50, hp_max = 50}
    return id
}

// Glenn's rule, whoever breaks it: a builder rescuing itself takes the turret
// apart, whichever parts its body sits in, and is not paid a block for it.
@(test)
a_builder_digging_free_takes_a_turret_apart_whole :: proc(t: ^testing.T) {
    for c in turret_heads {
        gs := turret_test_state()
        defer free(gs)
        head_y := tt_build(gs, c)
        id := tt_embed(gs, .Builder, head_y)
        e := &gs.enemies.data[id]
        e.builder.stuck_count = MAX_STRIKES - 1
        builder_strike(e, id, gs, "test")
        tt_expect_landed(t, gs, c)
        testing.expect_value(t, e.builder.pocket, 0)
        testing.expect(t, !body_embedded(&gs.world, e.pos, enemy_body_size(e.kind)), "the builder is free")
    }
}

// The whole pattern falls even when the rescue only touches its foot.
@(test)
a_builder_digging_free_under_a_head_leaves_no_bare_head :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    c := turret_heads[3]
    tt_build(gs, c)
    id := tt_embed(gs, .Builder, TT_Y)
    e := &gs.enemies.data[id]
    e.pos.y = f32(TT_Y) - BUILDER_H + 1
    builder_dig_free(e, id, gs)
    tt_expect_landed(t, gs, c)
}

// A digging-free builder spills a loaded machine the way a den carve does.
@(test)
a_builder_digging_free_spills_a_loaded_machine :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    turret_test_site(gs, TT_X, TT_Y)
    set_tile(&gs.world, TT_X, TT_Y, .Smelter)
    sd := &gs.world.sim_data[grid_idx(TT_X, TT_Y)]
    sd.store_item, sd.store_count = .Iron_Bar, 2
    sd.in_item,    sd.in_count    = .Iron_Ore, 3
    sd.fuel_count = 4
    id := tt_embed(gs, .Builder, TT_Y)
    e := &gs.enemies.data[id]
    e.pos.y = f32(TT_Y) - BUILDER_H + 1
    builder_dig_free(e, id, gs)
    testing.expect(t, !is_solid(&gs.world, TT_X, TT_Y), "the machine is gone")
    testing.expect_value(t, turret_ground_count(gs, terrain_table[.Smelter].drop_item), 1)
    testing.expect_value(t, turret_ground_count(gs, .Iron_Bar), 2)
    testing.expect_value(t, turret_ground_count(gs, .Iron_Ore), 3)
    testing.expect_value(t, turret_ground_count(gs, FUEL_ITEM), 4)
    testing.expect_value(t, e.builder.pocket, 0)
}

// A refused tile stays refused, and plain rock still pays the pocket: the
// rescue does not swing at a loaded chest for ever (card 42).
@(test)
a_builder_digging_free_leaves_a_loaded_barrel_and_still_digs_rock :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    turret_test_site(gs, TT_X, TT_Y)
    set_tile(&gs.world, TT_X, TT_Y, .Barrel)
    set_tile(&gs.world, TT_X + 1, TT_Y, .Stone)
    barrel_on_placed(gs, {TT_X, TT_Y})
    barrel_at(gs, gs.level_index, {TT_X, TT_Y}).slots[0] = {.Iron_Ore, 5}
    id := tt_embed(gs, .Builder, TT_Y)
    e := &gs.enemies.data[id]
    e.pos = {TT_X + 0.6, f32(TT_Y)}   // astride the barrel and the rock
    for _ in 0 ..< 10 do builder_dig_free(e, id, gs)
    testing.expect_value(t, get_tile(&gs.world, TT_X, TT_Y), Tile_Type.Barrel)
    testing.expect(t, !is_solid(&gs.world, TT_X + 1, TT_Y), "the rock is dug")
    testing.expect_value(t, e.builder.pocket, 1)
}

// Garm's own smash, through its real path.
@(test)
garm_takes_a_turret_apart_whole :: proc(t: ^testing.T) {
    for c in turret_heads {
        gs := turret_test_state()
        defer free(gs)
        head_y := tt_build(gs, c)
        id := tt_embed(gs, .Garm, head_y)
        e := &gs.enemies.data[id]
        e.pos = {TT_X - GARM_W - 0.1, f32(TT_Y) - GARM_H + 1}
        e.facing = 1
        gs.player.pos = {TT_X + 4, f32(TT_Y) - PLAYER_H + 1}
        e.nav.path.tiles[0], e.nav.path.len = {TT_X, TT_Y}, 1
        for _ in 0 ..< 600 {
            gs.player.hp = 1000
            update_enemies(gs)
            process_events(gs)
            eq_clear(&gs.events)
            if !is_turret_tile(get_tile(&gs.world, TT_X, TT_Y)) do break
        }
        tt_expect_landed(t, gs, c)
    }
}

// A fire sprite burns one part through its real update.
@(test)
a_fire_sprite_takes_a_turret_apart_whole :: proc(t: ^testing.T) {
    for c in turret_heads {
        gs := turret_test_state()
        defer free(gs)
        head_y := tt_build(gs, c)
        testing.expect(t, spawn_flyer_at(gs, TT_X - 1, head_y), "a sprite")
        for _ in 0 ..< 600 {
            update_enemies(gs)
            process_events(gs)
            eq_clear(&gs.events)
            if !is_turret_tile(get_tile(&gs.world, TT_X, head_y)) do break
        }
        tt_expect_landed(t, gs, c)
    }
}

// The pick lands the parts too, and a spare pillar under the pattern stays: the
// parts rest on it.
@(test)
parts_land_on_the_ground_or_on_a_spare_pillar :: proc(t: ^testing.T) {
    for c in turret_heads do for at in 0 ..= c.pillars {
        gs := turret_test_state()
        defer free(gs)
        head_y := tt_build(gs, c)
        eq_push(&gs.events, Event{type = .Tile_Mined, source = PLAYER_ID, tile = {TT_X, i32(head_y + at)}})
        process_events(gs)
        eq_clear(&gs.events)
        tt_expect_landed(t, gs, c)
    }
    gs := turret_test_state()
    defer free(gs)
    c := turret_heads[0]
    turret_test_site(gs, TT_X, TT_Y)
    set_tile(&gs.world, TT_X, TT_Y, .Turret_Pillar)
    set_tile(&gs.world, TT_X, TT_Y - 1, .Turret_Pillar)
    set_tile(&gs.world, TT_X, TT_Y - 2, c.tile)
    smash_tile(gs, TT_X, TT_Y - 2)
    tt_let_fall(gs)
    testing.expect_value(t, get_tile(&gs.world, TT_X, TT_Y), Tile_Type.Turret_Pillar)
    testing.expect_value(t, gs.world.items[grid_idx(TT_X, TT_Y - 1)], Item.Turret_Pillar)
    testing.expect_value(t, gs.world.items[grid_idx(TT_X, TT_Y - 2)], c.item)
}

// Only a lone pillar taken: nothing else is touched and it pays once.
@(test)
a_spare_pillar_taken_pays_only_itself :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    turret_test_site(gs, TT_X, TT_Y)
    set_tile(&gs.world, TT_X, TT_Y, .Turret_Pillar)
    set_tile(&gs.world, TT_X, TT_Y - 1, .Stone)
    smash_tile(gs, TT_X, TT_Y)
    testing.expect_value(t, turret_ground_count(gs, .Turret_Pillar), 1)
    testing.expect_value(t, get_tile(&gs.world, TT_X, TT_Y - 1), Tile_Type.Stone)
}

// The rescue digs only what a digger may: rock it cannot mine stays.
@(test)
a_builder_digging_free_leaves_unmineable_rock :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    turret_test_site(gs, TT_X, TT_Y)
    set_tile(&gs.world, TT_X, TT_Y, .Rune_Stone)
    id := tt_embed(gs, .Builder, TT_Y)
    builder_dig_free(&gs.enemies.data[id], id, gs)
    testing.expect_value(t, get_tile(&gs.world, TT_X, TT_Y), Tile_Type.Rune_Stone)
}

// A door is one item on two tiles: the rescue takes both and pays one door.
@(test)
a_builder_digging_free_takes_a_whole_door :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    turret_test_site(gs, TT_X, TT_Y)
    set_tile(&gs.world, TT_X, TT_Y, .Door)
    set_tile(&gs.world, TT_X, TT_Y - 1, .Door)
    id := tt_embed(gs, .Builder, TT_Y)
    e := &gs.enemies.data[id]
    builder_dig_free(e, id, gs)
    testing.expect(t, get_tile(&gs.world, TT_X, TT_Y) != .Door, "the foot is gone")
    testing.expect(t, get_tile(&gs.world, TT_X, TT_Y - 1) != .Door, "the top is gone")
    testing.expect_value(t, turret_ground_count(gs, .Door), 1)
    testing.expect_value(t, e.builder.pocket, 0)
}
