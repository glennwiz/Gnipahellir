package game

import "core:math"
import "core:slice"

// ─── Constants ────────────────────────────────────────────────────────────────

BUILDER_HP       :: 6
BUILDER_W        :: f32(0.8)
BUILDER_H        :: f32(1.0)
BUILDER_SPEED    :: f32(4.0)
BUILDER_JUMP     :: f32(-10.0)  // apex ~2.5 tiles — must clear the A*'s 2-up jumps
BUILDER_GRAVITY  :: f32(20.0)
BUILDER_MAX_FALL :: f32(12.0)

MINE_TIME       :: f32(0.4)   // pause after each mine/place action
MAX_ASTAR_NODES :: 4096       // search budget (nodes pushed)
ASTAR_H_WEIGHT  :: f32(2.0)   // greedy-ish A*: with mining the whole rock mass is
                              // searchable and an admissible h floods the budget

BUILDER_REACH   :: i32(3)     // chebyshev tile distance for mining/placing
// Garm's lair is 8 interior rows tall, so its roof sits 9 above the floor —
// far past a builder's arm.  He could not climb to it either: pathing onto
// his own masonry invites astar_dig to chew the walls he just raised.  So the
// boss places at boss range, the same conjuring licence as his masonry pocket
// and his MAX_NAV_PATH plan budget.  Only Garm gets it (builder_build_den).
GARM_BUILD_REACH :: i32(9)
REPLAN_MIN      :: f32(0.5)   // min seconds between path computations
MAX_NAV_SEARCHES_PER_FRAME :: 3   // ~1.2-1.4 ms per long or exhausted search
                                  // (release build), so this bounds pathing
                                  // at ~4 ms a frame whatever the enemy count;
                                  // a hunter over budget simply asks again
                                  // next frame
REPLAN_BACKOFF  :: f32(3.0)   // wait after a search that found no route, or
                              // ran its whole node budget without reaching the
                              // goal: those are the searches that cost the most
                              // and repeating them every REPLAN_MIN is what
                              // stalled a 512-enemy frame
STUCK_TIME      :: f32(3.0)   // no path progress for this long => strike
MAX_STRIKES     :: 3          // strikes before the current objective is dropped
AVOID_RADIUS    :: i32(4)     // given-up targets blacklist their whole cluster —
                              // unreachable ore (e.g. a ceiling vein over an open
                              // basin) usually comes in groups
JOB_COOLDOWN    :: f32(2.0)   // pause between objectives
SITE_SPACING    :: 20         // min x-distance between two builders' dens

// The pillar escape (Glenn's call, playtest 2026-07-16): a builder that
// keeps re-placing the same bridge block is fighting an unreachable jump
// (head-bump under a ledge) — the stuck watchdog can't see it because
// mine/place actions register as progress.  Escape hatch: tunnel straight
// UP — mine the ceiling, jump, place a block underfoot mid-air — until the
// column overhead is open and we've gained real height, then replan.
PLACE_REPS_LOOP :: 3          // same tile bridge-placed this often = the loop
ESCAPE_MIN_RISE :: i32(4)     // climb at least this far before replanning
ESCAPE_MAX_TIME :: f32(15.0)  // hard cap — never pillar forever

// Path move costs.  Walking is cheapest so builders prefer open routes and
// only tunnel or bridge when it genuinely pays off.
COST_WALK  :: f32(1)
COST_PLACE :: f32(4)   // bridge: place a block underfoot
COST_MINE  :: f32(6)   // tunnel: mine a solid tile

// Bridge blocks are not conjured: every tile a builder mines credits its
// pocket, and every bridge block spends from it.
POCKET_MAX :: u8(8)

// Hunting.
HUNT_RADIUS    :: f32(12)   // spot the player within this distance + line of sight
HUNT_LOSE_DIST :: f32(20)   // give up the chase beyond this distance
LOS_MEMORY     :: f32(3.0)  // keep hunting this long after losing sight
ATTACK_TIME    :: f32(0.8)  // seconds between bites
ATTACK_DAMAGE  :: 1

// Industry raids. A working surface furnace/kettle must stay hot for the full
// pressure + warning window; shutting it down during the warning cancels the
// attack. Once spawned, tunnellers break the marked machine and then fight.
RAID_PRESSURE_TIME :: f32(20.0)
RAID_WARNING_TIME  :: f32(10.0)
RAID_QUIET_CANCEL  :: f32(2.0)  // tolerate a machine's one-frame cycle reset
RAID_COOLDOWN      :: f32(180.0)
RAID_COUNT         :: 2
RAIDER_HP          :: 8
RAIDER_SPEED       :: f32(6.0)
RAIDER_ATTACK_TIME :: f32(0.9)
RAIDER_DAMAGE      :: 2

// Wave enemies. AIR is the Fire_Sprite (a dead stub until now — no spawn proc
// ever existed, so no save can contain one), GROUND is the Vargr, UNDERGROUND
// is an ordinary Raider carrying .Wave_Hunt. The wave numbers are separate
// knobs from the raid's on purpose: the two threats are tuned against
// different things. All first guesses, playtest-tuned.
FIRE_SPRITE_HP    :: 4
FIRE_SPRITE_SPEED :: f32(5.0)
FIRE_SPRITE_STALL :: f32(5)  // seconds on one spot before it counts as stalled
FIRE_SPRITE_GIVE_UP :: 4     // stalls with no burn in between: it gutters out
VARGR_HP          :: 8
WAVE_ATTACK_TIME  :: f32(0.9)
WAVE_DAMAGE       :: 2

// Den shell.  Tuned 3 -> 2 after playtest round 1: with 3 layers a dome
// took ~an hour of builder time, so the floor stockpile (the raid payout)
// never appeared in a real session.
DEN_SHELL_LAYERS :: 2       // mineral layers placed around the den

DEN_UNSET :: [2]i32{0, 0}   // anchor sentinel: no den site chosen yet
DEN_FLOOR_OFFS :: [3][2]i32{{0, 0}, {-1, 0}, {1, 0}}   // hoard stacks, around the anchor

// Rob a den and its owner comes back to your base with friends.  First guesses.
DEN_REVENGE_DELAY :: f32(600)
DEN_REVENGE_PARTY :: 3

// ─── Build Templates ──────────────────────────────────────────────────────────
//
//  Anchor = a standable floor tile; offsets are relative to it, -y is up.
//  Steps are ordered so each is placeable from the ground: carves (.Void)
//  first, then solids bottom-up.  Everything stays within BUILDER_REACH of
//  the anchor area, so a whole structure is buildable without re-pathing.
//  One exception: Garm's .Lair is 9 rows tall and reaches past any arm, so
//  he alone builds at GARM_BUILD_REACH (builder_build_den).  A template for
//  an ordinary builder must still obey BUILDER_REACH.

Template_Tile :: struct {
    off:  [2]i32,
    tile: Tile_Type,
}

Build_Template :: struct {
    name:  string,
    tiles: []Template_Tile,
}

@(rodata)
CAIRN_TILES := [?]Template_Tile{
    {{-1, 0}, .Stone}, {{0, 0}, .Stone}, {{1, 0}, .Stone},
    {{0, -1}, .Stone},
}

@(rodata)
PILLAR_TILES := [?]Template_Tile{
    {{0, 0}, .Stone}, {{0, -1}, .Stone}, {{0, -2}, .Stone}, {{0, -3}, .Stone},
    {{-1, -3}, .Stone}, {{1, -3}, .Stone},
}

@(rodata)
SHELTER_TILES := [?]Template_Tile{
    // carve the interior + doorway
    {{-1, 0}, .Void}, {{0, 0}, .Void}, {{1, 0}, .Void}, {{2, 0}, .Void},
    {{-1, -1}, .Void}, {{0, -1}, .Void}, {{1, -1}, .Void},
    {{-1, -2}, .Void}, {{0, -2}, .Void}, {{1, -2}, .Void},
    // walls (2-high door gap stays open at {2, 0} and {2, -1})
    {{-2, 0}, .Wood},
    {{-2, -1}, .Wood},
    {{-2, -2}, .Wood}, {{2, -2}, .Wood},
    // roof
    {{-2, -3}, .Wood}, {{-1, -3}, .Wood}, {{0, -3}, .Wood}, {{1, -3}, .Wood}, {{2, -3}, .Wood},
}

// Garm's lair: a real vault, not a hut — a stone hall 10 wide and 8 tall
// that he raises and then FILLS with fire.  Glenn's call (board seq 308):
// the walls and roof close FIRST, and only then does the floor flood, wall
// to wall, the gate ground included — reaching Hell means crossing his fire,
// so there is no dry plinth to stand on.  The doorway is one tile wide: a
// player fits, his 1.6-wide body never did — the den is his monument to
// guard, not a house, and its threshold {5,0} is the one floor cell left
// unpoured so the hall can be entered on foot.
//
// The step order IS the build sequence (builder_build_den walks it strictly
// in order): carve, then shell bottom-up, then roof, then the pour.  Interior
// carves over open arena air auto-satisfy — tile_satisfied treats any
// non-solid tile as a finished .Void — so the real work is the 34 placements,
// not the 80 carves.  Static lava (fluid.odin) holds a floor-level pool with
// no basin, forever; nothing is targeted below the floor row, so his own
// wide-body descent smashes have no excuse to chew through it.
@(rodata)
GARM_LAIR_TILES := [?]Template_Tile{
    // carve the hall: x -4..5, y 0..-7, doorway included at {5,0}/{5,-1}
    {{-4, 0}, .Void}, {{-3, 0}, .Void}, {{-2, 0}, .Void}, {{-1, 0}, .Void}, {{0, 0}, .Void},
    {{1, 0}, .Void}, {{2, 0}, .Void}, {{3, 0}, .Void}, {{4, 0}, .Void}, {{5, 0}, .Void},
    {{-4, -1}, .Void}, {{-3, -1}, .Void}, {{-2, -1}, .Void}, {{-1, -1}, .Void}, {{0, -1}, .Void},
    {{1, -1}, .Void}, {{2, -1}, .Void}, {{3, -1}, .Void}, {{4, -1}, .Void}, {{5, -1}, .Void},
    {{-4, -2}, .Void}, {{-3, -2}, .Void}, {{-2, -2}, .Void}, {{-1, -2}, .Void}, {{0, -2}, .Void},
    {{1, -2}, .Void}, {{2, -2}, .Void}, {{3, -2}, .Void}, {{4, -2}, .Void}, {{5, -2}, .Void},
    {{-4, -3}, .Void}, {{-3, -3}, .Void}, {{-2, -3}, .Void}, {{-1, -3}, .Void}, {{0, -3}, .Void},
    {{1, -3}, .Void}, {{2, -3}, .Void}, {{3, -3}, .Void}, {{4, -3}, .Void}, {{5, -3}, .Void},
    {{-4, -4}, .Void}, {{-3, -4}, .Void}, {{-2, -4}, .Void}, {{-1, -4}, .Void}, {{0, -4}, .Void},
    {{1, -4}, .Void}, {{2, -4}, .Void}, {{3, -4}, .Void}, {{4, -4}, .Void}, {{5, -4}, .Void},
    {{-4, -5}, .Void}, {{-3, -5}, .Void}, {{-2, -5}, .Void}, {{-1, -5}, .Void}, {{0, -5}, .Void},
    {{1, -5}, .Void}, {{2, -5}, .Void}, {{3, -5}, .Void}, {{4, -5}, .Void}, {{5, -5}, .Void},
    {{-4, -6}, .Void}, {{-3, -6}, .Void}, {{-2, -6}, .Void}, {{-1, -6}, .Void}, {{0, -6}, .Void},
    {{1, -6}, .Void}, {{2, -6}, .Void}, {{3, -6}, .Void}, {{4, -6}, .Void}, {{5, -6}, .Void},
    {{-4, -7}, .Void}, {{-3, -7}, .Void}, {{-2, -7}, .Void}, {{-1, -7}, .Void}, {{0, -7}, .Void},
    {{1, -7}, .Void}, {{2, -7}, .Void}, {{3, -7}, .Void}, {{4, -7}, .Void}, {{5, -7}, .Void},
    // shell, bottom-up: solid left wall the full height, right wall only
    // above the 2-tall doorway gap at {5,0} and {5,-1}
    {{-5, 0}, .Stone}, {{-5, -1}, .Stone}, {{-5, -2}, .Stone}, {{-5, -3}, .Stone},
    {{-5, -4}, .Stone}, {{-5, -5}, .Stone}, {{-5, -6}, .Stone}, {{-5, -7}, .Stone},
    {{5, -2}, .Stone}, {{5, -3}, .Stone}, {{5, -4}, .Stone}, {{5, -5}, .Stone},
    {{5, -6}, .Stone}, {{5, -7}, .Stone},
    // roof
    {{-5, -8}, .Stone}, {{-4, -8}, .Stone}, {{-3, -8}, .Stone}, {{-2, -8}, .Stone},
    {{-1, -8}, .Stone}, {{0, -8}, .Stone}, {{1, -8}, .Stone}, {{2, -8}, .Stone},
    {{3, -8}, .Stone}, {{4, -8}, .Stone}, {{5, -8}, .Stone},
    // and the fire — poured last, into a vault that is already closed.  The
    // gate cells {0,0} and {1,0} flood with the rest: his death overwrites
    // them with .Hell_Gate, so the only way to the gate is across the pour.
    {{-4, 0}, .Lava}, {{-3, 0}, .Lava}, {{-2, 0}, .Lava}, {{-1, 0}, .Lava},
    {{0, 0}, .Lava}, {{1, 0}, .Lava}, {{2, 0}, .Lava}, {{3, 0}, .Lava}, {{4, 0}, .Lava},
}

// Static table; cannot be @(rodata) because the slice initializers are not
// compile-time constants.  The arrays it points into ARE rodata — treat this
// as read-only. Same reason golem.odin's HEARTH_CELLS/DEPOT_CELLS/
// ANCHOR_CELLS/golem_plan_table aren't @(rodata) either — this is the
// documented exception, now four instances across two files.
build_templates := [Build_Kind]Build_Template{
    .Cairn   = {"cairn",   CAIRN_TILES[:]},
    .Pillar  = {"pillar",  PILLAR_TILES[:]},
    .Shelter = {"shelter", SHELTER_TILES[:]},
    .Lair    = {"lair",    GARM_LAIR_TILES[:]},
}

// ─── Enemy Pool ───────────────────────────────────────────────────────────────

// Entity_ID convention: PLAYER_ID is 0; enemy slot i maps to Entity_ID(i + 1).
enemy_entity_id :: #force_inline proc(i: int) -> Entity_ID {
    return Entity_ID(i + 1)
}

entity_id_to_enemy_index :: #force_inline proc(id: Entity_ID) -> int {
    return int(id) - 1
}

enemy_alloc :: proc(es: ^Enemy_Store) -> (id: int, ok: bool) {
    for i in 0 ..< MAX_ENEMIES {
        if !es.active[i] {
            es.active[i] = true
            es.data[i]   = {}
            es.count    += 1
            return i, true
        }
    }
    return 0, false
}

enemy_free :: proc(es: ^Enemy_Store, id: int) {
    if id < 0 || id >= MAX_ENEMIES { return }
    es.active[id] = false
    es.count      = max(0, es.count - 1)
}

// ─── Standable / Snap ─────────────────────────────────────────────────────────

is_standable :: proc(w: ^World_Grid, x, y: int) -> bool {
    return in_bounds(x, y) && in_bounds(x, y+1) &&
           !is_solid(w, x, y) && is_solid(w, x, y+1)
}

