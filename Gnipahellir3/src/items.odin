package game

import rl "vendor:raylib"

// ─── Item Behavior Table ──────────────────────────────────────────────────────

MAX_STACK :: 99

Item_Info :: struct {
    name:       string,
    color:      rl.Color,
    place_tile: Tile_Type,   // .Air = not placeable
    desc:       string,      // shown under MATERIALS in the crafting detail panel
}

is_rune_scroll :: proc(it: Item) -> bool {
    return it == .Rune_Scroll_A || it == .Rune_Scroll_B || it == .Rune_Scroll_C || it == .Sky_Rune_Scroll
}

// The item in the player's hand: the selected bag slot's stack (hotbar model —
// what you select is what you hold). Weapons and tools are never "equipped";
// gear in unselected slots is inert. .None = bare hands.
held_item :: proc(p: ^Player) -> Item {
    sel := p.inventory.selected
    if sel < 0 || sel >= MAX_INVENTORY do return .None
    s := p.inventory.slots[sel]
    if s.count <= 0 do return .None
    return s.item
}

// ─── Equipment & Stats ────────────────────────────────────────────────────────
//
//  Which slot an item occupies (.None = not equippable) and what it grants.
//  New gear = one entry in each table; no code changes elsewhere.

@(rodata)
charm_slot_order := [3]Equip_Slot{.Charm, .Charm_2, .Charm_3}

is_charm_slot :: proc(slot: Equip_Slot) -> bool {
    for charm_slot in charm_slot_order do if slot == charm_slot do return true
    return false
}

player_has_charm :: proc(p: ^Player, charm: Item) -> bool {
    for slot in charm_slot_order do if p.equipment[slot] == charm do return true
    return false
}

@(rodata)
item_stat_bonus := #partial [Item][Stat]i32{
    .Sword        = #partial {.Attack = SWORD_DAMAGE},
    .Silver_Sword = #partial {.Attack = 3},
    .Gold_Sword   = #partial {.Attack = 5},
    .Aether_Charm = #partial {.Speed = 3},
    // Helm/Greaves grow the health pool, the chestplate blunts blows,
    // gauntlets add swing weight, boots add stride.
    .Iron_Helm       = #partial {.Max_HP = 1},
    .Silver_Helm     = #partial {.Max_HP = 2},
    .Gold_Helm       = #partial {.Max_HP = 4},
    .Iron_Chestplate   = #partial {.Defense = 1},
    .Silver_Chestplate = #partial {.Defense = 2},
    .Gold_Chestplate   = #partial {.Defense = 3},
    .Iron_Gauntlets   = #partial {.Attack = 1},
    .Silver_Gauntlets = #partial {.Attack = 1},
    .Gold_Gauntlets   = #partial {.Attack = 2},
    .Iron_Greaves   = #partial {.Max_HP = 1},
    .Silver_Greaves = #partial {.Max_HP = 2},
    .Gold_Greaves   = #partial {.Max_HP = 3},
    .Iron_Boots   = #partial {.Speed = 1},
    .Silver_Boots = #partial {.Speed = 2},
    .Gold_Boots   = #partial {.Speed = 3},
    // Runic: the endgame rung above gold.
    .Runic_Sword      = #partial {.Attack = 8},
    .Runic_Helm       = #partial {.Max_HP = 6},
    .Runic_Chestplate = #partial {.Defense = 5},
    .Runic_Gauntlets  = #partial {.Attack = 3},
    .Runic_Greaves    = #partial {.Max_HP = 5},
    .Runic_Boots      = #partial {.Speed = 4},
}

// Display name for each stat's bonus line in the crafting detail panel.
@(rodata)
stat_label := [Stat]string{
    .Attack  = "Attack",
    .Defense = "Defense",
    .Max_HP  = "Max HP",
    .Speed   = "Speed",
}

// Only actual weapons may drive melee. This also keeps utility gear from
// swinging merely because armor contributes Attack to the total damage stat.
is_melee_weapon :: proc(it: Item) -> bool {
    return item_equip_slot[it] == .Weapon && item_stat_bonus[it][.Attack] > 0
}

