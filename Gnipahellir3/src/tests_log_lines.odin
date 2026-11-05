package game

import "core:fmt"
import "core:strings"
import "core:testing"

// ─── Card 183: action.log lines from playtests 133-135, and the new life's
// velocity.  A log line only exists under GAME_DEBUG, so each check does. ───

@(private = "file")
log_text :: proc(gs: ^Game_State) -> string {
    return string(gs.debug_log.buf[:gs.debug_log.pos])
}

// The pos line of enemy slot i on the last breadcrumb beat.
@(private = "file")
log_pos_line :: proc(gs: ^Game_State, i: int) -> string {
    head := fmt.tprintf("pos Enemy#%d ", i)
    text := log_text(gs)
    at := strings.last_index(text, head)
    if at < 0 do return ""
    line := text[at:]
    if end := strings.index_byte(line, '\n'); end >= 0 do line = line[:end]
    return line
}

// Playtest 133 (run 20261104-114152, life 2): the first poll of the new
// life had vx -8.  The poll at f0 had vx 0; by f28 the hero was walking
// (8 is MOVE_SPEED, the brain backing off the risen hero at the spawn).
// game_state_init zeroes the player, knockback included; this pins it.
@(test)
a_new_life_starts_still :: proc(t: ^testing.T) {
    gs := new(Game_State)
    defer free(gs)
    game_state_init(gs, 4107)
    gs.ui.show_title = false
    gs.player.vel = {-8, -3}
    gs.death_by = "a Vargr"
    eq_push(&gs.events, Event{type = .Entity_Died, source = PLAYER_ID})
    process_events(gs)
    process_events(gs)
    testing.expect(t, gs.player.dead, "the hero fell")
    eq_push(&gs.events, Event{type = .New_Game_Request})
    process_events(gs)
    testing.expect(t, !gs.player.dead, "a new life")
    testing.expect_value(t, gs.player.vel, [2]f32{})
}

// Playtest 134 (f84091-84122): water put out lava and action.log said
// nothing.
@(test)
a_quench_is_logged :: proc(t: ^testing.T) {
    when GAME_DEBUG {
        gs := new(Game_State)
        defer free(gs)
        game_state_init(gs, 781)
        x, y := 40, 30
        set_tile(&gs.world, x, y, .Water)
        set_tile(&gs.world, x, y + 1, .Lava)
        testing.expect(t, fluid_quench(gs, x, y, 1), "the water quenched")
        want := fmt.tprintf("quench: Water at (%d,%d) spent on Lava at (%d,%d), Scoria", x, y, x, y + 1)
        testing.expectf(t, strings.contains(log_text(gs), want), "no %q in the log", want)
    }
}

// Playtests 134 and 135 (a felled trunk at f10650, a pillar at f13121, a cut
// bridge at f90273-90400): blocks fell and landed, and action.log said
// nothing.  A block that falls is logged where it left, and where it lands:
// a tile again, or a pile.
@(test)
a_falling_block_is_logged_from_its_fall_to_its_landing :: proc(t: ^testing.T) {
    when GAME_DEBUG {
        Case :: struct { tile: Tile_Type, lands: string }
        for c in ([2]Case{{.Dirt, "settled"}, {.Wood, "a pile of Wood_Log"}}) {
            gs := new(Game_State)
            defer free(gs)
            game_state_init(gs, 781)
            gs.delta_time = 1.0 / 60.0
            x, y := 40, 20
            for r in y ..< y + 6 do set_tile(&gs.world, x, r, .Air)
            set_tile(&gs.world, x, y + 6, .Stone)
            gravity_spawn(gs, i32(x), i32(y), c.tile)
            for _ in 0 ..< 600 do update_gravity(gs)
            text := log_text(gs)
            falls := fmt.tprintf("falls: %v from (%d,%d)", c.tile, x, y)
            lands := fmt.tprintf("lands: %v at (%d,%d), %s", c.tile, x, y + 5, c.lands)
            testing.expectf(t, strings.contains(text, falls), "no %q in the log", falls)
            testing.expectf(t, strings.contains(text, lands), "no %q in the log", lands)
        }
    }
}

// Playtest 135 (AL 3670): pos lines gave a Rain_Wisp goal=Build_Den, the
// zero value of a goal only the builder brains keep.  Those kinds (the
// builder and raider brains, a wave's fire sprite, the risen hero) keep goal
// and target; every other kind says goal=-.
@(test)
a_pos_line_gives_only_a_goal_the_enemy_has :: proc(t: ^testing.T) {
    when GAME_DEBUG {
        brains := bit_set[Enemy_Kind]{.Builder, .Raider, .Vargr, .Fire_Sprite, .Undead}
        for k in Enemy_Kind {
            gs := new(Game_State)
            defer free(gs)
            game_state_init(gs, 781)
            id, ok := enemy_alloc(&gs.enemies)
            assert(ok)
            gs.enemies.data[id] = Enemy{kind = k, hp = 3, hp_max = 3, pos = {50, 20}}
            log_breadcrumbs(gs)
            line := log_pos_line(gs, id)
            if k in brains do testing.expectf(t, strings.contains(line, "goal=Build_Den target=("), "%v: %q", k, line)
            else do testing.expectf(t, strings.has_suffix(line, "goal=-"), "%v: %q", k, line)
        }
    }
}

// Playtest 135: action.log had no bird lines.  Each flock's place is on the
// breadcrumb beat, and a scatter is logged.
@(test)
the_birds_are_in_the_log :: proc(t: ^testing.T) {
    when GAME_DEBUG {
        gs := new(Game_State)
        defer free(gs)
        game_state_init(gs, 781)
        gs.level_index = LEVEL_SKY
        gs.delta_time = 1.0 / 60.0
        gs.player.pos = {96, 200}
        update_birds(gs)
        log_breadcrumbs(gs)
        testing.expect(t, strings.contains(log_text(gs), "pos Flock#0 ("), "no flock pos line")
        f := &gs.birds.flocks[0]
        gs.player.pos = f.birds[0].pos - {PLAYER_W, PLAYER_H} * 0.5
        update_birds(gs)
        testing.expect(t, f.scatter_t > 0, "the flock scattered")
        testing.expect(t, strings.contains(log_text(gs), "birds: a flock at ("), "no scatter line")
    }
}