// What an enemy dig may take, and every dig and dig plan asks here first.  Scroll
// chests are .Mineable for the player's reclaim only, and a loaded silo, barrel
// or coffer is rock to a digger, so none is hammered at or planned through.
// Nor is a tile holding water back: a breached pond drains for good, and it may
// be the only water a Boiler or Water Head will ever get.
is_builder_mineable :: proc(gs: ^Game_State, x, y: int) -> bool {
    if !in_bounds(x, y) { return false }
    t := gs.world.terrain[grid_idx(x, y)]
    return .Mineable in terrain_table[t].flags && !wave_target_refused(gs, {i32(x), i32(y)}) &&
           !holds_water_back(&gs.world, x, y)
}

// A block laid on water would delete it, and a laid block never comes back as
// water.  Nor does anything enemy-built go on the way to Hell.
builder_may_lay :: proc(t: Tile_Type) -> bool {
    return t != .Water && !is_sacred_tile(t)
}

holds_water_back :: proc(w: ^World_Grid, x, y: int) -> bool {
    return get_tile(w, x, y - 1) == .Water || get_tile(w, x - 1, y) == .Water ||
           get_tile(w, x + 1, y) == .Water
}

// A player's build: a dig knocks it loose instead of deleting it.  A door is
// placed by its own rules and is not .Placeable, so it is named here.
knocks_loose :: proc(t: Tile_Type) -> bool {
    return .Placeable in terrain_table[t].flags || t == .Door
}

// Enemy demolition of a tile.  A player machine is knocked loose, not deleted:
// it drops its item and spills what it held, so the loss is visible and
// recoverable instead of a silent hole in the base.  The rest is what a mine
// does to a tile (handle_tile_mined).  Returns whether the tile went to the
// ground: that block is paid, so a digger's pocket gets nothing for it.
smash_tile :: proc(gs: ^Game_State, x, y: int) -> (dropped: bool) {
    old := get_tile(&gs.world, x, y)
    T := [2]i32{i32(x), i32(y)}
    // A hoard is never smashed away, whoever swings; an emptied container's
    // record goes with its tile.
    if wave_target_refused(gs, T) do return
    if old == .Silo {
        if s := silo_at(gs, gs.level_index, T); s != nil do s^ = {}
    }
    if old == .Barrel || old == .Rune_Coffer do barrel_on_mined(gs, T)
    miner_anchor_on_taken(gs, T, old)
    set_tile(&gs.world, x, y, gravity_open_tile(gs, y))
    golem_remove_block_mark(gs, T)
    gs.world.tile_flags[grid_idx(x, y)] -= {.Placed, .Golem_Placed}
    gravity_check_removed(gs, x, y)
    if knocks_loose(old) {
        if drop := terrain_table[old].drop_item; drop != .None {
            spawn_ground_item(&gs.world, T, drop, 1)
            dropped = true
        }
    }
    spill_machine(gs, T, old)
    if old == .Door do door_take_partner(gs, x, y)
    turret_come_apart(gs, x, y, old)
    return
}

// The seconds a digger works a player-placed block before it breaks: Glenn's
// numbers to tune.  A block with no row takes DIG_TIME_PLACED.  Natural rock and
// blocks enemies laid carry no .Placed and break at the first hit, as ever.
DIG_TIME_PLACED :: f32(1.5)
DIG_LAPSE       :: f32(0.5)   // seconds past its time a digger's clock stays good
@(rodata)
dig_time_table := #partial [Tile_Type]f32{
    .Stone = 4,
    .Door  = 6,
}

dig_time :: proc(gs: ^Game_State, x, y: int) -> f32 {
    if !is_solid(&gs.world, x, y) || .Placed not_in gs.world.tile_flags[grid_idx(x, y)] do return 0
    secs := dig_time_table[gs.world.terrain[grid_idx(x, y)]]
    return secs if secs > 0 else DIG_TIME_PLACED
}

// What a plan pays for a dig: its time, in the units COST_MINE buys MINE_TIME.
// A wave goes for the thin spot.
dig_cost :: proc(gs: ^Game_State, x, y: int) -> f32 {
    return COST_MINE * max(1, dig_time(gs, x, y) / MINE_TIME)
}

// Ready to break this tile?  The first ask on a placed block starts the digger's
// dig time on nav.mine_timer, and an ask as that runs out breaks it; a digger that
// wandered off past DIG_LAPSE starts over.  Each digger times its own, so a pack
// is no faster on one block.  Nothing is refused: the wait always ends, and
// builder_travel counts it as work, so no hunter strikes out on a wall.  Garm goes
// through walls at his own pace.
builder_dig_ready :: proc(e: ^Enemy, id: int, gs: ^Game_State, T: [2]i32) -> bool {
    secs := dig_time(gs, int(T.x), int(T.y))
    if secs <= 0 || e.kind == .Garm do return true
    status := &gs.enemy_status[id]
    if status.dig_tile == T && e.nav.mine_timer > -DIG_LAPSE {
        status.dig_tile = {}
        return true
    }
    status.dig_tile  = T
    e.nav.mine_timer = secs
    e.vel.x = 0
    log_action(gs, "Enemy#%d digs at placed %v (%d,%d), %.1f s", id, get_tile(&gs.world, int(T.x), int(T.y)), T.x, T.y, secs)
    return false
}

// A clock dies with its block, however the block went, so a repair on the same
// tile is a new block with its full time.  Runs after the frame's digs, before
// anything can be placed on the gap.
dig_clocks_sweep :: proc(gs: ^Game_State) {
    for &status, i in gs.enemy_status {
        T := status.dig_tile
        if T == {} || dig_time(gs, int(T.x), int(T.y)) > 0 do continue
        status.dig_tile = {}
        gs.enemies.data[i].nav.mine_timer = 0
    }
}

is_mineral :: proc(t: Tile_Type) -> bool {
    #partial switch t {
    case .Iron_Ore, .Silver_Ore, .Gold_Ore, .Gold_Rare_Ore:
        return true
    }
    return false
}

snap_to_standable :: proc(w: ^World_Grid, x, y: int) -> (rx, ry: int) {
    for dy in 0 ..= 5 { if is_standable(w, x, y+dy) { return x, y+dy } }
    for dy in 1 ..= 5 { if is_standable(w, x, y-dy) { return x, y-dy } }
    return x, y
}

chebyshev :: proc(a, b: [2]i32) -> i32 {
    return max(abs(a.x - b.x), abs(a.y - b.y))
}

// One row per kind: what update_enemies moves and runs, and what a spawn gives
// it.  The risen hero alone is an .Undead with hp of its own (grave.odin).
Enemy_Behaviour :: struct {
    body:     [2]f32,
    speed:    f32,
    hp:       int,
    gravity:  f32,
    update:   proc(e: ^Enemy, id: int, gs: ^Game_State, dt: f32),
}

@(rodata)
enemy_behaviour := [Enemy_Kind]Enemy_Behaviour{
    .Garm         = {{GARM_W, GARM_H}, GARM_SPEED, GARM_HP, BUILDER_GRAVITY, update_garm},
    .Undead       = {{BUILDER_W, BUILDER_H}, DRAUGR_SPEED, DRAUGR_HP, BUILDER_GRAVITY, update_undead},
    // Zero gravity: it flies through the shared mover, so
    // collision and the entity map stay everyone else's code.
    .Fire_Sprite  = {{BUILDER_W, BUILDER_H}, FIRE_SPRITE_SPEED, FIRE_SPRITE_HP, 0, update_fire_sprite},
    .Builder      = {{BUILDER_W, BUILDER_H}, BUILDER_SPEED, BUILDER_HP, BUILDER_GRAVITY, update_builder},
    .Raider       = {{BUILDER_W, BUILDER_H}, RAIDER_SPEED, RAIDER_HP, BUILDER_GRAVITY, update_raider},
    // The wolf IS the raider brain: same body, same travel, and .Wave_Hunt is
    // what makes it hunt the whole base.
    .Vargr        = {{BUILDER_W, BUILDER_H}, RAIDER_SPEED, VARGR_HP, BUILDER_GRAVITY, update_raider},
    .Pond_Frog    = {{POND_FROG_W, POND_FROG_H}, POND_FROG_SPEED, POND_FROG_HP, BUILDER_GRAVITY, update_roamer},
    .Ember_Beetle = {{EMBER_BEETLE_W, EMBER_BEETLE_H}, EMBER_BEETLE_SPEED, EMBER_BEETLE_HP, BUILDER_GRAVITY, update_roamer},
    // Zero gravity: water holds it up, and update_roamer drops it when none does.
    .Cave_Eel     = {{CAVE_EEL_W, CAVE_EEL_H}, CAVE_EEL_SPEED, CAVE_EEL_HP, 0, update_roamer},
    .Magma_Crawler = {{MAGMA_CRAWLER_W, MAGMA_CRAWLER_H}, MAGMA_CRAWLER_SPEED, MAGMA_CRAWLER_HP, BUILDER_GRAVITY, update_roamer},
    .Stone_Grub   = {{STONE_GRUB_W, STONE_GRUB_H}, STONE_GRUB_SPEED, STONE_GRUB_HP, BUILDER_GRAVITY, update_roamer},
}

enemy_body_size :: proc(kind: Enemy_Kind) -> [2]f32 {
    return enemy_behaviour[kind].body
}

enemy_speed :: proc(kind: Enemy_Kind) -> f32 {
    return enemy_behaviour[kind].speed
}

// Nearest live enemy body under a world pixel, or -1.  A small halo around the
// body (the same allowance golem_at_world_point makes) keeps a walking builder
// comfortable to click.  Query only — used by the ALT camera follow.
enemy_at_world_point :: proc(gs: ^Game_State, world_pixel: [2]f32) -> int {
    p := [2]f32{world_pixel.x/CELL_SIZE, world_pixel.y/CELL_SIZE}
    best, best_dist := -1, max(f32)
    for &e, i in gs.enemies.data {
        if !gs.enemies.active[i] do continue
        size := enemy_body_size(e.kind)
        if p.x < e.pos.x - 0.3 || p.x > e.pos.x + size.x + 0.3 ||
           p.y < e.pos.y - 0.3 || p.y > e.pos.y + size.y + 0.3 {
            continue
        }
        dx := p.x - (e.pos.x + size.x*0.5)
        dy := p.y - (e.pos.y + size.y*0.5)
        if d := dx*dx + dy*dy; d < best_dist {
            best, best_dist = i, d
        }
    }
    return best
}

// Center tile for any enemy kind (name predates Garm; used everywhere).
builder_tile :: proc(e: ^Enemy) -> [2]i32 {
    size := enemy_body_size(e.kind)
    return {i32(e.pos.x + size.x*0.5), i32(e.pos.y + size.y*0.5)}
}

// T lies on a den's structure geometry: template solids or shell ring cells
// (the door corridor is open and never part of the structure).
den_structure_slot :: proc(b: ^Builder_State, T: [2]i32) -> bool {
    rel := T - b.anchor
    if rel.x < i32(-2 - DEN_SHELL_LAYERS) || rel.x > i32(2 + DEN_SHELL_LAYERS) ||
       rel.y < i32(-3 - DEN_SHELL_LAYERS) || rel.y > 1 {
        return false
    }
    // Den template solids.
    for t in build_templates[b.build].tiles {
        if t.tile == .Void || t.tile == .Air { continue }
        if rel == t.off { return true }
    }
    // Shell ring cells (door corridor stays open).
    for k in 1 ..= DEN_SHELL_LAYERS {
        x0 := i32(-2 - k)
        x1 := i32( 2 + k)
        y0 := i32(-3 - k)
        y1 := i32( 1)
        if rel.x < x0 || rel.x > x1 || rel.y < y0 || rel.y > y1 { continue }
        if rel.x != x0 && rel.x != x1 && rel.y != y0 && rel.y != y1 { continue }
        if rel.x == x1 && (rel.y == 0 || rel.y == -1) { continue }
        return true
    }
    return false
}

// Builder index owning den structure at T, or -1.  Geometry only — natural
// rock sitting in an unfilled shell slot still counts as the den's wall zone.
den_owner_index :: proc(gs: ^Game_State, T: [2]i32) -> int {
    for i in 0 ..< MAX_ENEMIES {
        if !gs.enemies.active[i] { continue }
        o := &gs.enemies.data[i]
        if o.kind != .Builder || !o.builder.den_built { continue }
        if den_structure_slot(&o.builder, T) { return i }
    }
    return -1
}

// Den tiles and shell slots must never be mined while pathing — otherwise
// builders tunnel through their own (or each other's) den walls and then loop
// forever repairing them.  Only the structure itself is protected; natural
// rock around a den stays diggable or nearby targets become unreachable.
// `owner` (enemy slot, -1 = none): a builder standing INSIDE its own den with
// no way out by the door may chew through its own walls — a den it can't leave
// is a coffin (the bounce loop from playtest 2026-07-16), and the encase loop
// repairs the hole on the next haul.  Only from inside: outside, the world is natural diggable rock
// (never a cage), and an outside exemption turns every commute into a
// break-in/repair treadmill that eats all the hauled ore.
den_protected :: proc(gs: ^Game_State, x, y: int, owner: int = -1) -> bool {
    if !in_bounds(x, y) { return false }
    if !den_material(gs, x, y) { return false }
    dens := collect_dens(gs)
    return den_protected_in(gs, &dens, x, y, owner)
}

// Only placed materials (den wood, shell minerals) are protected.  Natural
// rock stays diggable even inside the den footprint — protecting it walls
// builders out of their own home (e.g. when returning from below).
den_material :: proc(gs: ^Game_State, x, y: int) -> bool {
    t := gs.world.terrain[grid_idx(x, y)]
    return t == .Wood || is_mineral(t)
}

// The builders with a built den, gathered once.  astar_dig asks the den
// question per wood/ore neighbour per node, and walking every enemy slot each
// time was a MAX_ENEMIES-sized loop inside the search's inner loop — at 512
// slots, millions of iterations per full-budget search.
Den_List :: struct {
    idx: [MAX_ENEMIES]i16,
    n:   int,
}

collect_dens :: proc(gs: ^Game_State) -> (dl: Den_List) {
    for i in 0 ..< MAX_ENEMIES {
        if !gs.enemies.active[i] { continue }
        o := &gs.enemies.data[i]
        if o.kind != .Builder || !o.builder.den_built { continue }
        dl.idx[dl.n] = i16(i)
        dl.n += 1
    }
    return
}

// den_protected against a pre-collected den list.  Callers must have checked
// bounds and den_material themselves; the search does both at the call site.
den_protected_in :: proc(gs: ^Game_State, dl: ^Den_List, x, y: int, owner: int = -1) -> bool {
    T := [2]i32{i32(x), i32(y)}
    for k in 0 ..< dl.n {
        i := int(dl.idx[k])
        o := &gs.enemies.data[i]
        if !den_structure_slot(&o.builder, T) { continue }
        if i == owner {
            // Same interior box as the trespass check (den + door corridor).
            // Home has a door: the wall opens only when that door will not do,
            // or the repair pass refills the slot and the next haul never banks.
            rel := builder_tile(o) - o.builder.anchor
            if rel.x >= -1 && rel.x <= 2 && rel.y >= -2 && rel.y <= 0 &&
               (o.builder.stuck_count > 0 || den_door_blocked(gs, dl, &o.builder)) { continue }
        }
        return true
    }
    return false
}