@(rodata)
player_base_stats := [Stat]i32{
    .Attack  = 0,   // bare hands swing nothing — a weapon must be equipped
    .Defense = 0,
    .Max_HP  = 10,
    .Speed   = i32(MOVE_SPEED),   // base stride; boots add on top
}

// Total for one stat: base + every equipped item's bonus, plus the held
// hand-gear's own (a sword swings from the hand, not a slot). Worn stats
// still require wearing: a helm carried in the hand grants nothing.
player_stat :: proc(p: ^Player, stat: Stat) -> i32 {
    total := player_base_stats[stat]
    for slot in Equip_Slot {
        if slot == .None do continue
        if it := p.equipment[slot]; it != .None {
            total += item_stat_bonus[it][stat]
        }
    }
    if it := held_item(p); it != .None {
        if eq := item_equip_slot[it]; eq == .Weapon || eq == .Tool {
            total += item_stat_bonus[it][stat]
        }
    }
    return total
}

// Max HP follows the stat; current hp is clamped, never raised for free.
player_apply_max_hp :: proc(p: ^Player) {
    p.hp_max = int(player_stat(p, .Max_HP))
    p.hp     = min(p.hp, p.hp_max)
}

// Equip from an inventory slot: the item leaves the bag; whatever held the
// equip slot returns to it.  No-op for non-equippable or empty slots, and
// refused (nothing lost) when the displaced gear can't fit back in the bag.
player_equip :: proc(gs: ^Game_State, inv_slot: int) {
    p := &gs.player
    if inv_slot < 0 || inv_slot >= MAX_INVENTORY do return
    s := &p.inventory.slots[inv_slot]
    eq := item_equip_slot[s.item]
    if eq == .None || s.count <= 0 do return

    // Hand gear isn't worn anymore: wielding it IS selecting its slot, same
    // as the number keys. It stays in the bag.
    if eq == .Weapon || eq == .Tool {
        p.inventory.selected = inv_slot
        log_action(gs, "Player wields %s", item_table[s.item].name)
        return
    }

    item := s.item
    if eq == .Charm {
        if player_has_charm(p, item) {
            notify(gs, "That charm is already on the belt")
            return
        }
        eq = .None
        for slot in charm_slot_order {
            if p.equipment[slot] == .None {
                eq = slot
                break
            }
        }
        if eq == .None {
            notify(gs, "All three charm slots are full")
            return
        }
    }

    prev := p.equipment[eq]
    s.count -= 1
    if s.count == 0 do s.item = .None
    if prev != .None && !inventory_insert(&p.inventory, prev, 1) {
        s.item   = item   // no room for the displaced gear: undo the take
        s.count += 1
        return
    }
    p.equipment[eq] = item
    player_apply_max_hp(p)
    gs.save_dirty = true
    log_action(gs, "Player equips %s", item_table[item].name)
}

POTION_HEAL :: 5   // hp restored by one Health Potion

// Flower farming: a harvested flower yields this many seeds; a planted bed
// grows this many flowers, each harvested for its own seeds.
FLOWER_SEED_MIN   :: 2
FLOWER_SEED_MAX   :: 5
FLOWER_BED_BLOOMS :: 5

// A consumable is used (drunk or eaten) from the bag rather than equipped.
item_is_consumable :: proc(it: Item) -> bool {
    return it == .Potion_Health || it == .GreenBerrie
}

// A readable opens the tome overlay from the bag instead of equipping.  It is
// never spent — a reference you keep.
item_is_readable :: proc(it: Item) -> bool {
    return it == .Scroll_Of_Waters
}

// Open the tome on the page this scroll carries.  The sim freezes while it is
// up (game_update) and E/ESC/click closes it (input.odin), exactly as the
// ritual's tome does.
player_read :: proc(gs: ^Game_State, inv_slot: int) {
    if inv_slot < 0 || inv_slot >= MAX_INVENTORY do return
    if !item_is_readable(gs.player.inventory.slots[inv_slot].item) do return
    gs.ui.show_book       = true
    gs.ui.book_page       = .Waters
    gs.ui.book_open_frame = gs.frame
    audio_play(&gs.audio, .Pickup)
}