// Is the 2-high door corridor out of a den stopped by something its owner
// cannot dig?  A dug tile is no obstacle: natural rock in the corridor is a way
// out, so only unmineable tiles and another den's walls count.
den_door_blocked :: proc(gs: ^Game_State, dl: ^Den_List, b: ^Builder_State) -> bool {
    for dx in i32(2) ..= i32(2 + DEN_SHELL_LAYERS) do for dy in i32(-1) ..= 0 {
        T := b.anchor + [2]i32{dx, dy}
        x, y := int(T.x), int(T.y)
        if !is_solid(&gs.world, x, y) do continue
        if !is_builder_mineable(gs, x, y) do return true
        if den_material(gs, x, y) && den_protected_in(gs, dl, x, y) do return true
    }
    return false
}

player_tile :: proc(p: ^Player) -> [2]i32 {
    return {i32(p.pos.x + PLAYER_W*0.5), i32(p.pos.y + PLAYER_H*0.5)}
}

// ─── Dig-Aware A* ─────────────────────────────────────────────────────────────
//
//  Cost-based platformer pathfinder.  Besides the normal walk/jump/drop moves
//  it plans straight through the world by paying for modifications:
//    - tunnel into a mineable wall            (COST_MINE)
//    - dig through a mineable floor           (COST_MINE)
//    - mine out a diagonal step upward        (COST_MINE + 1)
//    - bridge a gap by placing a block below  (COST_PLACE)
//  builder_exec_action performs the implied mine/place when each waypoint
//  becomes current, so any in-bounds target surrounded by mineable rock is
//  reachable and the search only fails on budget exhaustion.
//
//  Bridge blocks come from the builder's pocket: a path may plan at most
//  `bridge_budget` bridge moves, so an empty-handed builder plans tunnels
//  and detours instead of conjuring matter.
//
//  Succeeds when a node within chebyshev `stop_within` of `to` is expanded.
//  If the found path exceeds MAX_NAV_PATH, the prefix nearest the start is
//  kept — the builder walks it and replans from there.

PLAN_CARVE_LOOKBACK :: 5   // steps back a climb checks its support against the plan

astar_dig :: proc(gs: ^Game_State, from, to: [2]i32, stop_within: i32, bridge_budget: int, out: ^Nav_Path, owner: int = -1, allow_mining := true, complete: ^bool = nil, protect_placed := false) -> bool {
    w := &gs.world
    out^ = {}

    fx, fy := snap_to_standable(w, int(from.x), int(from.y))
    sf := [2]i32{i32(fx), i32(fy)}
    if chebyshev(sf, to) <= stop_within {
		// The snapped planning origin may differ from the body's real tile (for
		// example while it balances across the edge of a block). Do not report
		// an empty route until the body has physically reached that origin.
		if sf!=from {
			out.tiles[0]=sf
			out.len=1
		}
        if complete != nil do complete^ = true
        return true
    }

    reached_goal := false
    dens := collect_dens(gs)
    // Golems never dig player masonry, and Garm does not slow for it.
    flat_digs := protect_placed || bridge_budget >= MAX_NAV_PATH

    // The den question, asked per dig transition: bounds and material first
    // (cheap, and what almost every tile fails), the den list only after.
    den_blocks :: proc(gs: ^Game_State, dl: ^Den_List, x, y, owner: int) -> bool {
        return in_bounds(x, y) && den_material(gs, x, y) && den_protected_in(gs, dl, x, y, owner)
    }

    A_Node :: struct {
        pos:     [2]i32,
        g:       f32,
        parent:  i16,   // index into nodes[], -1 = start
        bridges: u8,    // bridge moves on the path to this node
    }

    // Does the plan so far carve (x,y)?  A rise mines its landing, its own
    // headroom and the landing's headroom, so a later climb that needs that
    // tile as support contradicts its own plan: the builder carves it, then
    // bridges it back, on every commute.  flip_after_rise only sees one step
    // back; a walk between the two climbs hid the rest.
    plan_carves :: proc(nodes: []A_Node, from: int, x, y: int) -> bool {
        T := [2]i32{i32(x), i32(y)}
        c := from
        for _ in 0 ..< PLAN_CARVE_LOOKBACK {
            pi := int(nodes[c].parent)
            if pi < 0 { return false }
            a, b := nodes[pi].pos, nodes[c].pos
            if b.y == a.y - 1 && b.x != a.x {
                if T == b || T == {a.x, a.y - 1} || T == {b.x, b.y - 1} { return true }
            }
            c = pi
        }
        return false
    }

    mine_cost :: proc(gs: ^Game_State, x, y: int, flat: bool) -> f32 {
        return COST_MINE if flat else dig_cost(gs, x, y)
    }

    A_Trans :: struct {
        pos:    [2]i32,
        cost:   f32,
        bridge: bool,
    }

    nodes:   [MAX_ASTAR_NODES]A_Node
    n_count: int

    // Best known g-cost per grid cell.  f32 max = unvisited.
    g_cost: [GRID_W * GRID_H]f32
    for i in 0 ..< GRID_W * GRID_H { g_cost[i] = max(f32) }

    closed: [GRID_W * GRID_H]bool

    // Open set: node indices.  Linear scan for min-f (budget is small enough).
    open:      [MAX_ASTAR_NODES]i16
    open_size: int

    // Best-effort fallback: expanded node closest to the goal.  If the search
    // exhausts its budget, path there instead of failing — the builder makes
    // progress and replans from the new position.
    best_node := i16(0)
    best_h    := max(f32)

    heuristic :: proc(a, b: [2]i32) -> f32 {
        dx := f32(a.x - b.x)
        dy := f32(a.y - b.y)
        return math.sqrt(dx*dx + dy*dy)
    }

    push_trans :: proc(trans: ^[24]A_Trans, n: ^int, x, y: i32, cost: f32, bridge := false) {
        if n^ < len(trans) { trans[n^] = {{x, y}, cost, bridge}; n^ += 1 }
    }

    // protect_placed marks a golem plan, and golem_mine_tile refuses player
    // masonry AND structures outright — so a golem route must never dig
    // through either, or the worker stalls forever at the waypoint it can't
    // clear (seen live: a plan through a rune scroll chest, .Mineable for the
    // player's reclaim but a structure the golem may not touch).
    dig_allowed :: proc(w: ^World_Grid, x, y: int, protect_placed: bool) -> bool {
        if !in_bounds(x, y) { return false }
        if !protect_placed { return true }
        flags := w.tile_flags[grid_idx(x, y)]
        if .Placed in flags && .Golem_Placed not_in flags { return false }
        return !is_structure_tile[w.terrain[grid_idx(x, y)]]
    }

    // Seed the open set with the start node.
    nodes[0]  = {pos = sf, g = 0, parent = -1}
    g_cost[grid_idx(fx, fy)] = 0
    open[0]   = 0
    n_count   = 1
    open_size = 1
    found     := i16(-1)

    trans: [24]A_Trans

    outer: for open_size > 0 {
        // Pick the open node with the lowest f = g + h.
        best_f  := max(f32)
        best_oi := 0
        for oi in 0 ..< open_size {
            ni := int(open[oi])
            f  := nodes[ni].g + ASTAR_H_WEIGHT * heuristic(nodes[ni].pos, to)
            if f < best_f { best_f = f; best_oi = oi }
        }

        // Pop it (swap with last).
        cur_idx := int(open[best_oi])
        open[best_oi] = open[open_size - 1]
        open_size -= 1

        cur := nodes[cur_idx]
        vi  := grid_idx(int(cur.pos.x), int(cur.pos.y))

        if closed[vi] { continue }   // already expanded via a shorter path
        closed[vi] = true

        if chebyshev(cur.pos, to) <= stop_within {
            found = i16(cur_idx)
            reached_goal = true
            break outer
        }

        cur_h := heuristic(cur.pos, to)
        if cur_h < best_h { best_h = cur_h; best_node = i16(cur_idx) }

        // ── Generate transitions ──────────────────────────────────────────
        x  := int(cur.pos.x)
        y  := int(cur.pos.y)
        nt := 0

        // Dig through the floor (only when landing one tile down).
        floor_mineable := dig_allowed(w, x, y+1, protect_placed)
        if allow_mining && floor_mineable && is_builder_mineable(gs, x, y+1) && is_solid(w, x, y+2) && !den_blocks(gs, &dens, x, y+1, owner) {
            push_trans(&trans, &nt, i32(x), i32(y+1), mine_cost(gs, x, y+1, flat_digs))
        }

        HDIR :: [2]int{-1, 1}
        for d in HDIR {
            nx := x + d

            // Walk flat.
            if is_standable(w, nx, y) {
                push_trans(&trans, &nt, i32(nx), i32(y), COST_WALK)
            }

            // Step up 1.  Head clearance above the landing is required — a
            // 1-high notch is standable but the jump arc can't thread into it.
            if is_solid(w, nx, y) && !is_solid(w, x, y-1) && is_standable(w, nx, y-1) &&
               !is_solid(w, nx, y-2) {
                push_trans(&trans, &nt, i32(nx), i32(y-1), COST_WALK)
            }

            // Drop off edge.
            if !is_solid(w, nx, y) && !is_solid(w, nx, y+1) {
                for fall_y := y + 1; fall_y < GRID_H - 1; fall_y += 1 {
                    if is_standable(w, nx, fall_y) {
                        push_trans(&trans, &nt, i32(nx), i32(fall_y), COST_WALK)
                        break
                    }
                    if is_solid(w, nx, fall_y) { break }
                }
            }

            // Jump forward + up 1 or 2.  The arc must clear the rows it rises
            // through in every intermediate column — checking only the takeoff
            // row lets it plan jumps straight into overhangs (e.g. the wall
            // above a 1-high doorway).
            // A rise of 1 still needs the row above it: under a low ceiling the
            // hop stops dead at the landing's height and falls back, for ever.
            if !is_solid(w, x, y-1) && !is_solid(w, x, y-2) {
                for jdx in 1 ..= 2 {
                    jx := x + d*jdx
                    arc_clear := true
                    for ix := x + d; ix != jx; ix += d {
                        if is_solid(w, ix, y) || is_solid(w, ix, y-1) || is_solid(w, ix, y-2) { arc_clear = false; break }
                    }
                    if arc_clear && is_standable(w, jx, y-1) && !is_solid(w, jx, y-2) {
                        push_trans(&trans, &nt, i32(jx), i32(y-1), COST_WALK)
                    }
                }
                for jdx in 1 ..= 2 {
                    jx := x + d*jdx
                    arc_clear := true
                    for ix := x + d; ix != jx; ix += d {
                        if is_solid(w, ix, y-1) || is_solid(w, ix, y-2) { arc_clear = false; break }
                    }
                    // Water carries a body up a wall it could not jump dry,
                    // and a basin's walls are not dug: this is the way out.
                    swim_out := get_tile(w, x, y) == .Water
                    if arc_clear && (!is_solid(w, jx, y-1) || swim_out) && is_standable(w, jx, y-2) {
                        push_trans(&trans, &nt, i32(jx), i32(y-2), COST_WALK)
                    }
                }
            }

            // Tunnel into a mineable wall (needs a floor under the mined tile).
            wall_mineable := dig_allowed(w, nx, y, protect_placed)
            if allow_mining && wall_mineable && is_builder_mineable(gs, nx, y) && is_solid(w, nx, y+1) && !den_blocks(gs, &dens, nx, y, owner) {
                push_trans(&trans, &nt, i32(nx), i32(y), mine_cost(gs, nx, y, flat_digs))
            }

            // Diagonal step upward, mining whatever blocks the climb: the
            // landing (nx,y-1), our own headroom (x,y-1) and the landing's
            // headroom (nx,y-2) may each be open or mineable.  This is the
            // builders' only way UP through solid rock (zigzag staircases);
            // without it anything above a sheer wall is unreachable — dens
            // included, which starves the whole economy.
            if allow_mining && is_solid(w, nx, y) && in_bounds(nx, y-2) {
                climb_tiles := [3][2]int{{nx, y - 1}, {x, y - 1}, {nx, y - 2}}
                mines     := 0
                carve     := f32(0)
                climbable := true
                for c in climb_tiles {
                    if !is_solid(w, c.x, c.y) { continue }
                    cell_mineable := dig_allowed(w, c.x, c.y, protect_placed)
                    if cell_mineable && is_builder_mineable(gs, c.x, c.y) && !den_blocks(gs, &dens, c.x, c.y, owner) {
                        mines += 1
                        carve += mine_cost(gs, c.x, c.y, flat_digs)
                    } else {
                        climbable = false
                        break
                    }
                }
                // mines == 0 is the plain step-up move handled above.
                if climbable && mines > 0 {
                    cost := carve + 1
                    // Alternating climbs (1-wide shafts) are self-contradicting:
                    // one tile must be both carved (headroom) and left solid
                    // (support).  Prefer straight staircases.  Directly after
                    // a rise the flip is impossible, not merely costly: the
                    // rise carved (or required open) the very tile this climb
                    // needs solid as support.  Planning it anyway is the
                    // carve/place ping-pong livelock seen on map-edge walls.
                    flip_after_rise := false
                    if cur.parent >= 0 {
                        pdx := cur.pos.x - nodes[cur.parent].pos.x
                        pdy := cur.pos.y - nodes[cur.parent].pos.y
                        flip_after_rise = pdy == -1 && pdx != 0 && int(pdx) != d
                        if pdx != 0 && int(pdx) != d { cost += COST_MINE * 2 }
                    }
                    // Garm conjures his stone, so the laying back costs him nothing.
                    self_undone := bridge_budget < MAX_NAV_PATH && plan_carves(nodes[:], int(cur_idx), nx, y)
                    if !flip_after_rise && !self_undone {
                        push_trans(&trans, &nt, i32(nx), i32(y-1), cost)
                    }
                }
            }

            // Bridge a gap: place a block at (nx, y+1) and stand on it —
            // only while the path still has pocket blocks to spend.
            if int(cur.bridges) < bridge_budget &&
               !is_solid(w, nx, y) && in_bounds(nx, y+1) && !is_solid(w, nx, y+1) &&
               builder_may_lay(get_tile(w, nx, y+1)) {
                push_trans(&trans, &nt, i32(nx), i32(y), COST_PLACE, bridge = true)
            }
        }

        // ── Enqueue neighbours ────────────────────────────────────────────
        for i in 0 ..< nt {
            np  := trans[i].pos
            nxi := int(np.x)
            nyi := int(np.y)
            if !in_bounds(nxi, nyi) { continue }
            nvi := grid_idx(nxi, nyi)
            if closed[nvi] { continue }

            tentative_g := cur.g + trans[i].cost
            if tentative_g >= g_cost[nvi] { continue }   // not an improvement
            g_cost[nvi] = tentative_g

            if n_count >= MAX_ASTAR_NODES || open_size >= MAX_ASTAR_NODES {
                break outer   // budget exhausted
            }
            bridges := cur.bridges + (u8(1) if trans[i].bridge else u8(0))
            nodes[n_count] = {pos = np, g = tentative_g, parent = i16(cur_idx), bridges = bridges}
            open[open_size] = i16(n_count)
            open_size += 1
            n_count   += 1

            if chebyshev(np, to) <= stop_within {
                found = i16(n_count - 1)
                reached_goal = true
                break outer
            }
        }
    }

    if found < 0 {
        if best_node <= 0 { return false }   // couldn't move toward goal at all
        found = best_node
    }

    // Length of the found chain.
    length := 0
    for idx := int(found); idx >= 0; idx = int(nodes[idx].parent) { length += 1 }

    // Longer than the buffer: drop waypoints from the DESTINATION side so the
    // kept prefix still starts at the builder.
    skip := max(0, length - MAX_NAV_PATH)
    idx  := int(found)
    for _ in 0 ..< skip { idx = int(nodes[idx].parent) }

    tmp:     [MAX_NAV_PATH][2]i32
    tmp_len: int
    for idx >= 0 {
        tmp[tmp_len] = nodes[idx].pos
        tmp_len += 1
        idx = int(nodes[idx].parent)
    }
    out.len    = tmp_len
    out.cursor = 0
    for i in 0 ..< tmp_len {
        out.tiles[i] = tmp[tmp_len - 1 - i]
    }
    if complete != nil do complete^ = reached_goal
    return true
}

// ─── Path Following ───────────────────────────────────────────────────────────

enemy_follow_path :: proc(e: ^Enemy, nav: ^Enemy_Nav, w: ^World_Grid) {
    if nav.path.cursor >= nav.path.len {
        e.vel.x = 0
        return
    }

    size := enemy_body_size(e.kind)
    target := nav.path.tiles[nav.path.cursor]
    tx := f32(target.x) + 0.5
    ty := f32(target.y) + 0.5
    cx := e.pos.x + size.x*0.5
    cy := e.pos.y + size.y*0.5
    dx := tx - cx
    dy := ty - cy

    // The FINAL waypoint must be stood on precisely: arrival checks are
    // tile-based, and the loose radius can tick it off while the builder's
    // center is still in the neighboring tile (replan livelock).
    accept := f32(0.85) if nav.path.cursor < nav.path.len - 1 else f32(0.35)
    // Never tick off an elevated waypoint while airborne: a jump arc sweeps
    // through several climb waypoints' accept radii, leaving the cursor on
    // one that is unreachable from the ground (jump-bounce livelock).
    if math.sqrt(dx*dx + dy*dy) < accept && (e.grounded || dy > 0) {
        nav.path.cursor += 1
        return
    }

    // Waypoint below: shrink the deadzone so the builder centers exactly over
    // the drop — with the normal deadzone its body can stay clipped onto the
    // adjacent ledge by a hair and never fall.
    below    := dy > 0.6
    deadzone := f32(0.03) if below else f32(0.15)
    if abs(dx) > deadzone {
        e.facing = 1 if dx >= 0 else -1
        e.vel.x  = f32(e.facing) * enemy_speed(e.kind)
    } else {
        e.vel.x = 0
    }

    // Jump when the waypoint is above, or when walking into a wall.  The
    // wall jump needs real walking (vel.x != 0): standing centered over a
    // lower waypoint with stale facing at a wall must not pogo in place.
    if e.grounded {
        waypoint_above := dy < -0.4
        wall_ahead     := e.vel.x != 0 &&
            is_solid(w, int(e.pos.x + f32(e.facing)*(size.x + 0.1)), int(e.pos.y + size.y - 0.5))
        if waypoint_above || wall_ahead {
            e.vel.y = BUILDER_JUMP
        }
    }
}

// Movement/collision resolution lives in physics.odin (move_body), shared
// with the player.

// ─── Spawn ────────────────────────────────────────────────────────────────────

find_cave_floor :: proc(w: ^World_Grid, hint_x, min_clear: int) -> (tx, ty: int, ok: bool) {
    for r in 0 ..= 40 {
        for s in 0 ..= 1 {
            sign := 1 - 2*s
            cx := clamp(hint_x + r*sign, CAVE_LEFT, CAVE_RIGHT - 1)
            for y in CAVE_TOP ..< CAVE_BOT - 1 {
                if !is_solid(w, cx, y) && is_solid(w, cx, y+1) {
                    clear := 0
                    for cy := y; cy >= CAVE_TOP; cy -= 1 {
                        if is_solid(w, cx, cy) { break }
                        clear += 1
                    }
                    if clear >= min_clear { return cx, y, true }
                }
            }
        }
    }
    return 0, 0, false
}

spawn_builder :: proc(gs: ^Game_State, start_x: int) {
    id, ok := enemy_alloc(&gs.enemies)
    if !ok { return }

    e := &gs.enemies.data[id]
    e.kind   = .Builder
    e.hp     = enemy_behaviour[.Builder].hp
    e.hp_max = e.hp

    tx, ty, found := find_cave_floor(&gs.world, start_x, 3)
    if !found {
        enemy_free(&gs.enemies, id)
        return
    }

    e.pos = {f32(tx) + (1 - BUILDER_W)*0.5, f32(ty) - BUILDER_H + 1}
    entity_map_move(&gs.world, enemy_entity_id(id), builder_tile(e), builder_tile(e))
}

// Enemy slot whose center tile is at or adjacent to T (the entity map is a
// center-tile index, so a fat cursor makes bodies clickable) — melee targeting.
// Clear the entity-map marker and release the pool slot.
despawn_enemy :: proc(gs: ^Game_State, i: int) {
    if i < 0 || i >= MAX_ENEMIES || !gs.enemies.active[i] { return }
    tile := builder_tile(&gs.enemies.data[i])
    risen_hero_on_despawn(gs, i, tile)
    entity_map_clear(&gs.world, enemy_entity_id(i), tile)
    enemy_free(&gs.enemies, i)
    gs.enemy_status[i] = {}
}

spawn_level_1_enemies :: proc(gs: ^Game_State) {
    // Spawn order feeds each builder's deterministic job seed; this ordering
    // keeps three territories productive without cave-edge bridge ping-pong.
    spawn_builder(gs, CAVE_RIGHT - 20)
    spawn_builder(gs, CAVE_LEFT  + 20)
    spawn_builder(gs, GRID_W / 2)
}

// ─── Industry Raids ─────────────────────────────────────────────────────────

is_raid_machine :: proc(t: Tile_Type) -> bool {
    return t == .Smelter || t == .Boiler || t == .Magic_Kettle
}

// `growth_timer` advances only while a machine is genuinely producing, and it
// is the sole heat signal here. spread_timer must NOT count: an idle kettle
// consumes nothing by contract (tick_boiler), so a boiler that drank its
// source dry mid-burn keeps its residual burn clock frozen >0 forever — with
// it in this predicate, that machine was a permanent raid magnet no player
// action could cool. The one frame where a completing cycle zeroes
// growth_timer is already bridged by RAID_QUIET_CANCEL's 2 s tolerance.
raid_machine_hot :: proc(gs: ^Game_State, T: [2]i32) -> bool {
    x, y := int(T.x), int(T.y)
    if !in_bounds(x, y) || !is_raid_machine(get_tile(&gs.world, x, y)) do return false
    return gs.world.sim_data[grid_idx(x, y)].growth_timer > 0
}

// Nearest currently working heat source to the player. This makes the warning
// name a machine the player can actually reach and shut down in ten seconds.
raid_heat_target :: proc(gs: ^Game_State) -> (best: [2]i32, ok: bool) {
    pt := player_tile(&gs.player)
    best_d := max(i64)
    for y in 0 ..< GRID_H do for x in 0 ..< GRID_W {
        T := [2]i32{i32(x), i32(y)}
        if !raid_machine_hot(gs, T) do continue
        dx, dy := i64(T.x - pt.x), i64(T.y - pt.y)
        if d := dx*dx + dy*dy; d < best_d {
            best, best_d, ok = T, d, true
        }
    }
    return
}

// `goal` is what separates the two threats that share this body: .Hunt is the
// industry raider (one hot machine, then the player), .Wave_Hunt is the
// UNDERGROUND wave (every structure in the base).
spawn_raider :: proc(gs: ^Game_State, target: [2]i32, hint_x: int, goal := Builder_Goal.Hunt) -> bool {
    id, ok := enemy_alloc(&gs.enemies)
    if !ok do return false

    tx, ty, found := find_cave_floor(&gs.world, hint_x, 3)
    if !found {
        enemy_free(&gs.enemies, id)
        return false
    }

    e := &gs.enemies.data[id]
    e.kind   = .Raider
    e.hp     = enemy_behaviour[.Raider].hp
    e.hp_max = e.hp
    e.facing = 1 if target.x >= i32(tx) else -1
    e.pos    = {f32(tx) + (1 - BUILDER_W)*0.5, f32(ty) - BUILDER_H + 1}
    e.builder.goal        = goal
    e.builder.target_tile = target
    e.builder.has_target  = true
    e.builder.plan_target = target
    // pocket stays 0: tunnellers earn every block by digging, like builders.
    // A primed pocket was 8 conjured mineable blocks per raider; the escape
    // pillar already conjures on its own when the pocket runs dry, and the
    // first carve restores the A* bridging budget within one MINE_TIME.
    entity_map_move(&gs.world, enemy_entity_id(id), builder_tile(e), builder_tile(e))
    log_action(gs, "Tunneller#%d enters at (%d,%d), drawn to (%d,%d)", id, tx, ty, target.x, target.y)
    return true
}

spawn_tunneller_raid :: proc(gs: ^Game_State, target: [2]i32) -> int {
    // Two approach columns bracket the target. `find_cave_floor` snaps each
    // into the nearest upper-cave pocket; the dig-aware A* handles the rest.
    hints := [RAID_COUNT]int{
        clamp(int(target.x) - 18, CAVE_LEFT + 4, CAVE_RIGHT - 5),
        clamp(int(target.x) + 18, CAVE_LEFT + 4, CAVE_RIGHT - 5),
    }
    spawned := 0
    for hint in hints do if spawn_raider(gs, target, hint) do spawned += 1
    return spawned
}

// Called after the tile sim, so machine growth_timer describes this frame's
// actual work. The director is transient; spawned enemies themselves save in
// Enemy_Store, while reloading during a warning harmlessly resets the buildup.
update_raids :: proc(gs: ^Game_State) {
    r := &gs.raid
    if r.cooldown > 0 do r.cooldown = max(0, r.cooldown - gs.delta_time)

    // The first rune scroll is the grace-period boundary: industry may be
    // built earlier, but raids do not begin before the player enters the loop.
    if gs.level_index != LEVEL_SURFACE || !gs.progression.rune_scroll_found[0] {
        if r.warning_active do clear_tile_fx_kind(gs, .Raid_Rumble)
        r.pressure, r.quiet_timer = 0, 0
        r.warning_active = false
        return
    }

    // A loaded raid lives in Enemy_Store even though the director is
    // transient. Never stack a fresh wave on surviving saved tunnellers.
    raiders_present := false
    for &e, i in gs.enemies.data do if gs.enemies.active[i] && e.kind == .Raider {
        raiders_present = true
        break
    }
    if raiders_present && !r.warning_active {
        r.pressure = 0
        return
    }

    if r.warning_active {
        if raid_machine_hot(gs, r.target) {
            r.quiet_timer = 0
        } else {
            r.quiet_timer += gs.delta_time
            if r.quiet_timer >= RAID_QUIET_CANCEL {
                notify(gs, "The underground rumbling fades - the fires are quiet")
                clear_tile_fx_kind(gs, .Raid_Rumble)
                r^ = {cooldown = 20}
                return
            }
        }
        r.warning_timer -= gs.delta_time
        if r.warning_timer > 0 do return

        spawned := spawn_tunneller_raid(gs, r.target)
        if spawned > 0 {
            notify(gs, "%d tunnellers break toward the hot machine!", spawned)
            spawn_tile_fx(gs, .Raid_Rumble, r.target, 0.6, {205, 55, 24, 255})
            eq_push(&gs.events, Event{type = .Play_Sound, payload = {int_val = i32(Sound_ID.Builder_Shriek)}})
            log_action(gs, "Industry raid begins: %d tunnellers target (%d,%d)", spawned, r.target.x, r.target.y)
            r^ = {cooldown = RAID_COOLDOWN}
        } else {
            r^ = {cooldown = 10}
        }
        return
    }

    if r.cooldown > 0 do return
    target, hot := raid_heat_target(gs)
    if !hot {
        r.pressure = max(0, r.pressure - gs.delta_time*2)
        return
    }
    r.pressure += gs.delta_time
    if r.pressure < RAID_PRESSURE_TIME do return

    r.target         = target
    r.warning_timer  = RAID_WARNING_TIME
    r.warning_active = true
    r.quiet_timer    = 0
    spawn_tile_fx(gs, .Raid_Rumble, target, RAID_WARNING_TIME, {205, 55, 24, 255})
    notify(gs, "The ground growls beneath the hot machine - kill its fire!")
    eq_push(&gs.events, Event{type = .Play_Sound, payload = {int_val = i32(Sound_ID.Builder_Shriek)}})
    log_action(gs, "Industry raid warning at (%d,%d)", target.x, target.y)
}

// ─── Wave hunting (shared by every wave enemy) ──────────────────────────────

// Would handle_tile_mined turn this tile away?  It refuses a loaded silo, a
// loaded barrel/coffer, and any scroll chest (enemies never break one).  A wave
// hunter must know that BEFORE it picks a target: discovering it by failing
// at the tile is a livelock — the hunter arrives, swings forever, the tile
// never falls, and the wave never resolves.  So refused containers are
// excluded from targeting rather than found the hard way.
wave_target_refused :: proc(gs: ^Game_State, T: [2]i32) -> bool {
    x, y := int(T.x), int(T.y)
    if !in_bounds(x, y) do return true
    tile := get_tile(&gs.world, x, y)
    if tile == .Silo {
        if s := silo_at(gs, gs.level_index, T); s != nil do return silo_total(s) > 0
        return false
    }
    if is_rune_scroll_chest(tile) do return true
    if tile == .Barrel || tile == .Rune_Coffer {
        if b := barrel_at(gs, gs.level_index, T); b != nil do return barrel_total(b) > 0
        return false
    }
    return false
}

// Nearest structure worth smashing, read off the director's structure index
// (wave.odin) — this runs every frame for every hunter that lacks a target,
// so it must never walk the grid.  Each entry is checked live: a structure
// smashed since the beat is skipped, a refusal is decided now.
find_wave_structure_target :: proc(gs: ^Game_State, from: [2]i32, avoid: [][2]i32 = nil) -> (best: [2]i32, ok: bool) {
    w := &gs.wave
    if !w.structures_indexed do wave_index_structures(gs)
    best_d := max(i64)
    for i in 0 ..< w.structures_n {
        T := w.structures[i]
        if !is_structure_tile[gs.world.terrain[grid_idx(int(T.x), int(T.y))]] do continue
        if wave_target_refused(gs, T) do continue
        if slice.contains(avoid, T) do continue
        dx, dy := i64(T.x - from.x), i64(T.y - from.y)
        if d := dx*dx + dy*dy; d < best_d {
            best, best_d, ok = T, d, true
        }
    }
    return
}

// Is the held target still worth attacking?  Goal-dependent so one brain
// serves both threats: an industry raider keeps EXACTLY its old predicate,
// a wave hunter takes any live structure the mined-tile handler will break.
wave_target_valid :: proc(gs: ^Game_State, goal: Builder_Goal, T: [2]i32) -> bool {
    t := get_tile(&gs.world, int(T.x), int(T.y))
    if goal != .Wave_Hunt do return is_raid_machine(t)
    return is_structure_tile[t] && !wave_target_refused(gs, T)
}