// Use a consumable from a bag slot.  A Health Potion restores POTION_HEAL,
// never past the cap, refused (nothing spent) at full health; a GreenBerrie
// grants the leaf-fall buff (player.odin), re-eating just restarts the clock.
player_consume :: proc(gs: ^Game_State, inv_slot: int) {
    p := &gs.player
    if inv_slot < 0 || inv_slot >= MAX_INVENTORY do return
    s := &p.inventory.slots[inv_slot]
    if s.count <= 0 do return

    #partial switch s.item {
    case .Potion_Health:
        if p.hp >= p.hp_max {
            notify(gs, "Already at full health")
            return
        }
        heal := min(POTION_HEAL, p.hp_max - p.hp)
        p.hp += heal
        spawn_damage_number(&gs.floating_text, {p.pos.x + PLAYER_W*0.5, p.pos.y}, heal, HEAL_COLOR)
        log_action(gs, "Player drinks a Health Potion (+%d hp)", heal)
    case .GreenBerrie:
        gs.leaf_fall_t = LEAF_FALL_TIME
        notify(gs, "You feel light as a falling leaf")
        log_action(gs, "Player eats a GreenBerrie (leaf fall %.0fs)", LEAF_FALL_TIME)
    case:
        return
    }

    s.count -= 1
    if s.count == 0 do s.item = .None
    audio_play(&gs.audio, .Pickup)
    gs.save_dirty = true
}

// Worn, not spent: while a Jade Ring sits in any charm slot, the bag's
// "Return to Surface" button is live.
jade_ring_active :: proc(p: ^Player) -> bool {
    return player_has_charm(p, .Jade_Ring)
}

// The Jade Ring's effect: an early, cheap recall straight to the surface
// spawn, usable as often as it's worn.  Refused when the ring isn't equipped,
// when already home, or (matching the dimension gate's own rule) when
// leaving an unanchored dimension would strand a deployed golem crew.
player_warp_home :: proc(gs: ^Game_State) -> bool {
    if !jade_ring_active(&gs.player) do return false
    if gs.level_index == LEVEL_SURFACE {
        notify(gs, "Already on the surface")
        return false
    }
    if gs.level_index == LEVEL_DIMENSION && golem_deployed_count(gs, LEVEL_DIMENSION) > 0 && !dimension_world_anchored(gs) {
        notify(gs, "Recall the clay crew or build a World Anchor before leaving")
        return false
    }
    p := Portal{dest_level = LEVEL_SURFACE, dest_pos = SURFACE_HOME_POS, gate_tier = -1}
    level_transition(gs, &p)
    audio_play(&gs.audio, .Pickup)
    log_action(gs, "Player uses the Jade Ring, warps to the surface")
    return true
}

// Unequip back into the bag; refused when the bag can't hold the item.
player_unequip :: proc(gs: ^Game_State, slot: Equip_Slot) {
    p := &gs.player
    it := p.equipment[slot]
    if it == .None do return
    if !inventory_insert(&p.inventory, it, 1) do return

    p.equipment[slot] = .None
    player_apply_max_hp(p)
    gs.save_dirty = true
    log_action(gs, "Player unequips %s", item_table[it].name)
}

// ─── Inventory Operations ─────────────────────────────────────────────────────

// Insert items, stacking onto existing slots first.  Returns false if the
// inventory could not hold everything (whatever fit stays inserted).
inventory_insert :: proc(inv: ^Inventory, item: Item, count: int = 1) -> bool {
    left := count
    for &s in inv.slots {
        if left == 0 do break
        if s.item == item && s.count > 0 && s.count < MAX_STACK {
            take := min(MAX_STACK - s.count, left)
            s.count += take
            left    -= take
        }
    }
    for &s in inv.slots {
        if left == 0 do break
        if s.item == .None || s.count == 0 {
            take := min(MAX_STACK, left)
            s.item  = item
            s.count = take
            left   -= take
        }
    }
    return left == 0
}

inventory_count :: proc(inv: ^Inventory, item: Item) -> int {
    total := 0
    for s in inv.slots {
        if s.item == item do total += s.count
    }
    return total
}