// Standable surface ground near hint_x — the sky-side mirror of
// find_cave_floor: it scans the open air ABOVE the stone cap, so a wave
// walker lands on the world's roof rather than in a cave pocket.
find_surface_floor :: proc(w: ^World_Grid, hint_x: int) -> (tx, ty: int, ok: bool) {
    for r in 0 ..= 40 {
        for s in 0 ..= 1 {
            sign := 1 - 2*s
            cx := clamp(hint_x + r*sign, CAVE_LEFT, CAVE_RIGHT - 1)
            for y in 1 ..< CAVE_TOP {
                if !is_solid(w, cx, y) && is_solid(w, cx, y+1) do return cx, y, true
            }
        }
    }
    return 0, 0, false
}

// The x a wave enters from: alternating map edges, so a wave arrives as a
// pincer rather than a queue down one lane.
wave_edge_x :: proc(n: int) -> int {
    return CAVE_LEFT + 6 if n % 2 == 0 else CAVE_RIGHT - 7
}

// AIR: a fire sprite drops in from the sky over the surface.  It flies, so it
// needs no floor — only open air to hang in.
spawn_wave_flyer :: proc(gs: ^Game_State, n: int) -> bool {
    return spawn_flyer_at(gs, wave_edge_x(n), max(2, SURFACE_Y - 8 - (n / 2)))
}

// One hunting fire sprite at a sky tile - the wave's flyer and the F4 sky
// swarm share it.
spawn_flyer_at :: proc(gs: ^Game_State, x, y: int) -> bool {
    id, ok := enemy_alloc(&gs.enemies)
    if !ok do return false

    e := &gs.enemies.data[id]
    e^ = Enemy{
        kind = .Fire_Sprite, hp = enemy_behaviour[.Fire_Sprite].hp, hp_max = enemy_behaviour[.Fire_Sprite].hp,
        facing = 1 if x < GRID_W/2 else -1,
        pos = {f32(x) + (1 - BUILDER_W)*0.5, f32(y)},
    }
    e.builder.goal = .Wave_Hunt
    entity_map_move(&gs.world, enemy_entity_id(id), builder_tile(e), builder_tile(e))
    log_action(gs, "Fire sprite#%d drops out of the sky at (%d,%d)", id, x, y)
    return true
}

// GROUND: a vargr walks in over the surface.
spawn_wave_walker :: proc(gs: ^Game_State, n: int) -> bool {
    id, ok := enemy_alloc(&gs.enemies)
    if !ok do return false

    tx, ty, found := find_surface_floor(&gs.world, wave_edge_x(n))
    if !found {
        enemy_free(&gs.enemies, id)
        return false
    }
    e := &gs.enemies.data[id]
    e^ = Enemy{
        kind = .Vargr, hp = enemy_behaviour[.Vargr].hp, hp_max = enemy_behaviour[.Vargr].hp,
        facing = 1 if tx < GRID_W/2 else -1,
        pos = {f32(tx) + (1 - BUILDER_W)*0.5, f32(ty) - BUILDER_H + 1},
    }
    e.builder.goal = .Wave_Hunt
    entity_map_move(&gs.world, enemy_entity_id(id), builder_tile(e), builder_tile(e))
    log_action(gs, "Vargr#%d comes over the ridge at (%d,%d)", id, tx, ty)
    return true
}

// UNDERGROUND: the proven tunneller, re-aimed.  spawn_raider does the cave
// pocket and the dig-aware approach; .Wave_Hunt is what makes it hunt the
// whole base instead of one hot machine.  Bracket columns like a raid.
spawn_wave_tunneller :: proc(gs: ^Game_State, n: int) -> bool {
    pt := player_tile(&gs.player)
    target, found := find_wave_structure_target(gs, pt)
    if !found do target = pt
    hint := clamp(int(target.x) + (18 if n % 2 == 0 else -18), CAVE_LEFT + 4, CAVE_RIGHT - 5)
    return spawn_raider(gs, target, hint, .Wave_Hunt)
}

// ─── Raid Debug Actions (F4 menu, input.odin drives these) ──────────────────

// Skip the 20 s pressure build: arm the warning at the nearest hot machine
// right now. Honors the real gates so the forced warning survives update_raids.
debug_raid_warn_now :: proc(gs: ^Game_State) {
    if gs.level_index != LEVEL_SURFACE || !gs.progression.rune_scroll_found[0] {
        notify(gs, "Debug: raids need the surface level + the first rune scroll")
        return
    }
    target, hot := raid_heat_target(gs)
    if !hot {
        notify(gs, "Debug: no working Smelter/Boiler/Kettle to threaten")
        return
    }
    r := &gs.raid
    r.target         = target
    r.warning_timer  = RAID_WARNING_TIME
    r.warning_active = true
    r.quiet_timer    = 0
    spawn_tile_fx(gs, .Raid_Rumble, target, RAID_WARNING_TIME, {205, 55, 24, 255})
    notify(gs, "The ground growls beneath the hot machine - kill its fire!")
    eq_push(&gs.events, Event{type = .Play_Sound, payload = {int_val = i32(Sound_ID.Builder_Shriek)}})
    log_action(gs, "Debug: raid warning forced at (%d,%d)", target.x, target.y)
}

// Skip warning and gates both: land the pair immediately, aimed at the nearest
// hot machine or, with no industry running, at the player's own tile.
debug_raid_spawn_now :: proc(gs: ^Game_State) {
    target, hot := raid_heat_target(gs)
    if !hot do target = player_tile(&gs.player)
    if gs.raid.warning_active do clear_tile_fx_kind(gs, .Raid_Rumble)
    spawned := spawn_tunneller_raid(gs, target)
    if spawned > 0 {
        notify(gs, "Debug: %d tunnellers break toward (%d,%d)!", spawned, target.x, target.y)
        spawn_tile_fx(gs, .Raid_Rumble, target, 0.6, {205, 55, 24, 255})
        eq_push(&gs.events, Event{type = .Play_Sound, payload = {int_val = i32(Sound_ID.Builder_Shriek)}})
        log_action(gs, "Debug: raid forced, %d tunnellers target (%d,%d)", spawned, target.x, target.y)
        gs.raid = {cooldown = RAID_COOLDOWN}
    } else {
        notify(gs, "Debug: no cave pocket found - tunnellers have nowhere to enter")
    }
}

// Repeatable testing: despawn every tunneller and factory-reset the director.
debug_raid_clear :: proc(gs: ^Game_State) {
    cleared := 0
    for &e, i in gs.enemies.data do if gs.enemies.active[i] && e.kind == .Raider {
        despawn_enemy(gs, i)
        cleared += 1
    }
    clear_tile_fx_kind(gs, .Raid_Rumble)
    gs.raid = {}
    notify(gs, "Debug: %d tunnellers cleared, raid pressure reset", cleared)
}

// ─── Builder Path Actions (mine / place) ──────────────────────────────────────
//
//  Called each frame before path following.  If the current waypoint requires
//  a mine or bridge action, execute it (rate-limited by mine_timer) and return
//  true so the caller suppresses horizontal movement while working.

builder_exec_action :: proc(e: ^Enemy, id: int, nav: ^Enemy_Nav, gs: ^Game_State) -> (busy: bool) {
    // Cooling down after a recent action — stand still.
    if nav.mine_timer > 0 {
        e.vel.x = 0
        return true
    }

    if nav.path.cursor >= nav.path.len { return false }

    target := nav.path.tiles[nav.path.cursor]
    tx := int(target.x)
    ty := int(target.y)

    // Climbing waypoint: the up-step needs our own headroom and the
    // landing's headroom open too (see the A* climb move) — carve them.
    // Grounded only: while airborne the builder tile fluctuates and the
    // carves land on the wrong rows.
    bt := builder_tile(e)
    if target.y < bt.y && e.grounded {
        climb := [2][2]i32{{bt.x, bt.y - 1}, {target.x, target.y - 1}}
        for c in climb {
            cx := int(c.x)
            cy := int(c.y)
            if is_solid(&gs.world, cx, cy) && is_builder_mineable(gs, cx, cy) &&
               !den_protected(gs, cx, cy, id) {
                if !builder_dig_ready(e, id, gs, c) do return true
                dropped := smash_tile(gs, cx, cy)
                eq_push(&gs.events, Event{type = .Builder_Mined, tile = c})
                log_action(gs, "Builder clears climb tile (%d,%d)", cx, cy)
                if !dropped do e.builder.pocket = min(e.builder.pocket + 1, POCKET_MAX)
                nav.mine_timer = MINE_TIME
                e.vel.x = 0
                return true
            }
        }
    }

    // Mine: waypoint tile is solid and mineable (dens are off-limits).
    if is_builder_mineable(gs, tx, ty) && !den_protected(gs, tx, ty, id) {
        if !builder_dig_ready(e, id, gs, target) do return true
        dropped := smash_tile(gs, tx, ty)
        eq_push(&gs.events, Event{type = .Builder_Mined, tile = {i32(tx), i32(ty)}})
        log_action(gs, "Builder mines (%d,%d)", tx, ty)
        if !dropped do e.builder.pocket = min(e.builder.pocket + 1, POCKET_MAX)
        nav.mine_timer = MINE_TIME
        e.vel.x = 0
        return true
    }

    // Bridge: no floor below waypoint — spend a pocket block on it.  An
    // empty pocket (floor mined out from under a planned waypoint) clears
    // the path so the next replan routes around the gap instead.  Only for
    // waypoints at or below our height: a floor under an elevated waypoint
    // doesn't get us up there, and it feeds a place/carve livelock with
    // the climb rule above.
    if target.y >= bt.y && in_bounds(tx, ty+1) && !is_solid(&gs.world, tx, ty+1) &&
       builder_may_lay(get_tile(&gs.world, tx, ty+1)) {
        if e.builder.pocket == 0 {
            log_action(gs, "Builder out of blocks at (%d,%d) - replans", tx, ty+1)
            nav.path = {}
            e.vel.x  = 0
            return true
        }
        e.builder.pocket -= 1
        set_tile(&gs.world, tx, ty+1, .Stone)
        eq_push(&gs.events, Event{type = .Builder_Placed, tile = {i32(tx), i32(ty+1)}})
        log_action(gs, "Builder places at (%d,%d)", tx, ty+1)
        nav.mine_timer = MINE_TIME
        e.vel.x = 0

        // Place-loop detection: re-placing the SAME bridge block means the
        // plan keeps dying at the same jump (mines in between don't clear
        // the count — the loop interleaves carves with the re-place).
        pt := [2]i32{i32(tx), i32(ty + 1)}
        if pt == e.builder.last_place {
            e.builder.place_reps += 1
            if e.builder.place_reps >= PLACE_REPS_LOOP {
                e.builder.place_reps  = 0
                builder_start_escape(e)
                log_action(gs, "Builder loops at (%d,%d) - pillars up and out", tx, ty+1)
            }
        } else {
            e.builder.last_place = pt
            e.builder.place_reps = 1
        }
        return true
    }

    return false
}

builder_start_escape :: proc(e: ^Enemy) {
    e.builder.escaping     = true
    e.builder.escape_timer = 0
    e.builder.escape_from  = builder_tile(e).y
    e.nav.path = {}
}

// In a slot of its own den, or down a pit with its head in one.
builder_in_own_slot :: proc(e: ^Enemy) -> bool {
    bt := builder_tile(e)
    if den_structure_slot(&e.builder, bt) { return true }
    return den_structure_slot(&e.builder, bt - {0, 1}) && builder_overlaps_tile(e, int(bt.x), int(bt.y) - 1)
}

// A roof the pillar may eat.  A struck builder down a slot of its own den is in
// the wall, not outside it: it cuts through, the pillar's blocks seal the
// column behind it and the encase loop repairs the rest.
builder_may_eat_roof :: proc(gs: ^Game_State, e: ^Enemy, id, x, y: int) -> bool {
    if !is_builder_mineable(gs, x, y) { return false }
    if !den_protected(gs, x, y, id) { return true }
    return e.builder.stuck_count > 0 && den_structure_slot(&e.builder, {i32(x), i32(y)}) &&
           builder_in_own_slot(e)
}

// The pillar escape: mine the ceiling, jump, place a block underfoot while
// airborne; repeat.  Runs instead of the goal until the column overhead is
// open AND we stand ESCAPE_MIN_RISE above where the loop bit (so the replan
// starts from a genuinely new vantage), or the hard time cap ends it.
builder_escape_pillar :: proc(e: ^Enemy, id: int, gs: ^Game_State, dt: f32) {
    b   := &e.builder
    nav := &e.nav
    e.vel.x = 0
    bt := builder_tile(e)
    x  := int(bt.x)
    y  := int(bt.y)

    b.escape_timer += dt
    head_clear := !is_solid(&gs.world, x, y-1) && !is_solid(&gs.world, x, y-2)
    risen      := b.escape_from - bt.y >= ESCAPE_MIN_RISE
    if (head_clear && risen) || b.escape_timer >= ESCAPE_MAX_TIME {
        b.escaping = false
        nav.path   = {}
        log_action(gs, "Builder#%d escape ends %d up - replanning", id, b.escape_from - bt.y)
        if b.escape_from - bt.y <= 0 { builder_strike(e, id, gs, "pillar rose nothing") }
        // Left set, it marks a pillar that gained nothing (builder_pillar_toward).
        if risen do b.escape_from = 0
        return
    }

    // Airborne at the top of the hop: slot a block in underfoot.  A rescue
    // move doesn't stall on an empty pocket — it spends what it has (the
    // ceiling mined on the way up refills it) and conjures the rest; the
    // time cap bounds the free stone to a handful.
    if !e.grounded {
        if e.vel.y >= 0 && !is_solid(&gs.world, x, y+1) && in_bounds(x, y+1) &&
           e.pos.y + BUILDER_H <= f32(y+1) + (den_structure_slot(b, bt) ? BODY_EPS : 0) &&   // a head on its den roof stops a hair short
           builder_may_lay(get_tile(&gs.world, x, y+1)) {
            if b.pocket > 0 do b.pocket -= 1
            set_tile(&gs.world, x, y+1, .Stone)
            eq_push(&gs.events, Event{type = .Builder_Placed, tile = {i32(x), i32(y+1)}})
        }
        return
    }

    if nav.mine_timer > 0 { return }   // update_builder ticks it down
    // Ceiling in the way: eat it, both rows, since a hop rises through two and
    // the escape only ends with both clear.  Otherwise hop.
    roof_y := y - 1 if is_solid(&gs.world, x, y-1) else y - 2
    if is_solid(&gs.world, x, roof_y) {
        if builder_may_eat_roof(gs, e, id, x, roof_y) {
            own_wall := den_protected(gs, x, roof_y, id)
            dropped := smash_tile(gs, x, roof_y)
            eq_push(&gs.events, Event{type = .Builder_Mined, tile = {i32(x), i32(roof_y)}})
            if !dropped do b.pocket = min(b.pocket + 1, POCKET_MAX)
            nav.mine_timer = MINE_TIME
            if own_wall && roof_y == y - 1 {   // the cut is the way out: walk it, the slot is still open
                b.escaping    = false
                b.stuck_count = 0
                nav.path      = {}
            }
        } else {
            // Unmineable roof — the pillar can't continue; replan from here.
            b.escaping = false
            builder_strike(e, id, gs, "pillar refused")
        }
        return
    }
    e.vel.y = BUILDER_JUMP
}

// ─── Shared Helpers ───────────────────────────────────────────────────────────

tile_satisfied :: proc(w: ^World_Grid, T: [2]i32, desired: Tile_Type) -> bool {
    x := int(T.x)
    y := int(T.y)
    if !in_bounds(x, y) { return true }   // out of bounds — nothing to do
    if desired == .Void || desired == .Air {
        return !is_solid(w, x, y)
    }
    return get_tile(w, x, y) == desired
}

builder_overlaps_tile :: proc(e: ^Enemy, x, y: int) -> bool {
    size  := enemy_body_size(e.kind)
    left  := int(e.pos.x)
    right := int(e.pos.x + size.x - 0.01)
    top   := int(e.pos.y)
    bot   := int(e.pos.y + size.y - 0.01)
    return x >= left && x <= right && y >= top && y <= bot
}

builder_pause :: proc(b: ^Builder_State, t: f32, resume: Builder_Goal) {
    b.goal     = .Cooldown
    b.cooldown = t
    b.resume   = resume
}

// Place `t` at T, stepping aside first if the body overlaps the slot.
// Rate-limits via mine_timer.  Returns true once placed.
builder_place_tile :: proc(e: ^Enemy, gs: ^Game_State, T: [2]i32, t: Tile_Type) -> bool {
    x := int(T.x)
    y := int(T.y)
    if builder_overlaps_tile(e, x, y) {
        // Step out of the slot TOWARD the anchor: stepping away can carry
        // the builder out of its arrival radius and oscillate forever
        // (arrive -> step out -> walk back -> arrive).  Flip if that side
        // is walled off.
        dir := f32(1) if f32(e.builder.anchor.x) + 0.5 > e.pos.x + BUILDER_W*0.5 else f32(-1)
        ahead_x := e.pos.x - 0.2 if dir < 0 else e.pos.x + BUILDER_W + 0.2
        if is_solid(&gs.world, int(ahead_x), int(e.pos.y + BUILDER_H*0.5)) {
            dir = -dir
        }
        e.facing = int(dir)
        e.vel.x  = dir * BUILDER_SPEED
        return false
    }
    set_tile(&gs.world, x, y, t)
    eq_push(&gs.events, Event{type = .Builder_Placed, tile = T})
    e.nav.mine_timer = MINE_TIME
    return true
}

// Act on the current den template step: carve wrong solids, place the desired
// tile.  Rate-limited by mine_timer; the step advances via the satisfied-check.
builder_do_step :: proc(e: ^Enemy, id: int, gs: ^Game_State, T: [2]i32, desired: Tile_Type) {
    nav := &e.nav
    if nav.mine_timer > 0 { return }

    x := int(T.x)
    y := int(T.y)
    w := &gs.world

    if is_solid(w, x, y) {
        old := get_tile(w, x, y)
        // Wrong tile in the slot — carve it out first.
        //
        // A player's machine or container is NOT plain rock: builder_pick_den_site
        // roams the caves, so a den slot can land on a working smelter with no
        // boss and no raid involved.  The raw carve below would delete it —
        // dropping nothing, voiding the ore/fuel/bars in its buffers, and walking
        // straight past the loaded-silo refusal.  handle_tile_mined is the path
        // that spills a machine whole (the tunneller demolition pins it), routes
        // the barrel/silo records, and refuses a loaded container.  It also
        // consumes the tile itself, so no Builder_Mined goes out for it — the
        // handler plays its own dig sound.  Only a player's build qualifies; plain
        // terrain keeps the cheap carve, and with it the pocket economy.
        if knocks_loose(old) {
            handle_tile_mined(gs, Event{
                type   = .Tile_Mined,
                source = enemy_entity_id(id),
                tile   = T,
            })
            if get_tile(w, x, y) == old {
                // Refused — a loaded barrel or silo stands its ground.  Step
                // past it like any other obstruction rather than hammering the
                // same slot for the rest of the session.
                e.builder.step += 1
            } else {
                // No pocket block here: the machine went to the ground as an
                // item, and conjuring a block on top of it would mint matter.
                log_action(gs, "Builder#%d knocks %v loose at (%d,%d)", id, old, x, y)
                nav.mine_timer = MINE_TIME
            }
        } else if is_builder_mineable(gs, x, y) {
            set_tile(w, x, y, .Void)
            eq_push(&gs.events, Event{type = .Builder_Mined, tile = T})
            log_action(gs, "Builder#%d carves (%d,%d)", id, x, y)
            e.builder.pocket = min(e.builder.pocket + 1, POCKET_MAX)
            nav.mine_timer = MINE_TIME
        } else {
            e.builder.step += 1   // unmineable obstruction — skip this step
        }
        e.builder.stuck_timer = 0
        return
    }

    if !builder_may_lay(get_tile(w, x, y)) {
        e.builder.step += 1   // the way to Hell is no den slot, a pond neither
        return
    }

    if builder_place_tile(e, gs, T, desired) {
        log_action(gs, "Builder#%d builds %v at (%d,%d)", id, desired, x, y)
        e.builder.stuck_timer = 0
    }
}

// Last-resort rescue: if the body overlaps solid tiles (walled in by another
// builder, or a physics edge case), mine every mineable tile it touches.
builder_dig_free :: proc(e: ^Enemy, id: int, gs: ^Game_State) {
    size := enemy_body_size(e.kind)
    if !body_embedded(&gs.world, e.pos, size) {
        return
    }
    left  := int(e.pos.x)
    right := int(e.pos.x + size.x - BODY_EPS)
    top   := int(e.pos.y)
    bot   := int(e.pos.y + size.y - BODY_EPS)
    for y in top ..= bot {
        for x in left ..= right {
            if !is_builder_mineable(gs, x, y) do continue
            // A machine, turret part or door goes the den carve's way: it spills
            // whole, and no pocket block is minted on top of the item.
            t := get_tile(&gs.world, x, y)
            if .Placeable in terrain_table[t].flags || t == .Door {
                handle_tile_mined(gs, Event{
                    type   = .Tile_Mined,
                    source = enemy_entity_id(id),
                    tile   = {i32(x), i32(y)},
                })
                continue
            }
            set_tile(&gs.world, x, y, .Void)
            eq_push(&gs.events, Event{type = .Builder_Mined, tile = {i32(x), i32(y)}})
            e.builder.pocket = min(e.builder.pocket + 1, POCKET_MAX)
        }
    }
    log_action(gs, "Builder#%d digs itself free at (%.1f,%.1f)", id, e.pos.x, e.pos.y)
}

// The den's owner senses harm to its home — mined structure or a trespasser
// inside — and hunts the intruder regardless of line of sight.
builder_alert :: proc(gs: ^Game_State, i: int) {
    e := &gs.enemies.data[i]
    b := &e.builder
    if b.goal == .Hunt { return }
    log_action(gs, "Builder#%d den breached - hunting", i)
    notify(gs, "A builder shrieks - it hunts you!")
    eq_push(&gs.events, Event{type = .Play_Sound, payload = {int_val = i32(Sound_ID.Builder_Shriek)}})
    b.goal        = .Hunt
    b.los_timer   = 0
    b.plan_target = {-99, -99}
    b.stuck_timer = 0
    b.stuck_count = 0
    e.nav.path    = {}
}

// Back to mineral duty after a hunt (or when prey is gone).
builder_return_to_work :: proc(e: ^Enemy) {
    b := &e.builder
    b.goal        = .Encase_Den if b.carry != .Air else .Fetch_Mineral
    b.has_target  = false
    b.stuck_timer = 0
    b.stuck_count = 0
    e.nav.path    = {}
}

// A* has no way up through open air: a target overhead with no route would be
// struck at, dropped and picked again for ever.  Pillar toward it instead, which
// changes the map the next search reads.  Refused under a roof it cannot mine.
builder_pillar_toward :: proc(e: ^Enemy, id: int, gs: ^Game_State, T: [2]i32, reason: string) -> bool {
    bt := builder_tile(e)
    if reason != "no path" || T.y >= bt.y do return false
    x, y := int(bt.x), int(bt.y) - 1
    if is_solid(&gs.world, x, y) && (!is_builder_mineable(gs, x, y) || den_protected(gs, x, y, id)) do return false
    b := &e.builder
    // The pillar that just ended here gained nothing: another is the same loop.
    // Refuse once, so the caller gives the job up, and let a later no-route try.
    if b.escape_from != 0 && abs(bt.y - b.escape_from) < ESCAPE_MIN_RISE {
        b.escape_from = 0
        return false
    }
    b.escaping, b.escape_timer, b.escape_from = true, 0, bt.y
    log_action(gs, "Builder#%d has no route to (%d,%d) - pillars up", id, T.x, T.y)
    return true
}

builder_strike :: proc(e: ^Enemy, id: int, gs: ^Game_State, reason: string) {
    b := &e.builder
    b.stuck_count += 1
    b.stuck_timer  = 0
    log_action(gs, "Builder#%d strike %d (%s) pos=(%.1f,%.1f) cursor=%d/%d grounded=%v",
        id, b.stuck_count, reason, e.pos.x, e.pos.y,
        e.nav.path.cursor, e.nav.path.len, e.grounded)
    e.nav.path = {}

    if b.stuck_count >= MAX_STRIKES {
        b.stuck_count = 0
        builder_dig_free(e, id, gs)
        // Only builders shuffle goals on a strikeout; the boss and the draugr
        // have a single fixed purpose — dig free and keep hunting.
        if e.kind != .Builder { return }
        #partial switch b.goal {
        case .Build_Den:
            log_action(gs, "Builder#%d abandons den site (%d,%d)", id, b.anchor.x, b.anchor.y)
            b.anchor = DEN_UNSET
            b.step   = 0
            builder_pause(b, JOB_COOLDOWN, .Build_Den)
        case .Fetch_Mineral:
            if builder_pillar_toward(e, id, gs, b.target_tile, reason) do return
            log_action(gs, "Builder#%d gives up on (%d,%d)", id, b.target_tile.x, b.target_tile.y)
            b.avoid[b.avoid_n % len(b.avoid)] = b.target_tile
            b.avoid_n += 1
            b.has_target = false
            builder_pause(b, JOB_COOLDOWN, b.goal)
            if b.den_built && builder_in_own_slot(e) {   // no way out of its own slot
                b.stuck_count = 1
                builder_start_escape(e)
            }
        case .Encase_Den:
            if builder_pillar_toward(e, id, gs, b.anchor, reason) do return
            // Couldn't get home — set the block down at its feet, whole, and
            // fetch elsewhere rather than freeze in a retry loop.
            log_action(gs, "Builder#%d can't get home - drops %v", id, b.carry)
            drop := terrain_table[b.carry].drop_item
            if drop != .None do spawn_ground_item(&gs.world, builder_tile(e), drop, 1)
            b.carry = .Air
            builder_pause(b, JOB_COOLDOWN, .Fetch_Mineral)
        case .Hunt:
            log_action(gs, "Builder#%d gives up the hunt", id)
            builder_return_to_work(e)
        }
    }
}

// ─── Travel ───────────────────────────────────────────────────────────────────
//
//  Move toward T until within `stop` (chebyshev).  Handles pathing, mine/place
//  along the way, and the progress watchdog.  Returns true once in range.

builder_travel :: proc(e: ^Enemy, id: int, gs: ^Game_State, dt: f32, T: [2]i32, stop: i32) -> bool {
    b   := &e.builder
    nav := &e.nav

    // Arrival does NOT reset the watchdog: the on-site work loops (den step,
    // encase placement) accumulate stuck_timer and reset it on each completed
    // action, so a builder frozen at its worksite still strikes out.
    if chebyshev(builder_tile(e), T) <= stop {
        e.vel.x  = 0
        nav.path = {}
        return true
    }

    if nav.path.cursor >= nav.path.len {
        if b.replan_timer > 0 {
            e.vel.x = 0
            return false
        }
        size := enemy_body_size(e.kind)
        from := [2]i32{i32(e.pos.x + size.x*0.5), i32(e.pos.y + size.y - 0.01)}
        // A pack shares one plan: a same-kind hunter bound for the same tile
        // whose route crosses my tile lends me its remainder, no search at all.
        if nav_borrow_path(gs, e, id, from, T) {
            b.replan_timer = REPLAN_MIN
        } else {
            if gs.nav_searches >= MAX_NAV_SEARCHES_PER_FRAME {
                e.vel.x = 0   // the frame's budget is spent - ask again next frame
                return false
            }
            gs.nav_searches += 1
            b.replan_timer = REPLAN_MIN
        // Garm conjures his masonry (update_garm keeps his pocket topped up):
        // boss bridging is never limited by mined blocks, so the planner may
        // route through any climb a builder could only afford with a full pocket.
        budget := MAX_NAV_PATH if e.kind == .Garm else int(b.pocket)
        complete: bool
        if !astar_dig(gs, from, T, stop, budget, &nav.path, id, complete = &complete) {
            b.replan_timer = REPLAN_BACKOFF
            builder_strike(e, id, gs, "no path")
            return false
        }
        // A best-effort route means the budget ran dry: walk what it found,
        // but do not buy another full-budget search half a second from now.
        if !complete do b.replan_timer = REPLAN_BACKOFF
        }
    }

    // Watchdog measures PATH progress (waypoint reached or a mine/place
    // action), not raw movement — jump-bouncing in place must count as stuck.
    prev_cursor := nav.path.cursor
    acted := builder_exec_action(e, id, nav, gs)
    if !acted {
        enemy_follow_path(e, nav, &gs.world)
    }
    if acted || nav.path.cursor != prev_cursor {
        b.stuck_timer = 0
    } else {
        b.stuck_timer += dt
        if b.stuck_timer >= STUCK_TIME {
            builder_strike(e, id, gs, "no progress")
        }
    }
    return false
}

// Glenn's idea for the 512-enemy stall: hunters bunched on one target walk
// the same road, so let one plan and the rest copy.  A lender is another
// active enemy of my kind whose plan_target is my travel target and whose
// route passes through the tile I stand on; I take the route from that
// waypoint on, cursor at zero, exactly as a fresh plan would start on my own
// tile.  Waypoints the lender already walked still count - a follower behind
// the leader on the same road is the common case.  Only the wave hunters
// borrow (Raider, Vargr): they carry no pocket, so a borrowed route never
// asks for a bridge block the borrower does not have.
//
// A route that ENDS on my tile lends nothing: a MAX_NAV_PATH prefix stops
// mid-road, and the first save with this feature had a whole wave parked on
// that tile, each wolf copying a one-tile route from the next, consuming it
// on the spot, and never searching (all 303 at (70,53), 2026-09-01).  The
// last waypoint is excluded, so a borrow always moves me at least one tile.
nav_borrow_path :: proc(gs: ^Game_State, e: ^Enemy, id: int, from, T: [2]i32) -> bool {
    if e.kind != .Raider && e.kind != .Vargr do return false
    for i in 0 ..< MAX_ENEMIES {
        if i == id || !gs.enemies.active[i] do continue
        o := &gs.enemies.data[i]
        if o.kind != e.kind || o.builder.plan_target != T do continue
        p := &o.nav.path
        for k in 0 ..< p.len - 1 {
            if p.tiles[k] != from do continue
            n := p.len - k
            for j in 0 ..< n do e.nav.path.tiles[j] = p.tiles[k + j]
            e.nav.path.len    = n
            e.nav.path.cursor = 0
            return true
        }
    }
    return false
}

// ─── Den Site & Targets ───────────────────────────────────────────────────────

site_is_free :: proc(gs: ^Game_State, id: int, ax: int) -> bool {
    for i in 0 ..< MAX_ENEMIES {
        if i == id || !gs.enemies.active[i] { continue }
        o := &gs.enemies.data[i]
        if o.kind != .Builder || o.builder.anchor == DEN_UNSET { continue }
        if abs(int(o.builder.anchor.x) - ax) < SITE_SPACING { return false }
    }
    return true
}