inventory_remove :: proc(inv: ^Inventory, item: Item, count: int) -> bool {
    if inventory_count(inv, item) < count do return false
    left := count
    for &s in inv.slots {
        if s.item != item do continue
        take := min(s.count, left)
        s.count -= take
        left    -= take
        if s.count == 0 do s.item = .None
        if left == 0 do break
    }
    return true
}

// Split a bag stack into the first empty slot. The source keeps the smaller
// half when the count is odd; a full bag refuses without changing anything.
// Called through Inventory_Split so input never mutates inventory data.
inventory_split_stack :: proc(gs: ^Game_State, source: int) -> bool {
    if source < 0 || source >= MAX_INVENTORY do return false
    inv := &gs.player.inventory
    src := &inv.slots[source]
    if src.item == .None || src.count <= 1 do return false

    dest := -1
    for s, i in inv.slots {
        if i != source && (s.item == .None || s.count == 0) {
            dest = i
            break
        }
    }
    if dest < 0 {
        notify(gs, "No empty slot to split the stack")
        return false
    }

    moved := (src.count + 1) / 2
    inv.slots[dest] = {item = src.item, count = moved}
    src.count -= moved
    gs.save_dirty = true
    return true
}

// Resolve a bag-to-bag drag. Matching stacks consolidate up to MAX_STACK,
// empty targets receive the stack, and unlike items swap places. Selection
// follows a stack that leaves its old slot.
inventory_move_stack :: proc(gs: ^Game_State, source, target: int) -> bool {
    if source < 0 || source >= MAX_INVENTORY ||
       target < 0 || target >= MAX_INVENTORY || source == target {
        return false
    }

    inv := &gs.player.inventory
    src := &inv.slots[source]
    dst := &inv.slots[target]
    if src.item == .None || src.count <= 0 do return false

    if dst.item == .None || dst.count <= 0 {
        dst^ = src^
        src^ = {}
        if inv.selected == source do inv.selected = target
    } else if dst.item == src.item {
        moved := min(src.count, MAX_STACK - dst.count)
        if moved <= 0 do return false
        dst.count += moved
        src.count -= moved
        if src.count == 0 {
            src.item = .None
            if inv.selected == source do inv.selected = target
        }
    } else {
        src^, dst^ = dst^, src^
        if inv.selected == source {
            inv.selected = target
        } else if inv.selected == target {
            inv.selected = source
        }
    }

    gs.save_dirty = true
    return true
}

void_charm_active :: proc(p: ^Player) -> bool {
    return player_has_charm(p, .Void_Charm)
}

// Move a whole bag stack into the charm's recoverable buffer. The previous
// buffer is the only destructive part: replacing it erases it permanently.
void_slot_store :: proc(gs: ^Game_State, source: int) -> bool {
    p := &gs.player
    if !void_charm_active(p) || source < 0 || source >= MAX_INVENTORY do return false
    src := &p.inventory.slots[source]
    if src.item == .None || src.count <= 0 do return false

    old := p.void_slot
    p.void_slot = src^
    src^ = {}
    if p.inventory.selected == source do p.inventory.selected = -1
    gs.save_dirty = true

    if old.item != .None && old.count > 0 {
        notify(gs, "%s x%d vanishes into the void", item_table[old.item].name, old.count)
        log_action(gs, "Void Charm erases %s x%d", item_table[old.item].name, old.count)
    }
    return true
}

// Recover the buffered stack into the exact bag slot it was dragged onto.
// Refuse rather than partially moving: the undo stack always stays intact.
void_slot_take :: proc(gs: ^Game_State, target: int) -> bool {
    p := &gs.player
    if !void_charm_active(p) || target < 0 || target >= MAX_INVENTORY do return false
    src := &p.void_slot
    if src.item == .None || src.count <= 0 do return false
    dst := &p.inventory.slots[target]

    if dst.item == .None || dst.count <= 0 {
        dst^ = src^
    } else if dst.item == src.item && dst.count + src.count <= MAX_STACK {
        dst.count += src.count
    } else {
        notify(gs, "That bag slot cannot hold the void stack")
        return false
    }

    src^ = {}
    gs.save_dirty = true
    return true
}