builder_pick_den_site :: proc(e: ^Enemy, id: int, gs: ^Game_State) {
    b := &e.builder
    e.vel.x = 0

    seed := u32(gs.frame) + u32(id) * 7919
    for attempt in 0 ..< 8 {
        h := whash(seed + u32(attempt) * 131)

        // Prefer sites near the builder (short, reliable paths); widen the
        // search each attempt, going cave-wide on the last ones.
        hint_x: int
        if attempt < 5 {
            span := 25 + attempt*15
            hint_x = clamp(int(e.pos.x) - span + int(h % u32(span*2)), CAVE_LEFT, CAVE_RIGHT - 1)
        } else {
            hint_x = CAVE_LEFT + int(h % u32(CAVE_RIGHT - CAVE_LEFT))
        }

        ax, ay, found := find_cave_floor(&gs.world, hint_x, 4)
        if !found { continue }

        // Template extents (x ± 2, y − 3) must fit inside the cave shell.
        if ax - 2 <= CAVE_LEFT || ax + 2 >= CAVE_RIGHT - 1 { continue }
        if ay - 4 <= CAVE_TOP  || ay + 1 >= CAVE_BOT       { continue }

        if !site_is_free(gs, id, ax) { continue }

        if e.kind == .Builder { b.build = .Shelter }   // Garm keeps his .Lair
        b.anchor      = {i32(ax), i32(ay)}
        b.step        = 0
        b.den_built   = false
        b.stuck_count = 0
        b.stuck_timer = 0
        e.nav.path    = {}
        log_action(gs, "Builder#%d starts den at (%d,%d)", id, ax, ay)
        return
    }

    // No site this frame — brief pause, then try again.
    builder_pause(b, 1.0, .Build_Den)
}

// Nearest harvestable mineral (ore first, plain stone as fallback), skipping
// every builder's den + shell zone so nobody eats a den.
// The ring holds four give-ups, so a cluster of five bad targets would cycle for
// ever.  Each lap of the ring with nothing fetched widens the blacklist, until
// the whole cluster is off the list; a harvest, or an empty search, narrows it.
builder_avoid_radius :: proc(b: ^Builder_State) -> i32 {
    return AVOID_RADIUS * i32(max(b.avoid_n / len(b.avoid), 1))
}

builder_avoid_narrow :: proc(b: ^Builder_State) {
    if b.avoid_n >= len(b.avoid) do b.avoid_n = b.avoid_n % len(b.avoid) + len(b.avoid)
}

builder_find_mineral :: proc(e: ^Enemy, gs: ^Game_State) -> (best: [2]i32, ok: bool) {
    b  := &e.builder
    bt := builder_tile(e)
    // Dome extent + reach: anything closer sits in the pocket over/behind a
    // shell whose approach the den protection forbids digging through.
    exclude := i32(2 + DEN_SHELL_LAYERS) + BUILDER_REACH

    anchors:   [MAX_ENEMIES][2]i32
    n_anchors: int
    for i in 0 ..< MAX_ENEMIES {
        if !gs.enemies.active[i] { continue }
        o := &gs.enemies.data[i]
        if o.kind == .Builder && o.builder.anchor != DEN_UNSET {
            anchors[n_anchors] = o.builder.anchor
            n_anchors += 1
        }
    }

    avoid_r := builder_avoid_radius(b)
    best_d := max(i64)
    for pass in 0 ..< 2 {
        for y in CAVE_TOP ..< CAVE_BOT {
            for x in CAVE_LEFT ..< CAVE_RIGHT {
                t := gs.world.terrain[grid_idx(x, y)]
                want := is_mineral(t) if pass == 0 else t == .Stone
                if !want { continue }
                cand := [2]i32{i32(x), i32(y)}
                avoided := false
                for k in 0 ..< min(b.avoid_n, len(b.avoid)) {
                    if chebyshev(cand, b.avoid[k]) <= avoid_r { avoided = true; break }
                }
                if avoided { continue }
                near_den := false
                for a in 0 ..< n_anchors {
                    if chebyshev(cand, anchors[a]) <= exclude { near_den = true; break }
                }
                if near_den { continue }
                dx := i64(cand.x - bt.x)
                dy := i64(cand.y - bt.y)
                d  := dx*dx + dy*dy
                if d < best_d { best_d = d; best = cand; ok = true }
            }
        }
        if ok { break }
    }
    return
}

// Next open slot on the den: damaged den walls first (patched with whatever is
// carried), then the mineral shell, ring by ring.  The 2-high door corridor is
// kept open through every layer.  None under the builder's own body: under_body
// says one was passed over, so "nothing found" does not read as "shell complete".
den_next_build_tile :: proc(e: ^Enemy, gs: ^Game_State) -> (T: [2]i32, ok, under_body: bool) {
    b  := &e.builder
    pt := player_tile(&gs.player)

    usable :: proc(e: ^Enemy, gs: ^Game_State, pt, cand: [2]i32, under_body: ^bool) -> bool {
        if !in_bounds(int(cand.x), int(cand.y)) { return false }
        if is_solid(&gs.world, int(cand.x), int(cand.y)) { return false }
        if cand == pt && !gs.player.dead { return false }   // never entomb by accident
        // The slot under the body: a builder down a one-wide floor slot cannot
        // step out of it, so asking would pin it there, striking forever.
        if builder_overlaps_tile(e, int(cand.x), int(cand.y)) {
            under_body^ = true
            return false
        }
        return true
    }

    // Repair pass: missing solid den tiles.
    tmpl := build_templates[b.build]
    for t in tmpl.tiles {
        if t.tile == .Void || t.tile == .Air { continue }
        cand := b.anchor + t.off
        if usable(e, gs, pt, cand, &under_body) { return cand, true, under_body }
    }

    // Shell pass: perimeter rings around the den box, closest layer first.
    for k in 1 ..= DEN_SHELL_LAYERS {
        x0 := i32(-2 - k)
        x1 := i32( 2 + k)
        y0 := i32(-3 - k)
        y1 := i32( 1)
        for dy in y0 ..= y1 {
            for dx in x0 ..= x1 {
                if dx != x0 && dx != x1 && dy != y0 && dy != y1 { continue }  // ring only
                if dx == x1 && (dy == 0 || dy == -1) { continue }             // door corridor
                cand := b.anchor + [2]i32{dx, dy}
                if usable(e, gs, pt, cand, &under_body) { return cand, true, under_body }
            }
        }
    }
    return {}, false, under_body
}

// ─── Vision ───────────────────────────────────────────────────────────────────

builder_sees_player :: proc(e: ^Enemy, gs: ^Game_State, radius: f32) -> bool {
    if gs.player.dead { return false }
    bc := [2]f32{e.pos.x + BUILDER_W*0.5, e.pos.y + BUILDER_H*0.5}
    pc := [2]f32{gs.player.pos.x + PLAYER_W*0.5, gs.player.pos.y + PLAYER_H*0.5}
    d  := pc - bc
    if d.x*d.x + d.y*d.y > radius*radius { return false }
    return sight_line_clear(&gs.world, bc, pc)
}

// Sample a sight line every half tile; any solid tile blocks it.  skip_ends
// ignores the tiles the two ends stand in, for a looker that is itself a solid
// tile (the Rainbow Laser) and a target that may be dug into a wall: only what
// lies BETWEEN them blocks.  past_turrets lets a turret's shot pass over other
// turrets; a turret still blocks everyone else's sight.  PURE — render reaches
// this through laser_target.
sight_line_clear :: proc(w: ^World_Grid, from, to: [2]f32, skip_ends := false, past_turrets := false) -> bool {
    d     := to - from
    steps := int(math.sqrt(d.x*d.x + d.y*d.y) * 2) + 1
    for i in 1 ..< steps {
        p := from + d * (f32(i) / f32(steps))
        x, y := int(p.x), int(p.y)
        if skip_ends {
            if x == int(from.x) && y == int(from.y) { continue }
            if x == int(to.x)   && y == int(to.y)   { continue }
        }
        if is_solid(w, x, y) && !(past_turrets && is_turret_tile(get_tile(w, x, y))) { return false }
    }
    return true
}

// ─── Goals ────────────────────────────────────────────────────────────────────

builder_build_den :: proc(e: ^Enemy, id: int, gs: ^Game_State, dt: f32) {
    b := &e.builder
    if b.anchor == DEN_UNSET {
        builder_pick_den_site(e, id, gs)
        return
    }

    tmpl := build_templates[b.build]
    for b.step < len(tmpl.tiles) {
        t := tmpl.tiles[b.step]
        if !tile_satisfied(&gs.world, b.anchor + t.off, t.tile) { break }
        b.step += 1
    }
    if b.step >= len(tmpl.tiles) {
        log_action(gs, "Builder#%d den complete at (%d,%d)", id, b.anchor.x, b.anchor.y)
        b.den_built = true
        e.nav.path  = {}
        builder_pause(b, JOB_COOLDOWN, .Fetch_Mineral)
        return
    }

    t := tmpl.tiles[b.step]
    T := b.anchor + t.off
    reach := GARM_BUILD_REACH if e.kind == .Garm else BUILDER_REACH
    if builder_travel(e, id, gs, dt, T, reach) {
        builder_do_step(e, id, gs, T, t.tile)
        // do_step resets stuck_timer on every completed action; a builder
        // frozen at the worksite (step-aside pinned) must still strike out.
        b.stuck_timer += dt
        if b.stuck_timer >= STUCK_TIME {
            builder_strike(e, id, gs, "can't build")
        }
    }
}

builder_fetch :: proc(e: ^Enemy, id: int, gs: ^Game_State, dt: f32) {
    b := &e.builder
    if b.carry != .Air {
        b.goal = .Encase_Den
        return
    }

    // Target gone (mined by someone, or dug through en route)?
    if b.has_target {
        t := get_tile(&gs.world, int(b.target_tile.x), int(b.target_tile.y))
        if !is_mineral(t) && t != .Stone { b.has_target = false }
    }
    if !b.has_target {
        T, found := builder_find_mineral(e, gs)
        if !found {
            builder_avoid_narrow(b)
            builder_pause(b, 2.0, .Fetch_Mineral)
            return
        }
        b.target_tile = T
        b.has_target  = true
        log_action(gs, "Builder#%d prospecting %v at (%d,%d)",
            id, get_tile(&gs.world, int(T.x), int(T.y)), T.x, T.y)
    }

    if builder_travel(e, id, gs, dt, b.target_tile, BUILDER_REACH) {
        if e.nav.mine_timer <= 0 {
            tx := int(b.target_tile.x)
            ty := int(b.target_tile.y)
            t  := get_tile(&gs.world, tx, ty)
            set_tile(&gs.world, tx, ty, .Void)
            eq_push(&gs.events, Event{type = .Builder_Mined, tile = b.target_tile})
            log_action(gs, "Builder#%d harvests %v at (%d,%d)", id, t, tx, ty)
            e.nav.mine_timer = MINE_TIME
            b.carry      = t
            b.has_target = false
            b.goal       = .Encase_Den
            builder_avoid_narrow(b)
        }
    }
}

// Bank the carried block as loot on the den floor: the stockpile a raider
// can break in and steal.  Falls back to discarding when the floor stacks
// are full (the den can only hold so much).
builder_deposit_loot :: proc(e: ^Enemy, id: int, gs: ^Game_State) {
    b    := &e.builder
    drop := terrain_table[b.carry].drop_item
    if drop != .None {
        for off in DEN_FLOOR_OFFS {
            T := b.anchor + off
            if !in_bounds(int(T.x), int(T.y)) { continue }
            idx      := grid_idx(int(T.x), int(T.y))
            existing := gs.world.items[idx]
            if existing == drop && gs.world.item_counts[idx] > 0 {
                if int(gs.world.item_counts[idx]) < MAX_STACK {
                    gs.world.item_counts[idx] += 1
                    log_action(gs, "Builder#%d stockpiles %v at (%d,%d)", id, drop, T.x, T.y)
                    break
                }
            } else if existing == .None || gs.world.item_counts[idx] == 0 {
                gs.world.items[idx]       = drop
                gs.world.item_counts[idx] = 1
                log_action(gs, "Builder#%d stockpiles %v at (%d,%d)", id, drop, T.x, T.y)
                break
            }
        }
    }
    b.carry = .Air
}

// What lies on a den's floor, the number over its door.
den_hoard :: proc(gs: ^Game_State, b: ^Builder_State) -> (n: int) {
    for off in DEN_FLOOR_OFFS {
        T := b.anchor + off
        if in_bounds(int(T.x), int(T.y)) do n += int(gs.world.item_counts[grid_idx(int(T.x), int(T.y))])
    }
    return
}

// The player lifted something off a tile: if that tile is a den's floor, the
// owner shrieks now and comes for the base later.  One grudge at a time.
den_check_robbed :: proc(gs: ^Game_State, T: [2]i32) {
    for i in 0 ..< MAX_ENEMIES {
        if !gs.enemies.active[i] { continue }
        e := &gs.enemies.data[i]
        if e.kind != .Builder || !e.builder.den_built { continue }
        for off in DEN_FLOOR_OFFS {
            if T != e.builder.anchor + off { continue }
            builder_alert(gs, i)
            if !gs.den_revenge.active {
                gs.den_revenge = {true, DEN_REVENGE_DELAY, i, gs.level_index, e.builder.anchor}
                log_action(gs, "Builder#%d's den is robbed at (%d,%d)", i, T.x, T.y)
            }
            return
        }
    }
}

// Step 5b1z.  The grudge comes due on the surface, where the base is, through
// the wave warning.  An owner who has died since, or who rose as a draugr, has
// no friends to bring: killing him is how you settle it.
update_den_revenge :: proc(gs: ^Game_State) {
    r := &gs.den_revenge
    if !r.active do return
    r.timer -= gs.delta_time
    if r.timer > 0 || gs.level_index != LEVEL_SURFACE || gs.wave.pending do return
    r.active = false

    here   := r.level == gs.level_index
    store  := &gs.enemies if here else &gs.levels.enemies[r.level]
    world  := &gs.world if here else &gs.levels.worlds[r.level]
    owner  := &store.data[r.owner]
    if !store.active[r.owner] || owner.kind != .Builder || owner.builder.anchor != r.anchor {
        log_action(gs, "The robbed builder of (%d,%d) is gone - no revenge", r.anchor.x, r.anchor.y)
        return
    }
    entity_map_clear(world, enemy_entity_id(r.owner), builder_tile(owner))
    enemy_free(store, r.owner)   // bare: the store may be another level's, despawn_enemy only knows gs.enemies
    wave_trigger(gs, .Underground, DEN_REVENGE_PARTY)
    notify(gs, "The builder you robbed has found friends!")
    log_action(gs, "Builder#%d leaves his den at (%d,%d) as a raider", r.owner, r.anchor.x, r.anchor.y)
}

builder_encase :: proc(e: ^Enemy, id: int, gs: ^Game_State, dt: f32) {
    b := &e.builder
    if b.carry == .Air {
        b.goal = .Fetch_Mineral
        return
    }

    // Work from home: walk back to the den, then fit the block into the next
    // open shell slot from there.  (Approaching each dome slot individually is
    // a reachability minefield — slots interleave with protected rock.)
    // The last slot under the body takes the walk all the way in: no slot
    // touches the anchor, so from there it is clear to place.  No walk out
    // takes the pillar, and a pillar that is refused is a strike.
    T, found, under_body := den_next_build_tile(e, gs)
    if !found && under_body && b.stuck_count > 0 {
        builder_start_escape(e)
        log_action(gs, "Builder#%d is under its last slot - pillars up and out", id)
        return
    }
    if !builder_travel(e, id, gs, dt, b.anchor, !found && under_body ? 0 : 2) { return }

    if !found {
        // Shell complete and intact — bank the haul as den loot and keep
        // fetching.  This is the ore economy: builders drain the shared
        // veins for as long as they live, and the stockpile is raidable.
        builder_deposit_loot(e, id, gs)
        b.stuck_timer = 0
        builder_pause(b, JOB_COOLDOWN, .Fetch_Mineral)
        return
    }
    // Same worksite watchdog as den building: a pinned step-aside must
    // strike out (3rd strike drops the block and refetches).
    b.stuck_timer += dt
    if b.stuck_timer >= STUCK_TIME {
        builder_strike(e, id, gs, "can't place")
        return
    }
    if e.nav.mine_timer <= 0 && builder_place_tile(e, gs, T, b.carry) {
        b.stuck_timer = 0
        log_action(gs, "Builder#%d encases den with %v at (%d,%d)",
            id, b.carry, T.x, T.y)
        b.carry = .Air
        b.goal  = .Fetch_Mineral
    }
}

builder_hunt :: proc(e: ^Enemy, id: int, gs: ^Game_State, dt: f32) {
    b := &e.builder
    if gs.player.dead {
        log_action(gs, "Builder#%d prey eliminated - back to work", id)
        builder_return_to_work(e)
        return
    }

    pt := player_tile(&gs.player)
    bt := builder_tile(e)

    // Den defense: a raider on the den's grounds is never "lost" — the
    // den's own walls blocking sight must not protect the intruder.
    raiding := b.den_built &&
        chebyshev(pt, b.anchor) <= i32(2 + DEN_SHELL_LAYERS) + 2

    if raiding || builder_sees_player(e, gs, HUNT_LOSE_DIST) {
        b.los_timer = 0
    } else {
        b.los_timer += dt
    }
    if !raiding && (f32(chebyshev(bt, pt)) > HUNT_LOSE_DIST || b.los_timer > LOS_MEMORY) {
        log_action(gs, "Builder#%d lost the player - back to work", id)
        builder_return_to_work(e)
        return
    }

    // Player moved off the planned intercept — force a replan.
    if chebyshev(b.plan_target, pt) > 2 {
        b.plan_target = pt
        e.nav.path    = {}
    }

    if builder_travel(e, id, gs, dt, pt, 1) {
        e.facing = 1 if pt.x >= bt.x else -1
        if b.attack_timer <= 0 {
            b.attack_timer = ATTACK_TIME
            eq_push(&gs.events, Event{
                type    = .Damage_Dealt,
                source  = enemy_entity_id(id),
                target  = PLAYER_ID,
                payload = {int_val = ATTACK_DAMAGE},
            })
            log_action(gs, "Builder#%d bites the player", id)
        }
    }
}

// ─── Builder Update ───────────────────────────────────────────────────────────

update_builder :: proc(e: ^Enemy, id: int, gs: ^Game_State, dt: f32) {
    b := &e.builder
    e.nav.mine_timer -= dt
    b.replan_timer   -= dt
    b.attack_timer   -= dt

    // Pillar escape overrides everything: a stuck builder digs itself out
    // first, then resumes whatever it was doing with a fresh path.
    if b.escaping {
        builder_escape_pillar(e, id, gs, dt)
        return
    }

    // Trespass: the player standing inside the den enrages its owner, no
    // line of sight needed (interior box: template carve + door corridor).
    if b.den_built && b.goal != .Hunt && !gs.player.dead {
        rel := player_tile(&gs.player) - b.anchor
        if rel.x >= -1 && rel.x <= 2 && rel.y >= -2 && rel.y <= 0 {
            builder_alert(gs, id)
        }
    }

    // Spot the player while out working (den construction stays focused).
    if (b.goal == .Fetch_Mineral || b.goal == .Encase_Den) &&
       builder_sees_player(e, gs, HUNT_RADIUS) {
        log_action(gs, "Builder#%d spots the player - hunting", id)
        b.goal        = .Hunt
        b.los_timer   = 0
        b.plan_target = {-99, -99}
        b.stuck_timer = 0
        b.stuck_count = 0
        e.nav.path    = {}
    }

    switch b.goal {
    case .Build_Den:
        builder_build_den(e, id, gs, dt)
    case .Fetch_Mineral:
        builder_fetch(e, id, gs, dt)
    case .Encase_Den:
        builder_encase(e, id, gs, dt)
    case .Hunt, .Wave_Hunt:
        // .Wave_Hunt is not a builder goal — only wave kinds carry it, and
        // they run update_raider/update_fire_sprite instead.  Listed here
        // rather than hidden behind a #partial so this switch keeps failing
        // the build if a real goal is ever left out.
        builder_hunt(e, id, gs, dt)
    case .Cooldown:
        e.vel.x     = 0
        b.cooldown -= dt
        if b.cooldown <= 0 { b.goal = b.resume }
    }
}

// A raid tunneller follows the heat-marked machine without LOS and uses the
// shared dig-aware travel. A defender who intercepts it gets priority; after
// the machine falls it relentlessly hunts the nearest player/golem.
update_raider :: proc(e: ^Enemy, id: int, gs: ^Game_State, dt: f32) {
    b := &e.builder
    e.nav.mine_timer -= dt
    b.replan_timer   -= dt
    b.attack_timer   -= dt

    if b.escaping {
        builder_escape_pillar(e, id, gs, dt)
        return
    }

    bt := builder_tile(e)
    pt := player_tile(&gs.player)
    golem_id := -1
    if gt, gid, gok := nearest_deployed_golem(gs, bt); gok &&
       (gs.player.dead || chebyshev(bt, gt) < chebyshev(bt, pt)) {
        pt = gt
        golem_id = gid
    }
    defender_alive := !gs.player.dead || golem_id >= 0

    strike_defender :: proc(e: ^Enemy, id: int, gs: ^Game_State, T: [2]i32, golem_id: int) {
        wave := e.builder.goal == .Wave_Hunt
        e.facing = 1 if T.x >= builder_tile(e).x else -1
        e.builder.attack_timer = WAVE_ATTACK_TIME if wave else RAIDER_ATTACK_TIME
        dmg := WAVE_DAMAGE if wave else RAIDER_DAMAGE
        if golem_id >= 0 {
            eq_push(&gs.events, Event{type = .Golem_Damaged, tile = {i32(golem_id), 0}, payload = {int_val = i32(dmg)}})
            log_action(gs, "Tunneller#%d strikes golem#%d", id, golem_id)
        } else {
            eq_push(&gs.events, Event{
                type    = .Damage_Dealt,
                source  = enemy_entity_id(id),
                target  = PLAYER_ID,
                payload = {int_val = i32(dmg)},
            })
            log_action(gs, "Tunneller#%d strikes the player", id)
        }
    }

    // An adjacent defender can body-block the siege and draw the blow.
    if defender_alive && chebyshev(bt, pt) <= 1 {
        e.vel.x = 0
        if b.attack_timer <= 0 do strike_defender(e, id, gs, pt, golem_id)
        return
    }

    wave := b.goal == .Wave_Hunt
    if b.has_target && wave_target_valid(gs, b.goal, b.target_tile) {
        if chebyshev(b.plan_target, b.target_tile) > 0 {
            b.plan_target = b.target_tile
            e.nav.path = {}
        }
        if builder_travel(e, id, gs, dt, b.target_tile, 1) && b.attack_timer <= 0 {
            T := b.target_tile
            e.facing = 1 if T.x >= bt.x else -1
            b.attack_timer = WAVE_ATTACK_TIME if wave else RAIDER_ATTACK_TIME
            // The normal mined-tile path drops the machine and every buffered
            // input/fuel/output item. The raid threatens the base, never the
            // conservation law.
            handle_tile_mined(gs, Event{type = .Tile_Mined, source = enemy_entity_id(id), tile = T})
            spawn_tile_fx(gs, .Raid_Rumble, T, 0.5, {235, 75, 28, 255})
            notify(gs, "A wave breaker tears your structure down!" if wave else "A tunneller smashes the hot machine!")
            log_action(gs, "Enemy#%d demolishes a structure at (%d,%d)", id, T.x, T.y)
            b.has_target  = false
            b.plan_target = {-99, -99}
            e.nav.path    = {}
        }
        return
    }
    b.has_target = false

    // A wave hunter works the base down one structure at a time and only
    // turns on the player when nothing built is left standing.
    if wave {
        if T, found := find_wave_structure_target(gs, bt); found {
            b.target_tile = T
            b.has_target  = true
            b.plan_target = T
            e.nav.path    = {}
            return
        }
    }

    if !defender_alive {
        e.vel.x = 0
        return
    }
    if chebyshev(b.plan_target, pt) > 2 {
        b.plan_target = pt
        e.nav.path = {}
    }
    if builder_travel(e, id, gs, dt, pt, 1) && b.attack_timer <= 0 {
        strike_defender(e, id, gs, pt, golem_id)
    }
}

// The first flying enemy.  It STEERS rather than paths: the surface is open
// sky, and the shared A* is dig-aware — a flyer running it would tunnel
// through the roof it is supposed to sail over.  Gravity is handed to the
// SHARED mover as zero (update_enemies), so collision, grounding and the
// entity-map bookkeeping stay identical to every other body's.
update_fire_sprite :: proc(e: ^Enemy, id: int, gs: ^Game_State, dt: f32) {
    // Aim at a point: full speed toward it, and a wall dead ahead means rise.
    // The climb probe spans half a tile above the head to just under the
    // feet, because a single foot-height point cleared a tree canopy before
    // the body did — steering dove straight back in and the mover pinned two
    // sprites against one trunk for 72 seconds of playtest.  The under-feet
    // row keeps the climb committed until the whole body crosses with margin.
    fly_to :: proc(e: ^Enemy, gs: ^Game_State, goal: [2]f32) {
        center := [2]f32{e.pos.x + BUILDER_W*0.5, e.pos.y + BUILDER_H*0.5}
        d      := goal - center
        l      := math.sqrt(d.x*d.x + d.y*d.y)
        if l < 0.001 {
            e.vel = {}
            return
        }
        e.vel    = d / l * FIRE_SPRITE_SPEED
        e.facing = 1 if d.x >= 0 else -1

        // No climb inside the last tile of sideways travel: the prey itself
        // is solid, and rising over it would hold the sprite out of range.
        if abs(d.x) <= 1.0 do return
        ax := int(e.pos.x + f32(e.facing)*(BUILDER_W + 0.1))
        for row in int(e.pos.y - 0.5) ..= int(e.pos.y + BUILDER_H + 0.4) {
            if is_solid(&gs.world, ax, row) {
                e.vel.y = -FIRE_SPRITE_SPEED
                break
            }
        }
    }

    b := &e.builder
    b.attack_timer -= dt
    bt := builder_tile(e)

    // It steers and cannot dig, so a target under rock pins it on the roof for
    // good (run 3: two sprites parked over the cave altar), and a parked
    // survivor also holds back every later wave.  Same tile a whole window
    // later: drop that target; too many of those and it gutters out.
    // Standing in reach of its prey never counts.
    b.stuck_timer += dt
    if b.stuck_timer >= FIRE_SPRITE_STALL {
        b.stuck_timer = 0
        stalled := chebyshev(bt, b.anchor) <= 1
        b.anchor = bt
        if stalled {
            b.stuck_count += 1
            if b.stuck_count >= FIRE_SPRITE_GIVE_UP {
                log_action(gs, "Fire sprite#%d gutters out at (%d,%d)", id, bt.x, bt.y)
                despawn_enemy(gs, id)
                return
            }
            if b.has_target {
                log_action(gs, "Fire sprite#%d gives up on (%d,%d)", id, b.target_tile.x, b.target_tile.y)
                b.avoid[b.avoid_n % len(b.avoid)] = b.target_tile
                b.avoid_n += 1
                b.has_target = false
            }
        }
    }

    // Re-aim on spawn and whenever what it was burning is gone.
    if !b.has_target || !wave_target_valid(gs, b.goal, b.target_tile) {
        T, found := find_wave_structure_target(gs, bt, b.avoid[:min(b.avoid_n, len(b.avoid))])
        b.target_tile, b.has_target = T, found
    }

    if b.has_target {
        T := b.target_tile
        if chebyshev(bt, T) <= 1 {
            e.vel = {}
            b.stuck_timer = 0
            if b.attack_timer <= 0 {
                b.attack_timer = WAVE_ATTACK_TIME
                e.facing = 1 if T.x >= bt.x else -1
                b.stuck_count = 0
                handle_tile_mined(gs, Event{type = .Tile_Mined, source = enemy_entity_id(id), tile = T})
                spawn_tile_fx(gs, .Raid_Rumble, T, 0.5, {235, 75, 28, 255})
                notify(gs, "A fire sprite burns your structure down!")
                log_action(gs, "Fire sprite#%d burns the structure at (%d,%d)", id, T.x, T.y)
                b.has_target = false
            }
            return
        }
        fly_to(e, gs, {f32(T.x) + 0.5, f32(T.y) + 0.5})
        return
    }

    // Nothing built left standing: the sprite turns on whoever is defending.
    pt := player_tile(&gs.player)
    golem_id := -1
    if gt, gid, gok := nearest_deployed_golem(gs, bt); gok &&
       (gs.player.dead || chebyshev(bt, gt) < chebyshev(bt, pt)) {
        pt = gt
        golem_id = gid
    }
    if gs.player.dead && golem_id < 0 {
        e.vel = {}
        return
    }

    if chebyshev(bt, pt) <= 1 {
        e.vel = {}
        b.stuck_timer = 0
        if b.attack_timer <= 0 {
            b.attack_timer = WAVE_ATTACK_TIME
            e.facing = 1 if pt.x >= bt.x else -1
            b.stuck_count = 0
            if golem_id >= 0 {
                eq_push(&gs.events, Event{type = .Golem_Damaged, tile = {i32(golem_id), 0}, payload = {int_val = i32(WAVE_DAMAGE)}})
                log_action(gs, "Fire sprite#%d burns golem#%d", id, golem_id)
            } else {
                eq_push(&gs.events, Event{
                    type    = .Damage_Dealt,
                    source  = enemy_entity_id(id),
                    target  = PLAYER_ID,
                    payload = {int_val = i32(WAVE_DAMAGE)},
                })
                log_action(gs, "Fire sprite#%d burns the player", id)
            }
        }
        return
    }
    fly_to(e, gs, {f32(pt.x) + 0.5, f32(pt.y) + 0.5})
}

// ─── Update All Enemies ───────────────────────────────────────────────────────

update_enemies :: proc(gs: ^Game_State) {
    dt := gs.delta_time
    gs.nav_searches = 0
    for i in 0 ..< MAX_ENEMIES {
        if !gs.enemies.active[i] { continue }
        e := &gs.enemies.data[i]
        prev := builder_tile(e)
        move_dt := enemy_move_dt(gs, i)
        row := enemy_behaviour[e.kind]
        move_body(&gs.world, &e.pos, &e.vel, row.body, move_dt, row.gravity, BUILDER_MAX_FALL, &e.grounded)
        row.update(e, i, gs, dt)
        if !gs.enemies.active[i] {   // it gutted out
            entity_map_clear(&gs.world, enemy_entity_id(i), prev)
            continue
        }
        entity_map_move(&gs.world, enemy_entity_id(i), prev, builder_tile(e))
    }
    dig_clocks_sweep(gs)
}
