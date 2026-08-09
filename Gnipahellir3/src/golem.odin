package game

import "core:math"

// ─── Clay Golems ─────────────────────────────────────────────────────────────
// Friendly one-block workers.  The command wand owns a fixed fifteen-slot
// roster; deployed records are tagged by level, so inactive worlds freeze with
// the rest of the level store. Workers visibly expose the front item from a
// small internal pack; every mined and navigation-placed block remains real.

GOLEM_W       :: f32(0.55)
GOLEM_H       :: f32(0.72)
GOLEM_SPEED   :: f32(5.0)
GOLEM_JUMP    :: f32(-11.5)
GOLEM_HP      :: u8(3)
GOLEM_MINE_TIME :: f32(0.42)
GOLEM_REACH   :: i32(1)
GOLEM_BUILD_REACH :: i32(5)
GOLEM_TRANSFER_REACH :: i32(3)
GOLEM_ZONE_MAX_W :: i32(32)
GOLEM_ZONE_MAX_H :: i32(24)
GOLEM_STOCKPILE_MARGIN :: i32(4)
GOLEM_STUCK_TIME :: f32(3.0)
GOLEM_NAV_CLEANUP_PENALTY :: i32(512)
GOLEM_PLAYER_CLEANUP_PENALTY :: i32(768)
GOLEM_BLOCK_GRACE_TIME :: f32(3.0)
GOLEM_QUICK_CLAY_LINGER :: i32(2) // chebyshev tiles a worker may stray before its old foothold dissolves

Golem_Build_Cell :: struct {
	off:  [2]i32,
	tile: Tile_Type,
	item: Item,
}

// Ordered bottom-up; capstones are last so a monument visibly closes only
// after its ordinary masonry has arrived.
// (Not @(rodata): slice initializers aren't compile-time constants — same
// documented exception as enemy.odin's build_templates; the array contents
// are still read-only in practice.)
HEARTH_CELLS := [?]Golem_Build_Cell{
	{{-2, 0}, .Stone, .Stone_Block}, {{-1, 0}, .Stone, .Stone_Block},
	{{ 1, 0}, .Stone, .Stone_Block}, {{ 2, 0}, .Stone, .Stone_Block},
	{{-2,-1}, .Clay,  .Clay},        {{ 2,-1}, .Clay,  .Clay},
	{{-2,-2}, .Wood,  .Plank},       {{-1,-2}, .Wood,  .Plank},
	{{ 0,-2}, .Clay,  .Clay},        {{ 1,-2}, .Wood,  .Plank},
	{{ 2,-2}, .Wood,  .Plank},
	{{ 0, 0}, .Clay_Hearth, .Iron_Bar},
}

DEPOT_CELLS := [?]Golem_Build_Cell{
	{{-3, 0}, .Stone, .Stone_Block}, {{-2, 0}, .Stone, .Stone_Block},
	{{-1, 0}, .Stone, .Stone_Block}, {{ 1, 0}, .Stone, .Stone_Block},
	{{ 2, 0}, .Stone, .Stone_Block}, {{ 3, 0}, .Stone, .Stone_Block},
	{{-3,-1}, .Wood, .Plank},        {{ 3,-1}, .Wood, .Plank},
	{{-3,-2}, .Wood, .Plank},        {{ 3,-2}, .Wood, .Plank},
	{{-3,-3}, .Stone, .Stone_Block}, {{-2,-3}, .Wood, .Plank},
	{{-1,-3}, .Wood, .Plank},        {{ 0,-3}, .Clay, .Clay},
	{{ 1,-3}, .Wood, .Plank},        {{ 2,-3}, .Wood, .Plank},
	{{ 3,-3}, .Stone, .Stone_Block},
	{{-1,-1}, .Clay, .Clay},         {{ 1,-1}, .Clay, .Clay},
	{{ 0, 0}, .Golem_Depot, .Emerald},
}

ANCHOR_CELLS := [?]Golem_Build_Cell{
	{{-2, 0}, .Stone, .Stone_Block}, {{-1, 0}, .Gold_Ore, .Gold_Bar},
	{{ 1, 0}, .Gold_Ore, .Gold_Bar}, {{ 2, 0}, .Stone, .Stone_Block},
	{{-2,-1}, .Stone, .Stone_Block}, {{ 2,-1}, .Stone, .Stone_Block},
	{{-2,-2}, .Gold_Ore, .Gold_Bar}, {{ 2,-2}, .Gold_Ore, .Gold_Bar},
	{{-1,-3}, .Cloud, .Cloud_Stone}, {{ 0,-3}, .Clay, .Clay},
	{{ 1,-3}, .Cloud, .Cloud_Stone},
	{{ 0,-2}, .World_Anchor, .Cloud_Stone},
}

Golem_Plan_Info :: struct {
	name:  string,
	cells: []Golem_Build_Cell,
}

golem_plan_table := #partial [Golem_Plan]Golem_Plan_Info{
	.Clay_Hearth  = {"Clay Hearth", HEARTH_CELLS[:]},
	.Golem_Depot  = {"Golem Depot", DEPOT_CELLS[:]},
	.World_Anchor = {"World Anchor", ANCHOR_CELLS[:]},
}

is_command_wand :: proc(it: Item) -> bool {
	return it == .Command_Wand || it == .Command_Wand_Emerald || it == .Command_Wand_Hel
}

command_wand_capacity :: proc(it: Item) -> int {
	#partial switch it {
	case .Command_Wand:         return 1
	case .Command_Wand_Emerald: return 5
	case .Command_Wand_Hel:     return 15
	case:                       return 0
	}
}

equipped_command_wand :: proc(gs: ^Game_State) -> Item {
	it := gs.player.equipment[.Weapon]
	return it if is_command_wand(it) else .None
}

player_has_command_wand :: proc(gs: ^Game_State) -> bool {
	if is_command_wand(gs.player.equipment[.Weapon]) do return true
	for s in gs.player.inventory.slots do if is_command_wand(s.item) && s.count > 0 do return true
	return false
}

golem_loaded_count :: proc(gs: ^Game_State) -> (n: int) {
	for g in gs.golems.data do if g.status != .Empty do n += 1
	return
}

golem_pack_count :: proc(g: ^Golem) -> (n: int) {
	for item in g.pack do if item != .None do n += 1
	return
}

golem_pack_has_room :: proc(g: ^Golem) -> bool {
	return golem_pack_count(g) < GOLEM_PACK_CAP
}

golem_pack_add :: proc(g: ^Golem, item: Item) -> bool {
	if item == .None do return true
	for &slot in g.pack do if slot == .None {slot = item; return true}
	return false
}

golem_pack_take :: proc(g: ^Golem, item: Item) -> bool {
	for &slot in g.pack do if slot == item {slot = .None; return true}
	return false
}

golem_pack_has :: proc(g: ^Golem, item: Item) -> bool {
	for slot in g.pack do if slot == item do return true
	return false
}

golem_pack_pop :: proc(g: ^Golem) -> Item {
	for &slot in g.pack do if slot != .None {item:=slot; slot=.None; return item}
	return .None
}

golem_pack_peek :: proc(g: ^Golem) -> Item {
	for slot in g.pack do if slot != .None do return slot
	return .None
}

golem_deployed_count :: proc(gs: ^Game_State, level: int) -> (n: int) {
	for g in gs.golems.data do if (g.status == .Deployed || g.status == .Broken) && g.level == level do n += 1
	return
}

golem_tile :: proc(g: ^Golem) -> [2]i32 {
	return {i32(g.pos.x + GOLEM_W*0.5), i32(g.pos.y + GOLEM_H*0.5)}
}

golem_center :: proc(g:^Golem) -> [2]f32 {
	return {g.pos.x+GOLEM_W*0.5,g.pos.y+GOLEM_H*0.5}
}

tile_center :: proc(T:[2]i32) -> [2]f32 {
	return {f32(T.x)+0.5,f32(T.y)+0.5}
}

golem_overlaps_cell :: proc(g:^Golem, x,y:int) -> bool {
	return g.pos.x<f32(x+1) && g.pos.x+GOLEM_W>f32(x) &&
	       g.pos.y<f32(y+1) && g.pos.y+GOLEM_H>f32(y)
}

golem_body_clear :: proc(w:^World_Grid, pos:[2]f32) -> bool {
	min_x:=int(math.floor(pos.x+0.001))
	max_x:=int(math.floor(pos.x+GOLEM_W-0.001))
	min_y:=int(math.floor(pos.y+0.001))
	max_y:=int(math.floor(pos.y+GOLEM_H-0.001))
	for y in min_y..=max_y do for x in min_x..=max_x {
		if is_solid(w,x,y) do return false
	}
	return true
}

// Settling sand-style blocks can surround a body between physics ticks. Move
// an embedded worker to the nearest centered open cell, preferring real floor,
// and preserve its cargo/objective so the ordinary route can resume.
golem_unembed :: proc(gs:^Game_State, g:^Golem) -> bool {
	if golem_body_clear(&gs.world,g.pos) do return false
	origin:=golem_tile(g)
	for grounded_pass in 0..=1 do for r in i32(0)..=i32(8) do for dy in -r..=r do for dx in -r..=r {
		if max(abs(dx),abs(dy))!=r do continue
		x,y:=int(origin.x+dx),int(origin.y+dy)
		if !in_bounds(x,y) do continue
		candidate:=[2]f32{f32(x)+(1-GOLEM_W)*0.5,f32(y+1)-GOLEM_H}
		if !golem_body_clear(&gs.world,candidate) do continue
		supported:=in_bounds(x,y+1) && is_solid(&gs.world,x,y+1)
		if grounded_pass==0 && !supported do continue
		g.pos=candidate
		g.vel={}
		g.grounded=supported
		g.path={}
		g.replan_timer=0
		bt:=golem_tile(g)
		if g.has_target && g.target.y<bt.y-golem_job_reach(g) {
			g.recovering=true
			g.recover_from=bt.y
		}
		gs.save_dirty=true
		spawn_chip_sparks(gs,origin)
		return true
	}
	return false
}

golem_at_tile :: proc(gs: ^Game_State, tile: [2]i32) -> int {
	for &g, i in gs.golems.data {
		if (g.status == .Deployed || g.status == .Broken) && g.level == gs.level_index &&
		   chebyshev(golem_tile(&g), tile) <= 0 {
			return i
		}
	}
	return -1
}

golem_at_world_point :: proc(gs:^Game_State, world_pixel:[2]f32) -> int {
	p:=[2]f32{world_pixel.x/CELL_SIZE,world_pixel.y/CELL_SIZE}
	best,best_dist:=-1,max(f32)
	for &g,i in gs.golems.data {
		if g.status!=.Deployed || g.level!=gs.level_index do continue
		// Match the deliberately oversized rendered sprite and add a small halo
		// so a moving half-tile worker is comfortable to select.
		if p.x<g.pos.x-.3 || p.x>g.pos.x+GOLEM_W+.4 ||
		   p.y<g.pos.y-.35 || p.y>g.pos.y+GOLEM_H+.35 {continue}
		c:=golem_center(&g)
		dx,dy:=p.x-c.x,p.y-c.y
		d:=dx*dx+dy*dy
		if d<best_dist {best,best_dist=i,d}
	}
	return best
}

nearest_deployed_golem :: proc(gs: ^Game_State, from: [2]i32) -> (tile: [2]i32, id: int, ok: bool) {
	best := max(i32)
	id = -1
	for &g, i in gs.golems.data {
		if g.status != .Deployed || g.level != gs.level_index do continue
		T := golem_tile(&g)
		d := chebyshev(from,T)
		if d < best {best=d; tile=T; id=i; ok=true}
	}
	return
}

golem_damage :: proc(gs: ^Game_State, id, damage: int) {
	if id<0 || id>=MAX_GOLEMS || damage<=0 do return
	g:=&gs.golems.data[id]
	if g.status != .Deployed || g.level != gs.level_index do return
	g.hp = u8(max(0,int(g.hp)-damage))
	if g.hp==0 {
		golem_release_reservation(gs,id)
		if g.carry!=.None do spawn_ground_item(&gs.world,golem_tile(g),g.carry,1)
		for item in g.pack do if item!=.None do spawn_ground_item(&gs.world,golem_tile(g),item,1)
		g.status=.Broken; g.vel={}; g.carry=.None; g.pack={}; g.recovering=false
		golem_reset_job(g)
		notify(gs,"A clay golem cracks apart - recall it for repair")
	}
	gs.save_dirty=true
}

golem_reset_job :: proc(g: ^Golem) {
	g.job = .Idle
	g.target = {}
	g.has_target = false
	g.path = {}
	g.replan_timer = 0
}

golem_release_reservation :: proc(gs: ^Game_State, id: int) {
	g := &gs.golems.data[id]
	if g.project_cell >= 0 && g.level >= 0 && g.level < NUM_LEVELS {
		p := &gs.golems.projects[g.level]
		ci := int(g.project_cell)
		if ci < GOLEM_PROJECT_CELLS && p.reserved[ci] == u8(id+1) do p.reserved[ci] = 0
	}
	g.project_cell = -1
}

golem_load :: proc(gs: ^Game_State, bag_slot: int) -> bool {
	if !player_has_command_wand(gs) {
		notify(gs, "Craft and keep a Command Wand before waking a golem")
		return false
	}
	if bag_slot < 0 || bag_slot >= MAX_INVENTORY do return false
	s := &gs.player.inventory.slots[bag_slot]
	if s.item != .Clay_Golem || s.count <= 0 do return false

	capacity := 0
	if w := equipped_command_wand(gs); w != .None {
		capacity = command_wand_capacity(w)
	} else {
		for slot in gs.player.inventory.slots do capacity = max(capacity, command_wand_capacity(slot.item))
	}
	if golem_loaded_count(gs) >= capacity {
		notify(gs, "The wand has no empty golem slots (%d/%d)", golem_loaded_count(gs), capacity)
		return false
	}
	for &g in gs.golems.data {
		if g.status != .Empty do continue
		g = {status = .Carried, hp = GOLEM_HP, mode = .Gather, facing = 1, project_cell = -1}
		s.count -= 1
		if s.count == 0 do s.item = .None
		gs.save_dirty = true
		audio_play(&gs.audio, .Place)
		notify(gs, "A clay golem curls into wand slot %d/%d", golem_loaded_count(gs), capacity)
		return true
	}
	return false
}

golem_deploy :: proc(gs: ^Game_State, tile: [2]i32) -> bool {
	if equipped_command_wand(gs) == .None do return false
	if chebyshev(tile, player_tile(&gs.player)) > PLAYER_REACH do return false
	x, y := int(tile.x), int(tile.y)
	if !in_bounds(x, y) || is_solid(&gs.world, x, y) || !is_solid(&gs.world, x, y+1) {
		notify(gs, "The golem needs an open cell with ground beneath it")
		return false
	}
	for &g in gs.golems.data {
		if g.status != .Carried do continue
		g.status = .Deployed
		g.level  = gs.level_index
		g.pos    = {f32(x) + (1-GOLEM_W)*0.5, f32(y+1)-GOLEM_H}
		g.vel    = {}
		g.job    = .Idle
		g.has_target = false
		g.path   = {}
		g.project_cell = -1
		gs.save_dirty = true
		audio_play(&gs.audio, .Place)
		if g.mode == .Gather && !gs.golems.work[gs.level_index].active {
			notify(gs, "Golem awaits orders - hold LEFT MOUSE and drag a Gather zone")
		} else if g.mode == .Build && !gs.golems.projects[gs.level_index].active {
			notify(gs, "Golem awaits orders - choose a monument plan, then mark its anchor")
		}
		return true
	}
	notify(gs, "No carried golem is ready")
	return false
}

debug_golem_deploy :: proc(gs:^Game_State, tile:[2]i32) -> bool {
	x,y:=int(tile.x),int(tile.y)
	if !in_bounds(x,y) || !in_bounds(x,y+1) || is_solid(&gs.world,x,y) || !is_solid(&gs.world,x,y+1) {
		notify(gs,"Debug: the golem needs an open cell with ground beneath it")
		return false
	}
	for &g in gs.golems.data do if g.status==.Empty {
		g={status=.Deployed,hp=GOLEM_HP,mode=.Gather,facing=1,level=gs.level_index,
			pos={f32(x)+(1-GOLEM_W)*.5,f32(y+1)-GOLEM_H},grounded=true,project_cell=-1}
		gs.save_dirty=true
		notify(gs,"Debug: Clay Golem deployed - use the Command Wand to give orders")
		return true
	}
	notify(gs,"Debug: all golem roster slots are occupied")
	return false
}

golem_toggle :: proc(gs: ^Game_State, id: int) {
	if id < 0 || id >= MAX_GOLEMS do return
	g := &gs.golems.data[id]
	if g.status != .Deployed || g.level != gs.level_index do return
	golem_release_reservation(gs, id)
	g.mode = .Build if g.mode == .Gather else .Gather
	golem_reset_job(g)
	gs.save_dirty = true
	if g.mode==.Build && !gs.golems.projects[gs.level_index].active {
		notify(gs,"Golem %d: BUILD - choose a monument plan, then mark its anchor",id+1)
	} else {
		notify(gs, "Golem %d: %s", id+1, "BUILD" if g.mode == .Build else "GATHER")
	}
}

golem_recall :: proc(gs: ^Game_State, id: int) {
	if id < 0 || id >= MAX_GOLEMS do return
	g := &gs.golems.data[id]
	if (g.status != .Deployed && g.status != .Broken) || g.level != gs.level_index do return
	if chebyshev(golem_tile(g), player_tile(&gs.player)) > PLAYER_REACH {
		notify(gs, "Move closer to recall that golem")
		return
	}
	golem_release_reservation(gs, id)
	if g.carry != .None {
		if !inventory_insert(&gs.player.inventory, g.carry, 1) {
			spawn_ground_item(&gs.world, golem_tile(g), g.carry, 1)
		}
	}
	for &item in g.pack {
		if item == .None do continue
		if !inventory_insert(&gs.player.inventory, item, 1) do spawn_ground_item(&gs.world, golem_tile(g), item, 1)
		item = .None
	}
	broken := g.status == .Broken
	g.status = .Carried
	g.level = 0
	g.pos, g.vel = {}, {}
	g.carry = .None
	g.recovering = false
	golem_reset_job(g)
	gs.save_dirty = true
	if broken do notify(gs, "The cracked golem returns to the wand - repair it at a Clay Hearth")
}

golem_crew_toggle :: proc(gs: ^Game_State) {
	to_build := false
	for g in gs.golems.data do if g.status == .Deployed && g.level == gs.level_index && g.mode == .Gather {
		to_build = true
		break
	}
	for &g, i in gs.golems.data {
		if g.status != .Deployed || g.level != gs.level_index do continue
		golem_release_reservation(gs, i)
		g.mode = .Build if to_build else .Gather
		golem_reset_job(&g)
	}
	gs.save_dirty = true
	if to_build && !gs.golems.projects[gs.level_index].active {
		notify(gs,"Crew: BUILD - choose a monument plan, then mark its anchor")
	} else {
		notify(gs, "Crew: %s", "BUILD" if to_build else "GATHER")
	}
}

golem_set_zone :: proc(gs: ^Game_State, a, b: [2]i32) {
	lo := [2]i32{min(a.x, b.x), min(a.y, b.y)}
	hi := [2]i32{max(a.x, b.x), max(a.y, b.y)}
	hi.x = min(hi.x, lo.x + GOLEM_ZONE_MAX_W - 1)
	hi.y = min(hi.y, lo.y + GOLEM_ZONE_MAX_H - 1)
	lo.x = clamp(lo.x, 0, GRID_W-1); hi.x = clamp(hi.x, 0, GRID_W-1)
	lo.y = clamp(lo.y, 0, GRID_H-1); hi.y = clamp(hi.y, 0, GRID_H-1)
	gs.golems.work[gs.level_index] = {active = true, min = lo, max = hi}
	for &g in gs.golems.data do if g.status == .Deployed && g.level == gs.level_index && g.mode == .Gather {
		golem_reset_job(&g)
	}
	gs.save_dirty = true
	notify(gs, "Gather zone marked: %dx%d", hi.x-lo.x+1, hi.y-lo.y+1)
}

golem_plan_unlocked :: proc(gs: ^Game_State, plan: Golem_Plan) -> bool {
	cap := command_wand_capacity(equipped_command_wand(gs))
	#partial switch plan {
	case .Clay_Hearth:  return cap >= 1
	case .Golem_Depot:  return cap >= 5
	case .World_Anchor: return cap >= 5 && gs.level_index == LEVEL_DIMENSION
	case:               return false
	}
}

golem_project_start :: proc(gs: ^Game_State, plan: Golem_Plan, anchor: [2]i32) -> bool {
	if !golem_plan_unlocked(gs, plan) do return false
	if chebyshev(anchor, player_tile(&gs.player)) > PLAYER_REACH {
		notify(gs, "That monument anchor is beyond the wand's reach")
		return false
	}
	p := &gs.golems.projects[gs.level_index]
	if p.active && !p.complete {
		notify(gs, "Finish the current monument before marking another")
		return false
	}
	info := &golem_plan_table[plan]
	if len(info.cells) == 0 do return false
	for c in info.cells {
		x, y := int(anchor.x+c.off.x), int(anchor.y+c.off.y)
		if !in_bounds(x, y) { notify(gs, "That monument would cross the world's edge"); return false }
		t := get_tile(&gs.world, x, y)
		if t != .Air && t != .Void && t != c.tile {
			notify(gs, "The %s footprint is blocked", info.name)
			return false
		}
	}
	if !is_solid(&gs.world, int(anchor.x), int(anchor.y)+1) {
		notify(gs, "The monument needs solid ground beneath its anchor")
		return false
	}
	p^ = {active = true, plan = plan, level = gs.level_index, anchor = anchor}
	for &g, i in gs.golems.data do if g.status == .Deployed && g.level == gs.level_index && g.mode == .Build {
		golem_release_reservation(gs, i)
		golem_reset_job(&g)
	}
	gs.save_dirty = true
	notify(gs, "%s marked - BUILD golems await materials", info.name)
	return true
}

// ─── Depot storage and machine handoff ───────────────────────────────────────

golem_depot_at :: proc(gs: ^Game_State, level: int, tile: [2]i32) -> ^Golem_Depot_State {
	for &d in gs.golems.depots do if d.active && d.level == level && d.tile == tile do return &d
	return nil
}

golem_depot_add :: proc(d: ^Golem_Depot_State, item: Item, n: u32) -> bool {
	for &s in d.slots do if s.item == item { s.count += n; return true }
	for &s in d.slots do if s.item == .None || s.count == 0 { s = {item, n}; return true }
	return false
}

golem_depot_has_room :: proc(d: ^Golem_Depot_State, item: Item) -> bool {
	for s in d.slots do if s.item == item || s.item == .None || s.count == 0 do return true
	return false
}

golem_depot_take :: proc(d: ^Golem_Depot_State, item: Item) -> bool {
	for &s in d.slots {
		if s.item != item || s.count == 0 do continue
		s.count -= 1
		if s.count == 0 do s.item = .None
		return true
	}
	return false
}

golem_depot_withdraw :: proc(gs: ^Game_State, d: ^Golem_Depot_State) {
	taken := 0
	for &slot in d.slots {
		for slot.count > 0 {
			batch := int(min(slot.count, u32(MAX_STACK)))
			before := inventory_count(&gs.player.inventory, slot.item)
			inventory_insert(&gs.player.inventory, slot.item, batch)
			moved := inventory_count(&gs.player.inventory, slot.item)-before
			slot.count -= u32(moved); taken += moved
			if moved < batch {notify(gs,"The bag is full - cargo remains in the Depot"); return}
		}
		slot.item = .None
	}
	if taken > 0 {audio_play(&gs.audio,.Pickup); notify(gs,"The Depot pours %d items into the bag",taken)}
	else {notify(gs,"The Golem Depot is empty")}
}

golem_depot_on_built :: proc(gs: ^Game_State, tile: [2]i32) {
	if golem_depot_at(gs, gs.level_index, tile) != nil do return
	for &d in gs.golems.depots do if !d.active {
		d = {active = true, level = gs.level_index, tile = tile}
		return
	}
}

// Depot tick: one unit per adjacent furnace per frame is intentionally simple;
// furnace caps stop it, while visible golem trips remain the limiting input.
tick_golem_depot :: proc(gs: ^Game_State, x, y: int) {
	d := golem_depot_at(gs, gs.level_index, {i32(x), i32(y)})
	if d == nil do return
	for dir in ([4][2]int{{1,0},{-1,0},{0,1},{0,-1}}) {
		nx, ny := x+dir.x, y+dir.y
		if get_tile(&gs.world, nx, ny) != .Smelter do continue
		sd := &gs.world.sim_data[grid_idx(nx, ny)]
		if int(sd.fuel_count) < SMELTER_FUEL_CAP && golem_depot_take(d, .Wood_Log) {
			sd.fuel_count += 1
		}
		if int(sd.in_count) >= SMELTER_IN_CAP do continue
		for &slot in d.slots {
			if slot.count == 0 do continue
			if _, ok := smelt_rule_for(slot.item); !ok do continue
			if sd.in_item != .None && sd.in_item != slot.item do continue
			sd.in_item = slot.item
			sd.in_count += 1
			slot.count -= 1
			if slot.count == 0 do slot.item = .None
			break
		}
	}
}

golem_depot_adjacent :: proc(gs: ^Game_State, x, y: int) -> ^Golem_Depot_State {
	for dy in -1 ..= 1 do for dx in -1 ..= 1 {
		if dx == 0 && dy == 0 do continue
		if get_tile(&gs.world, x+dx, y+dy) == .Golem_Depot {
			if d := golem_depot_at(gs, gs.level_index, {i32(x+dx), i32(y+dy)}); d != nil do return d
		}
	}
	return nil
}

// ─── Work selection and transfers ────────────────────────────────────────────

golem_resource_priority :: proc(t: Tile_Type) -> int {
	#partial switch t {
	case .Gold_Rare_Ore: return 8
	case .Gold_Ore:      return 7
	case .Silver_Ore:    return 6
	case .Iron_Ore:      return 5
	case .Clay:          return 4
	case .Wood:          return 3
	case .Stone:         return 2
	case .Grass, .Dirt:  return 1
	case:                return 0
	}
}

golem_target_claimed :: proc(gs: ^Game_State, id: int, tile: [2]i32) -> bool {
	for &o, oi in gs.golems.data do if oi != id && o.status == .Deployed && o.level == gs.level_index &&
		o.has_target && o.target == tile && (o.job == .Mine || o.job == .Seek) {
		return true
	}
	return false
}

golem_register_block_grace_until :: proc(gs: ^Game_State, owner: int, tile: [2]i32, expires_at: f32) {
	// Reuse an existing cell record, an expired slot, or finally the record
	// closest to expiry. At the placement cadence the fixed pool covers every
	// block all fifteen workers can create during the three-second window.
	best := 0
	best_expiry := gs.golem_grace.blocks[0].expires_at
	for &entry, i in gs.golem_grace.blocks {
		if entry.level == gs.level_index && entry.tile == tile || entry.expires_at <= gs.elapsed_time {
			best = i
			break
		}
		if entry.expires_at < best_expiry {
			best = i
			best_expiry = entry.expires_at
		}
	}
	gs.golem_grace.blocks[best] = {
		tile = tile,
		level = gs.level_index,
		owner = i16(owner),
		expires_at = expires_at,
	}
}

golem_block_grace_details :: proc(gs: ^Game_State, tile: [2]i32) -> (owner: int, expires_at: f32, ok: bool) {
	for entry in gs.golem_grace.blocks {
		if entry.expires_at > gs.elapsed_time && entry.level == gs.level_index && entry.tile == tile {
			return int(entry.owner), entry.expires_at, true
		}
	}
	return -1, 0, false
}

golem_block_grace_protected :: proc(gs: ^Game_State, miner: int, tile: [2]i32) -> bool {
	owner, _, ok := golem_block_grace_details(gs,tile)
	return ok && owner != miner
}

golem_rebuild_mark_index :: proc(gs:^Game_State) {
	index:=&gs.golem_marks
	index^={valid=true,level=gs.level_index,min={GRID_W,GRID_H}}
	for y in 0..<GRID_H do for x in 0..<GRID_W {
		if .Golem_Marked not_in gs.world.tile_flags[grid_idx(x,y)] do continue
		T:=[2]i32{i32(x),i32(y)}
		if index.count==0 {
			index.min=T; index.max=T
		} else {
			index.min={min(index.min.x,T.x),min(index.min.y,T.y)}
			index.max={max(index.max.x,T.x),max(index.max.y,T.y)}
		}
		index.count+=1
	}
}

golem_ensure_mark_index :: proc(gs:^Game_State) {
	if !gs.golem_marks.valid || gs.golem_marks.level!=gs.level_index do golem_rebuild_mark_index(gs)
}

golem_remove_block_mark :: proc(gs:^Game_State,tile:[2]i32) {
	if !in_bounds(int(tile.x),int(tile.y)) do return
	idx:=grid_idx(int(tile.x),int(tile.y))
	if .Golem_Marked not_in gs.world.tile_flags[idx] do return
	golem_ensure_mark_index(gs)
	gs.world.tile_flags[idx]-={.Golem_Marked}
	gs.golem_marks.count=max(0,gs.golem_marks.count-1)
	if gs.golem_marks.count==0 {
		gs.golem_marks.min={}; gs.golem_marks.max={}
	}
}

golem_set_block_mark :: proc(gs:^Game_State,tile:[2]i32,marked:bool) -> bool {
	if !in_bounds(int(tile.x),int(tile.y)) do return false
	idx:=grid_idx(int(tile.x),int(tile.y))
	if !marked {
		if .Golem_Marked not_in gs.world.tile_flags[idx] do return false
		golem_remove_block_mark(gs,tile)
		for &g in gs.golems.data {
			if g.status==.Deployed && g.level==gs.level_index && g.job==.Mine &&
			   g.has_target && g.target==tile {
				golem_reset_job(&g)
			}
		}
		gs.save_dirty=true
		return true
	}
	t:=gs.world.terrain[idx]
	if .Golem_Marked in gs.world.tile_flags[idx] || .Mineable not_in terrain_table[t].flags ||
	   is_structure_tile[t] || den_protected(gs,int(tile.x),int(tile.y),-1) {
		return false
	}
	golem_ensure_mark_index(gs)
	gs.world.tile_flags[idx]+={.Golem_Marked}
	if gs.golem_marks.count==0 {
		gs.golem_marks.min=tile; gs.golem_marks.max=tile
	} else {
		gs.golem_marks.min={min(gs.golem_marks.min.x,tile.x),min(gs.golem_marks.min.y,tile.y)}
		gs.golem_marks.max={max(gs.golem_marks.max.x,tile.x),max(gs.golem_marks.max.y,tile.y)}
	}
	gs.golem_marks.count+=1
	gs.save_dirty=true
	return true
}

golem_resource_skipped :: proc(tile: [2]i32, skipped: [][2]i32) -> bool {
	for rejected in skipped do if rejected == tile do return true
	return false
}

golem_find_marked_resource :: proc(gs:^Game_State,id:int,skipped:[][2]i32) -> ([2]i32,bool) {
	golem_ensure_mark_index(gs)
	if gs.golem_marks.count<=0 do return {},false
	from:=golem_tile(&gs.golems.data[id])
	best,best_score,ok:=[2]i32{},max(i32),false
	for y in int(gs.golem_marks.min.y)..=int(gs.golem_marks.max.y) do for x in int(gs.golem_marks.min.x)..=int(gs.golem_marks.max.x) {
		idx:=grid_idx(x,y)
		if .Golem_Marked not_in gs.world.tile_flags[idx] do continue
		T:=[2]i32{i32(x),i32(y)}
		if golem_resource_skipped(T,skipped) || golem_target_claimed(gs,id,T) do continue
		t:=gs.world.terrain[idx]
		if .Mineable not_in terrain_table[t].flags || is_structure_tile[t] || den_protected(gs,x,y,-1) do continue
		if terrain_table[t].drop_item!=.None && !golem_pack_has_room(&gs.golems.data[id]) do continue
		score:=chebyshev(from,T)
		if score<best_score {best,best_score,ok=T,score,true}
	}
	return best,ok
}

golem_find_resource :: proc(gs: ^Game_State, id: int, skipped: [][2]i32) -> ([2]i32, bool) {
	if marked,found:=golem_find_marked_resource(gs,id,skipped); found do return marked,true
	w := gs.golems.work[gs.level_index]
	if !w.active do return {}, false
	from := golem_tile(&gs.golems.data[id])
	best, best_score, ok := [2]i32{}, max(i32), false
	for y in int(w.min.y) ..= int(w.max.y) do for x in int(w.min.x) ..= int(w.max.x) {
		idx := grid_idx(x, y)
		T := [2]i32{i32(x), i32(y)}
		if golem_resource_skipped(T, skipped) || golem_target_claimed(gs, id, T) do continue
		if gs.world.items[idx] != .None && gs.world.item_counts[idx] > 0 && !is_rune_scroll(gs.world.items[idx]) {
			if !golem_pack_has_room(&gs.golems.data[id]) do continue
			score := chebyshev(from, T) - 100
			if score < best_score {best, best_score, ok = T, score, true}
			continue
		}
		priority := golem_resource_priority(gs.world.terrain[idx])
		cleanup := .Golem_Placed in gs.world.tile_flags[idx]
		player_cleanup := .Placed in gs.world.tile_flags[idx] && !cleanup
		if priority == 0 do continue
		if cleanup && golem_block_grace_protected(gs, id, T) do continue
		if terrain_table[gs.world.terrain[idx]].drop_item != .None && !golem_pack_has_room(&gs.golems.data[id]) do continue
		if den_protected(gs, x, y, -1) do continue
		score := chebyshev(from, T) + i32((8-priority)*32)
		// Navigation masonry is real material and should not litter an exhausted
		// work order forever. A deliberately marked Gather rectangle also clears
		// ordinary player masonry last; structures remain protected below.
		if cleanup do score += GOLEM_NAV_CLEANUP_PENALTY
		if player_cleanup do score += GOLEM_PLAYER_CLEANUP_PENALTY
		if score < best_score {best, best_score, ok = T, score, true}
	}
	return best, ok
}

golem_storage_has_item :: proc(gs: ^Game_State, tile: [2]i32, item: Item) -> bool {
	if d := golem_depot_at(gs, gs.level_index, tile); d != nil {
		for s in d.slots do if s.item == item && s.count > 0 do return true
	}
	if b := barrel_at(gs, gs.level_index, tile); b != nil {
		for s in b.slots do if s.item == item && s.count > 0 do return true
	}
	if s := silo_at(gs, gs.level_index, tile); s != nil {
		for slot in s.slots do if slot.item == item && slot.count > 0 do return true
	}
	idx := grid_idx(int(tile.x), int(tile.y))
	return gs.world.items[idx] == item && gs.world.item_counts[idx] > 0
}

golem_find_item_source :: proc(gs: ^Game_State, from: [2]i32, item: Item) -> ([2]i32, bool) {
	best, dist, ok := [2]i32{}, max(i32), false
	for y in 0 ..< GRID_H do for x in 0 ..< GRID_W {
		T := [2]i32{i32(x), i32(y)}
		if !golem_storage_has_item(gs, T, item) do continue
		d := chebyshev(from, T)
		if d < dist {best, dist, ok = T, d, true}
	}
	return best, ok
}

golem_take_item_at :: proc(gs: ^Game_State, tile: [2]i32, item: Item) -> bool {
	idx := grid_idx(int(tile.x), int(tile.y))
	if gs.world.items[idx] == item && gs.world.item_counts[idx] > 0 {
		gs.world.item_counts[idx] -= 1
		if gs.world.item_counts[idx] == 0 do gs.world.items[idx] = .None
		return true
	}
	if d := golem_depot_at(gs, gs.level_index, tile); d != nil do return golem_depot_take(d, item)
	if b := barrel_at(gs, gs.level_index, tile); b != nil {
		for &s in b.slots do if s.item == item && s.count > 0 {
			s.count -= 1; if s.count == 0 do s.item = .None
			return true
		}
	}
	if s := silo_at(gs, gs.level_index, tile); s != nil {
		for &slot in s.slots do if slot.item == item && slot.count > 0 {
			slot.count -= 1; if slot.count == 0 do slot.item = .None
			return true
		}
	}
	return false
}

golem_smelter_accepts :: proc(sd: ^Sim_Tile_Data, item: Item) -> bool {
	if smelter_is_fuel(item) do return int(sd.fuel_count) < SMELTER_FUEL_CAP
	if _, ok := smelt_rule_for(item); ok {
		return int(sd.in_count) < SMELTER_IN_CAP && (sd.in_item == .None || sd.in_item == item)
	}
	return false
}

golem_deposit_possible :: proc(gs: ^Game_State, tile: [2]i32, item: Item) -> bool {
	t := get_tile(&gs.world, int(tile.x), int(tile.y))
	#partial switch t {
	case .Smelter:
		return golem_smelter_accepts(&gs.world.sim_data[grid_idx(int(tile.x), int(tile.y))], item)
	case .Golem_Depot:
		if d := golem_depot_at(gs, gs.level_index, tile); d != nil do return golem_depot_has_room(d, item)
	case .Barrel, .Sky_Rune_Scroll_Chest, .Rune_Scroll_Chest_A, .Rune_Scroll_Chest_B, .Rune_Scroll_Chest_C:
		if b := barrel_at(gs, gs.level_index, tile); b != nil {
			for s in b.slots do if s.item == item && s.count < MAX_STACK || s.item == .None || s.count == 0 do return true
		}
	case .Silo:
		if s := silo_at(gs, gs.level_index, tile); s != nil do return silo_has_room_for(s, item)
	case:
	}
	return false
}

golem_ground_pile_room :: proc(gs: ^Game_State, tile: [2]i32, item: Item) -> bool {
	x, y := int(tile.x), int(tile.y)
	if !in_bounds(x, y) || !in_bounds(x, y+1) || is_solid(&gs.world, x, y) || !is_solid(&gs.world, x, y+1) do return false
	idx := grid_idx(x, y)
	return gs.world.items[idx] == .None || gs.world.item_counts[idx] == 0 ||
	       gs.world.items[idx] == item && int(gs.world.item_counts[idx]) < MAX_STACK
}

// A Barrel/Depot is an efficiency upgrade, not a prerequisite.  Before one
// exists, workers make visible piles just outside the marked work rectangle.
golem_find_stockpile :: proc(gs: ^Game_State, from: [2]i32, item: Item) -> ([2]i32, bool) {
	w := gs.golems.work[gs.level_index]
	if !w.active do return {}, false
	best, best_score, ok := [2]i32{}, max(i32), false
	min_x := max(i32(0), w.min.x-GOLEM_STOCKPILE_MARGIN)
	max_x := min(i32(GRID_W-1), w.max.x+GOLEM_STOCKPILE_MARGIN)
	min_y := max(i32(0), w.min.y-GOLEM_STOCKPILE_MARGIN)
	max_y := min(i32(GRID_H-2), w.max.y+GOLEM_STOCKPILE_MARGIN)
	for y in int(min_y) ..= int(max_y) do for x in int(min_x) ..= int(max_x) {
		T := [2]i32{i32(x), i32(y)}
		if golem_in_work_zone(gs, T) || !golem_ground_pile_room(gs, T, item) do continue
		idx := grid_idx(x, y)
		score := chebyshev(from, T)
		if gs.world.items[idx] == item && gs.world.item_counts[idx] > 0 do score -= GOLEM_STOCKPILE_MARGIN
		if score < best_score {best, best_score, ok = T, score, true}
	}
	return best, ok
}

golem_find_deposit :: proc(gs: ^Game_State, from: [2]i32, item: Item) -> ([2]i32, bool) {
	best := [2]i32{}; best_score := max(i32); ok := false
	for y in 0 ..< GRID_H do for x in 0 ..< GRID_W {
		T := [2]i32{i32(x), i32(y)}
		if !golem_deposit_possible(gs, T, item) do continue
		t := get_tile(&gs.world, x, y)
		class := i32(4)
		if t == .Smelter do class = 0
		if t == .Golem_Depot do class = 1
		if t == .Barrel || is_rune_scroll_chest(t) do class = 2
		if t == .Silo do class = 3
		score := class*i32(GRID_W)*2 + chebyshev(from, T)
		if score < best_score {best, best_score, ok = T, score, true}
	}
	if ok do return best, true
	return golem_find_stockpile(gs, from, item)
}

golem_deposit_at :: proc(gs: ^Game_State, tile: [2]i32, item: Item) -> bool {
	t := get_tile(&gs.world, int(tile.x), int(tile.y))
	#partial switch t {
	case .Smelter:
		sd := &gs.world.sim_data[grid_idx(int(tile.x), int(tile.y))]
		if !golem_smelter_accepts(sd, item) do return false
		if smelter_is_fuel(item) {sd.fuel_count += 1} else {sd.in_item = item; sd.in_count += 1}
		return true
	case .Golem_Depot:
		if d := golem_depot_at(gs, gs.level_index, tile); d != nil do return golem_depot_add(d, item, 1)
	case .Barrel, .Sky_Rune_Scroll_Chest, .Rune_Scroll_Chest_A, .Rune_Scroll_Chest_B, .Rune_Scroll_Chest_C:
		if b := barrel_at(gs, gs.level_index, tile); b != nil do return barrel_deposit(b, item, 1) == 1
	case .Silo:
		if s := silo_at(gs, gs.level_index, tile); s != nil && silo_has_room_for(s, item) {
			silo_add(s, item, 1); return true
		}
	case:
	}
	if golem_ground_pile_room(gs, tile, item) {
		idx := grid_idx(int(tile.x), int(tile.y))
		if gs.world.items[idx] == item && gs.world.item_counts[idx] > 0 {
			gs.world.item_counts[idx] += 1
		} else {
			gs.world.items[idx] = item
			gs.world.item_counts[idx] = 1
		}
		return true
	}
	return false
}

golem_store_carried :: proc(gs:^Game_State, g:^Golem, tile:[2]i32) -> bool {
	item:=g.carry
	if item==.None || !golem_deposit_at(gs,tile,item) do return false
	spawn_item_transfer_motes(gs,golem_center(g),tile_center(tile),item)
	g.carry=.None
	gs.save_dirty=true
	return true
}

golem_fetch_carried :: proc(gs:^Game_State, g:^Golem, tile:[2]i32, item:Item) -> bool {
	if item==.None || !golem_take_item_at(gs,tile,item) do return false
	g.carry=item
	spawn_item_transfer_motes(gs,tile_center(tile),golem_center(g),item)
	gs.save_dirty=true
	return true
}

// ─── Navigation and actions ──────────────────────────────────────────────────

golem_job_reach :: proc(g: ^Golem) -> i32 {
	if g.job==.Place do return GOLEM_BUILD_REACH
	if g.job==.Deliver || g.job==.Fetch_Build do return GOLEM_TRANSFER_REACH
	return GOLEM_REACH
}

golem_set_target :: proc(gs: ^Game_State, g: ^Golem, tile: [2]i32, vertical_recovery := true) -> bool {
	g.target = tile
	g.has_target = true
	g.path = {}
	g.replan_timer = 0
	stop_within := golem_job_reach(g)
	can_mine_path := golem_pack_has_room(g)
	// Bridging is free Quick Clay, not real material — budget it by path
	// length instead of pack contents (a path can never use more bridge moves
	// than it has waypoints).
	bridge_budget := MAX_NAV_PATH
	complete := false
	if !astar_dig(gs, golem_tile(g), tile, stop_within, bridge_budget, &g.path,
		allow_mining = can_mine_path, complete = &complete, protect_placed = true) {
		if vertical_recovery && tile.y < golem_tile(g).y-stop_within {
			g.recovering = true
			g.recover_from = golem_tile(g).y
			g.path = {}
			return true
		}
		g.has_target = false
		return false
	}
	if vertical_recovery && !complete && tile.y < golem_tile(g).y-stop_within {
		g.recovering = true
		g.recover_from = golem_tile(g).y
		g.path = {}
		return true
	}
	if !can_mine_path && !complete {
		g.has_target = false
		g.path = {}
		return false
	}
	// A* normally returns its best partial route when no complete path exists.
	// That is useful for long routes (64-waypoint prefixes), but a shorter
	// loaded route ending away from the target is an unreachable destination.
	if !can_mine_path && g.path.len < MAX_NAV_PATH {
		last := golem_tile(g)
		if g.path.len > 0 do last = g.path.tiles[g.path.len-1]
		if chebyshev(last, tile) > stop_within {
			g.has_target = false
			g.path = {}
			return false
		}
	}
	return true
}

golem_cache_cargo :: proc(gs: ^Game_State, g: ^Golem) {
	if g.carry == .None do return
	origin := golem_tile(g)
	for r in i32(0) ..= 3 do for dy in -r ..= r do for dx in -r ..= r {
		if max(abs(dx), abs(dy)) != r do continue
		T := origin + [2]i32{dx,dy}
		if !golem_ground_pile_room(gs, T, g.carry) do continue
		if !golem_store_carried(gs,g,T) do continue
		golem_reset_job(g)
		return
	}
	// A fully enclosed pocket still must not deadlock the worker. Ground drops
	// search nearby non-solid cells and preserve the real carried block.
	spawn_ground_item(&gs.world, origin, g.carry, 1)
	g.carry = .None
	golem_reset_job(g)
	gs.save_dirty = true
}

golem_start_delivery :: proc(gs: ^Game_State, g: ^Golem) -> bool {
	if g.carry == .None do g.carry = golem_pack_pop(g)
	if g.carry == .None do return false
	g.job = .Deliver
	if dest, ok := golem_find_deposit(gs, golem_tile(g), g.carry); ok && golem_set_target(gs, g, dest, false) do return true
	// Preferred storage may be across an unbridged shaft or sealed tunnel.  A
	// loaded worker cannot mine another block, so keep the material productive
	// by returning it to the nearest reachable edge stockpile instead.
	if pile, ok := golem_find_stockpile(gs, golem_tile(g), g.carry); ok && golem_set_target(gs, g, pile) do return true
	// If an old route already stranded a loaded worker behind rock, set the
	// block down as a visible field cache. Empty hands can excavate a way out.
	golem_cache_cargo(gs, g)
	return false
}

// Resource desirability and reachability are separate concerns: a nearby vein
// can sit behind masonry while another vein has a valid route. Try the next
// ranked choices in the same assignment tick, then leave successful targets
// claimed so following workers naturally spread out.
golem_assign_resource :: proc(gs: ^Game_State, id: int) -> bool {
	g := &gs.golems.data[id]
	skipped: [16][2]i32
	for attempt in 0 ..< len(skipped) {
		target, ok := golem_find_resource(gs, id, skipped[:attempt])
		if !ok do break
		g.job = .Mine
		// Gathering should only reserve a target with a real route. Vertical
		// recovery is for escaping a fall; it cannot solve a sideways pocket
		// whose headroom is protected player masonry.
		if golem_set_target(gs, g, target, false) do return true
		skipped[attempt] = target
	}
	golem_reset_job(g)
	return false
}

golem_assign_gather :: proc(gs:^Game_State, id:int) {
	g:=&gs.golems.data[id]
	w:=gs.golems.work[gs.level_index]
	T:=golem_tile(g)
	// Once a fall leaves a worker below its marked job site, climb back before
	// selecting another faraway resource or storage route. But a worker can
	// also legitimately be this far below the rectangle on purpose, chasing a
	// Golem_Marked block — those are explicit permission to work anywhere, not
	// just inside the zone — so don't yank it away from one it can still reach.
	if w.active && T.y>w.max.y+2 {
		if _, marked := golem_find_marked_resource(gs, id, nil); !marked {
			g.job=.Seek
			g.target={clamp(T.x,w.min.x,w.max.x),w.min.y}
			g.has_target=true
			g.recovering=true
			g.recover_from=T.y
			g.path={}
			g.replan_timer=0
			return
		}
	}
	if g.carry!=.None {
		_ = golem_start_delivery(gs,g)
	} else if golem_pack_has_room(g) {
		if golem_assign_resource(gs,id) {
			return
		} else if golem_pack_count(g)>0 {
			_ = golem_start_delivery(gs,g)
		}
	} else if golem_pack_count(g)>0 {
		_ = golem_start_delivery(gs,g)
	} else {
		_ = golem_assign_resource(gs,id)
	}
}

golem_follow_path :: proc(g: ^Golem, w: ^World_Grid) {
	if g.path.cursor >= g.path.len {g.vel.x = 0; return}
	T := g.path.tiles[g.path.cursor]
	dx := f32(T.x)+0.5 - (g.pos.x+GOLEM_W*0.5)
	dy := f32(T.y)+0.5 - (g.pos.y+GOLEM_H*0.5)
	if math.sqrt(dx*dx+dy*dy) < 0.38 && (g.grounded || dy > 0) {
		g.path.cursor += 1
		g.replan_timer = 0
		return
	}
	if abs(dx) > 0.08 {
		g.facing = 1 if dx >= 0 else -1
		g.vel.x = f32(g.facing)*GOLEM_SPEED
	} else {g.vel.x = 0}
	if g.grounded {
		wall := is_solid(w, int(g.pos.x+f32(g.facing)*(GOLEM_W+0.1)), int(g.pos.y+GOLEM_H-0.3))
		if dy < -0.35 || wall do g.vel.y = GOLEM_JUMP
	}
}

// ─── Quick Clay ───────────────────────────────────────────────────────────────
//
//  A worker's own free, instant foothold for bridging a gap or pillaring up
//  during vertical recovery — never real material, never mineable, never
//  reclaimed. It just dissolves once its worker has moved on.

golem_dissolve_quick_clay :: proc(gs: ^Game_State, slot: ^Golem_Quick_Clay) {
	if get_tile(&gs.world, int(slot.tile.x), int(slot.tile.y)) == .Quick_Clay {
		set_tile(&gs.world, int(slot.tile.x), int(slot.tile.y), gravity_open_tile(gs, int(slot.tile.y)))
		spawn_clay_drip(gs, slot.tile)
	}
	slot.active = false
}

golem_place_quick_clay :: proc(gs: ^Game_State, g: ^Golem, id: int, tile: [2]i32) {
	set_tile(&gs.world, int(tile.x), int(tile.y), .Quick_Clay)
	pool := &gs.golem_quick_clay
	for &slot in pool.blocks do if !slot.active {
		slot = {active = true, tile = tile, level = gs.level_index, owner = i16(id)}
		return
	}
	// Pool exhausted (unusual: a very long unbroken climb or bridge). Reclaim
	// this worker's own oldest foothold rather than leaving an untracked,
	// permanent Quick Clay block behind — it must always succeed.
	for &slot in pool.blocks do if slot.active && slot.level == gs.level_index && slot.owner == i16(id) {
		golem_dissolve_quick_clay(gs, &slot)
		slot = {active = true, tile = tile, level = gs.level_index, owner = i16(id)}
		return
	}
}

golem_tick_quick_clay :: proc(gs: ^Game_State) {
	for &slot in gs.golem_quick_clay.blocks {
		if !slot.active || slot.level != gs.level_index do continue
		g := &gs.golems.data[slot.owner]
		if g.status != .Deployed || g.level != gs.level_index ||
		   chebyshev(golem_tile(g), slot.tile) > GOLEM_QUICK_CLAY_LINGER {
			golem_dissolve_quick_clay(gs, &slot)
		}
	}
}

// The Quick Clay pool is deliberately not saved (Golem_Quick_Clay_State
// comment, game_state.odin) — but the .Quick_Clay world tile IS, being part
// of World_Grid. A save/load wipes the pool, so nothing is left to ever
// dissolve a tile that was mid-lingering at save time: it would otherwise
// sit as permanent fake terrain. Called once whenever gs.world becomes the
// active level for a level with no live memory of its pool (right after
// load_game, and on every level_transition) — a plain grid scan, cheap and
// idempotent, and a no-op on a level with no orphaned Quick Clay.
golem_sweep_orphan_quick_clay :: proc(gs: ^Game_State) {
	for y in 0 ..< GRID_H {
		for x in 0 ..< GRID_W {
			if get_tile(&gs.world, x, y) != .Quick_Clay do continue
			tracked := false
			for slot in gs.golem_quick_clay.blocks {
				if slot.active && slot.level == gs.level_index && slot.tile == {i32(x), i32(y)} {
					tracked = true
					break
				}
			}
			if !tracked {
				set_tile(&gs.world, x, y, gravity_open_tile(gs, y))
			}
		}
	}
}

golem_exec_path_bridge :: proc(gs: ^Game_State, g: ^Golem, id: int) -> bool {
	if g.mine_timer > 0 {g.vel.x=0; return true}
	if g.path.cursor >= g.path.len do return false
	T := g.path.tiles[g.path.cursor]
	bt := golem_tile(g)
	x, y := int(T.x), int(T.y)
	if T.y < bt.y || !in_bounds(x,y+1) || is_solid(&gs.world,x,y+1) do return false
	golem_place_quick_clay(gs, g, id, {i32(x), i32(y+1)})
	g.mine_timer = GOLEM_MINE_TIME
	g.vel.x = 0
	gs.save_dirty = true
	eq_push(&gs.events, Event{type=.Play_Sound,tile={i32(x),i32(y+1)},payload={int_val=i32(Sound_ID.Place)}})
	return true
}

golem_end_recovery :: proc(g: ^Golem) {
	g.recovering = false
	g.has_target = false
	g.path = {}
	g.vel.x = 0
	g.replan_timer = 0
}

// Vertical self-rescue: carve headroom when blocked, then hop up onto a free
// Quick Clay foothold. Repeats until ordinary A* can take over near the
// objective. Headroom is still real terrain (its drops still bank to the
// pack), but the footing itself costs nothing and needs no material.
golem_update_recovery :: proc(gs: ^Game_State, g: ^Golem, id: int) {
	bt := golem_tile(g)
	if bt.y <= g.target.y+golem_job_reach(g) {golem_end_recovery(g); return}
	g.vel.x = 0
	if g.mine_timer > 0 do return
	x,y := int(bt.x),int(bt.y)

	if !g.grounded do return

	// Carve headroom first. Quick Clay only ever supplies footing, not a way
	// through solid rock overhead.
	for c in ([2][2]i32{{i32(x),i32(y-1)},{i32(x),i32(y-2)}}) {
		if is_solid(&gs.world,int(c.x),int(c.y)) {
			if !golem_pack_has_room(g) {
				cached:=golem_pack_pop(g)
				spawn_ground_item(&gs.world,bt,cached,1)
				gs.save_dirty=true
			}
			if !golem_mine_tile(gs,g,c,true,id) do golem_end_recovery(g)
			return
		}
	}
	if !is_solid(&gs.world,x,y) {
		// Raise the body first, then plug its old cell with an instant, free
		// Quick Clay foothold — no material spent, no scavenging needed; it
		// dissolves in a dripping blob once the worker has moved on.
		g.pos.y-=1
		golem_place_quick_clay(gs, g, id, {i32(x), i32(y)})
		g.vel={}
		g.grounded=true
		g.mine_timer=GOLEM_MINE_TIME
		gs.save_dirty=true
	}
}

golem_in_work_zone :: proc(gs: ^Game_State, tile: [2]i32) -> bool {
	w := gs.golems.work[gs.level_index]
	return w.active && tile.x >= w.min.x && tile.x <= w.max.x && tile.y >= w.min.y && tile.y <= w.max.y
}

golem_mine_tile :: proc(gs: ^Game_State, g: ^Golem, tile: [2]i32, path_clear := false, id := -1) -> bool {
	if g.mine_timer > 0 do return false
	x, y := int(tile.x), int(tile.y)
	if !in_bounds(x, y) do return false
	idx := grid_idx(x, y)
	t := gs.world.terrain[idx]
	flags := gs.world.tile_flags[idx]
	if !path_clear && !golem_in_work_zone(gs,tile) && .Golem_Marked not_in flags do return false
	if .Golem_Placed in flags && golem_block_grace_protected(gs,id,tile) do return false
	// A den shell can otherwise turn a completed rescue pillar into a trap: the
	// worker aborts beneath the protected ceiling and falls all the way back
	// down. Only the active vertical self-rescue may punch its narrow shaft
	// through that shell; ordinary pathing still leaves enemy dens intact.
	den_blocks_path := den_protected(gs,x,y,-1) && !g.recovering
	// A Gather target is explicit permission to remove ordinary player masonry
	// inside the rectangle. Incidental path clearing still protects it.
	if (path_clear && .Placed in flags && .Golem_Placed not_in flags) || den_blocks_path || is_structure_tile[t] do return false
	if path_clear {
		if .Mineable not_in terrain_table[t].flags do return false
	} else if golem_resource_priority(t) == 0 && .Golem_Marked not_in flags do return false
	drop := terrain_table[t].drop_item
	if pct := terrain_table[t].drop_pct; pct > 0 {
		if whash(u32(idx)*2246822519 + 101) % 100 >= u32(pct) do drop = .None
	}
	if drop != .None && !golem_pack_has_room(g) do return false
	set_tile(&gs.world, x, y, gravity_open_tile(gs, y))
	golem_remove_block_mark(gs,tile)
	gs.world.tile_flags[idx] -= {.Placed,.Golem_Placed}
	gravity_check_removed(gs, x, y)
	if drop != .None do _ = golem_pack_add(g, drop)
	color:=terrain_table[t].color
	if drop!=.None do color=item_table[drop].color
	spawn_transfer_motes(gs,tile_center(tile),golem_center(g),color)
	g.mine_timer = GOLEM_MINE_TIME
	if !path_clear {
		g.has_target = false
		g.path = {}
	}
	gs.save_dirty = true
	eq_push(&gs.events, Event{type = .Play_Sound, tile = tile, payload = {int_val = i32(Sound_ID.Mine)}})
	return true
}

golem_clear_path_obstruction :: proc(gs: ^Game_State, g: ^Golem, id: int) -> bool {
	if !golem_pack_has_room(g) || g.path.cursor >= g.path.len do return false
	T := g.path.tiles[g.path.cursor]
	// Landing and headroom are the cells an A* dig transition may require.
	for c in ([3][2]i32{T, {T.x, T.y-1}, {golem_tile(g).x, golem_tile(g).y-1}}) {
		if is_solid(&gs.world, int(c.x), int(c.y)) && golem_mine_tile(gs, g, c, true, id) {
			return true
		}
	}
	return false
}

// A saved path can become invalid after the worker builds beneath itself.
// Validate the whole upward takeoff arc, not only the landing waypoint: a
// block directly overhead otherwise leaves the worker jumping in place.
golem_path_obstructed :: proc(gs: ^Game_State, g: ^Golem) -> bool {
	if g.path.cursor >= g.path.len do return false
	T := g.path.tiles[g.path.cursor]
	if is_solid(&gs.world, int(T.x), int(T.y)) do return true
	bt := golem_tile(g)
	if T.y < bt.y {
		return is_solid(&gs.world, int(bt.x), int(bt.y-1)) ||
		       is_solid(&gs.world, int(T.x), int(T.y-1))
	}
	return false
}

// A path may survive a fall even though its upper ledge no longer can. A*
// transitions move at most two columns and rise at most two rows; anything
// farther away is an abandoned waypoint and must be replanned from the landing.
golem_path_stale :: proc(g:^Golem) -> bool {
	if g.path.cursor>=g.path.len do return false
	bt:=golem_tile(g)
	T:=g.path.tiles[g.path.cursor]
	return abs(T.x-bt.x)>2 || T.y<bt.y-2
}

golem_pick_resource :: proc(gs: ^Game_State, g: ^Golem, id: int) {
	idx := grid_idx(int(g.target.x), int(g.target.y))
	if gs.world.items[idx] != .None && gs.world.item_counts[idx] > 0 && !is_rune_scroll(gs.world.items[idx]) {
		item:=gs.world.items[idx]
		if golem_pack_add(g, item) {
			gs.world.item_counts[idx] -= 1
			if gs.world.item_counts[idx] == 0 do gs.world.items[idx] = .None
			spawn_item_transfer_motes(gs,tile_center(g.target),golem_center(g),item)
		}
	} else {
		_ = golem_mine_tile(gs, g, g.target, false, id)
	}
	// A failed attempt (mine_timer still cooling down, a full pack, ...) is
	// fine to abandon here: the very next assignment tick re-evaluates from
	// scratch, and a full pack correctly triggers a delivery trip instead of
	// a re-pick. That reassignment used to be hijacked by golem_assign_gather's
	// zone-distance heuristic (see its comment) whenever the target sat below
	// the work-zone rectangle, forcing a pointless climb that looped forever
	// on a resource it could never actually reach again. That heuristic is
	// the real fix; this reset is deliberately unconditional.
	g.job = .Idle
	g.has_target = false
	g.path = {}
}

golem_project_cell_done :: proc(gs: ^Game_State, p: ^Golem_Project, ci: int) -> bool {
	info := &golem_plan_table[p.plan]
	if ci < 0 || ci >= len(info.cells) do return true
	c := info.cells[ci]
	return get_tile(&gs.world, int(p.anchor.x+c.off.x), int(p.anchor.y+c.off.y)) == c.tile
}

golem_project_reserve :: proc(gs: ^Game_State, id: int) -> bool {
	g := &gs.golems.data[id]
	p := &gs.golems.projects[g.level]
	if !p.active || p.complete do return false
	info := &golem_plan_table[p.plan]
	// A cell whose material is nowhere to be had must not hold up the cells
	// behind it: reserve only work this golem can actually source (carried,
	// packed, or findable in storage / on the ground), so a missing Clay
	// leaves the Plank courses buildable instead of stalling the whole
	// monument.  The source scan walks the whole grid, so remember items
	// that already failed — one scan per distinct missing item, not per cell.
	failed: [8]Item
	n_failed := 0
	for ci in 0 ..< len(info.cells) {
		if golem_project_cell_done(gs, p, ci) || p.reserved[ci] != 0 do continue
		item := info.cells[ci].item
		if g.carry != item && !golem_pack_has(g, item) {
			known_dry := false
			for i in 0 ..< n_failed do if failed[i] == item {known_dry = true; break}
			if known_dry do continue
			if _, ok := golem_find_item_source(gs, golem_tile(g), item); !ok {
				if n_failed < len(failed) {failed[n_failed] = item; n_failed += 1}
				continue
			}
		}
		p.reserved[ci] = u8(id+1)
		g.project_cell = i16(ci)
		return true
	}
	golem_note_starved(gs, failed[:n_failed])
	return false
}

// A crew waiting for material it cannot source must say so, or the wait reads
// as a stuck worker (Glenn reported exactly that, twice — the Clay was in his
// bag the whole time).  Reported only from reserve's full-pass failure, so
// every starved worker computes the same list and the notify fires once per
// distinct starvation set, not per frame.  The list feeds the command strip's
// NEEDS line and is gated there on an active incomplete project.
golem_note_starved :: proc(gs: ^Game_State, failed: []Item) {
	changed := len(failed) != gs.golem_need_n
	if !changed do for it, i in failed do if gs.golem_need[i] != it {changed = true; break}
	if !changed do return
	gs.golem_need_n = len(failed)
	for it, i in failed do gs.golem_need[i] = it
	if len(failed) == 0 do return
	buf: [96]u8
	// Keep it inside NOTIFY_TEXT_LEN (64) with a two-item list.
	notify(gs, "the crew needs %s - drop it nearby", golem_need_text(gs, buf[:]))
}

// "Clay, Iron Bar" — joined display names of the wanted items.
golem_need_text :: proc(gs: ^Game_State, buf: []u8) -> string {
	n := 0
	for i in 0 ..< gs.golem_need_n {
		if i > 0 do n += copy(buf[n:], ", ")
		n += copy(buf[n:], item_table[gs.golem_need[i]].name)
	}
	return string(buf[:n])
}

golem_project_finish_if_done :: proc(gs: ^Game_State, p: ^Golem_Project) {
	if !p.active || p.complete do return
	info := &golem_plan_table[p.plan]
	for ci in 0 ..< len(info.cells) do if !golem_project_cell_done(gs, p, ci) do return
	p.complete = true
	if p.plan == .Golem_Depot do golem_depot_on_built(gs, p.anchor)
	spawn_grow_burst(gs, p.anchor)
	audio_play(&gs.audio, .Fanfare)
	notify(gs, "%s complete - the crew raises its runes", info.name)
	gs.save_dirty = true
}

golem_assign_build :: proc(gs: ^Game_State, id: int) {
	g := &gs.golems.data[id]
	if g.project_cell < 0 && !golem_project_reserve(gs, id) {
		golem_project_finish_if_done(gs, &gs.golems.projects[g.level])
		return
	}
	p := &gs.golems.projects[g.level]
	info := &golem_plan_table[p.plan]
	ci := int(g.project_cell)
	if ci < 0 || ci >= len(info.cells) {golem_release_reservation(gs, id); return}
	c := info.cells[ci]
	dest := p.anchor + c.off
	if golem_project_cell_done(gs, p, ci) {golem_release_reservation(gs, id); return}
	if g.carry == c.item {
		g.job = .Place
		_ = golem_set_target(gs, g, dest)
		return
	}
	if g.carry != .None {
		if golem_pack_add(g,g.carry) {
			g.carry=.None
		} else {
			golem_release_reservation(gs, id)
			g.mode = .Gather
			g.job = .Deliver
		}
		return
	}
	if golem_pack_take(g,c.item) {
		g.carry=c.item
		g.job=.Place
		_ = golem_set_target(gs,g,dest)
		return
	}
	if src, ok := golem_find_item_source(gs, golem_tile(g), c.item); ok {
		g.job = .Fetch_Build
		_ = golem_set_target(gs, g, src)
	} else {
		// The source dried up after this cell was reserved (another worker
		// took the last one). Let go so the next tick can reserve a cell
		// that still has material instead of holding the queue hostage.
		golem_release_reservation(gs, id)
	}
}

golem_place_reserved :: proc(gs: ^Game_State, id: int) {
	g := &gs.golems.data[id]
	p := &gs.golems.projects[g.level]
	info := &golem_plan_table[p.plan]
	ci := int(g.project_cell)
	if ci < 0 || ci >= len(info.cells) {golem_release_reservation(gs, id); return}
	c := info.cells[ci]
	T := p.anchor + c.off
	if g.carry != c.item || (get_tile(&gs.world, int(T.x), int(T.y)) != .Air && get_tile(&gs.world, int(T.x), int(T.y)) != .Void) {
		golem_release_reservation(gs, id); golem_reset_job(g); return
	}
	set_tile(&gs.world, int(T.x), int(T.y), c.tile)
	if c.tile != .Clay_Hearth && c.tile != .Golem_Depot && c.tile != .World_Anchor {
		gs.world.tile_flags[grid_idx(int(T.x), int(T.y))] += {.Placed}
	}
	spawn_item_transfer_motes(gs,golem_center(g),tile_center(T),c.item)
	g.carry = .None
	g.mine_timer = GOLEM_MINE_TIME
	golem_release_reservation(gs, id)
	golem_reset_job(g)
	spawn_smelt_burst(gs, T)
	gs.save_dirty = true
	golem_project_finish_if_done(gs, p)
}

golem_update_hazard :: proc(gs: ^Game_State, g: ^Golem, id: int) {
	t := get_tile(&gs.world, int(g.pos.x+GOLEM_W*0.5), int(g.pos.y+GOLEM_H*0.5))
	dps := terrain_table[t].damage_per_second
	if dps <= 0 {g.hazard_timer = 0; return}
	g.hazard_timer += gs.delta_time*dps
	for g.hazard_timer >= 1 && g.status == .Deployed {
		g.hazard_timer -= 1
		golem_damage(gs,id,1)
		if g.status != .Deployed do return
	}
}

// Escalate into vertical recovery if the target sits meaningfully above what
// this job's reach permits, otherwise try to replan a route to the same
// target; give up the target on failure. Shared by the replan-timer trip and
// the stale-path check in golem_update_one — only the timer-trip site also
// clears replan_timer (so it isn't immediately re-triggered next frame; the
// stale-path site has no timer to clear).
golem_recover_or_replan :: proc(gs: ^Game_State, g: ^Golem, reset_replan_timer: bool) {
	target := g.target
	bt := golem_tile(g)
	if target.y < bt.y - golem_job_reach(g) {
		g.recovering = true
		g.recover_from = bt.y
		g.path = {}
		g.vel.x = 0
		if reset_replan_timer do g.replan_timer = 0
	} else if !golem_set_target(gs, g, target) {
		g.has_target = false
		g.vel.x = 0
		if reset_replan_timer do g.replan_timer = 0
	}
}

golem_update_one :: proc(gs: ^Game_State, id: int) {
	g := &gs.golems.data[id]
	if g.status != .Deployed || g.level != gs.level_index do return
	_ = golem_unembed(gs,g)
	if g.mine_timer > 0 do g.mine_timer = max(0, g.mine_timer-gs.delta_time)
	golem_update_hazard(gs, g, id)
	if g.status != .Deployed do return
	if g.recovering {
		golem_update_recovery(gs,g,id)
		move_body(&gs.world, &g.pos, &g.vel, {GOLEM_W, GOLEM_H}, gs.delta_time,
			GRAVITY, MAX_FALL_SPEED, &g.grounded, step_up = true)
		return
	}

	if !g.has_target {
		if g.mode==.Gather {
			golem_assign_gather(gs,id)
		} else {
			p:=&gs.golems.projects[g.level]
			if !p.active || p.complete {
				// Build means Build: finish unloading old cargo, then wait for a
				// monument plan instead of silently returning to Gather work.
				if g.carry!=.None || golem_pack_count(g)>0 {
					_ = golem_start_delivery(gs,g)
				} else {
					g.vel.x=0
				}
			} else {
				golem_assign_build(gs,id)
			}
		}
	}
	if g.recovering {
		golem_update_recovery(gs,g,id)
		move_body(&gs.world, &g.pos, &g.vel, {GOLEM_W, GOLEM_H}, gs.delta_time,
			GRAVITY, MAX_FALL_SPEED, &g.grounded, step_up = true)
		return
	}
	if g.has_target {
		g.replan_timer += gs.delta_time
		if g.replan_timer >= GOLEM_STUCK_TIME {
			golem_recover_or_replan(gs, g, true)
		}
	}

	if g.has_target {
		reach := GOLEM_REACH
		if g.job == .Place do reach = GOLEM_BUILD_REACH
		if g.job == .Deliver || g.job == .Fetch_Build do reach = GOLEM_TRANSFER_REACH
		if chebyshev(golem_tile(g), g.target) <= reach {
			#partial switch g.job {
			case .Seek:       golem_reset_job(g)
			case .Mine:       golem_pick_resource(gs, g, id)
			case .Deliver:
				stored:=golem_store_carried(gs,g,g.target)
				continues:=false
				if !stored || golem_pack_count(g)>0 do continues=golem_start_delivery(gs,g)
				if !continues do golem_reset_job(g)
			case .Fetch_Build:
				p := &gs.golems.projects[g.level]
				info := &golem_plan_table[p.plan]
				ci := int(g.project_cell)
				if ci >= 0 && ci < len(info.cells) do _ = golem_fetch_carried(gs,g,g.target,info.cells[ci].item)
				golem_reset_job(g)
			case .Place:      golem_place_reserved(gs, id)
			case:
				golem_reset_job(g)
			}
		} else {
			// Saved routes may be invalidated by newly placed navigation masonry.
			// Clear reclaimable blocks; otherwise replan instead of repeatedly
			// jumping into a blocked landing or takeoff arc.
			if golem_path_stale(g) {
				golem_recover_or_replan(gs, g, false)
			}
			if g.recovering {
				move_body(&gs.world,&g.pos,&g.vel,{GOLEM_W,GOLEM_H},gs.delta_time,
					GRAVITY,MAX_FALL_SPEED,&g.grounded,step_up=true)
				return
			}
			if golem_path_obstructed(gs,g) && !golem_clear_path_obstruction(gs,g,id) {
				target := g.target
				if !golem_set_target(gs, g, target) {
					g.has_target = false
					g.vel.x = 0
				}
			}
			if !g.has_target {
				move_body(&gs.world, &g.pos, &g.vel, {GOLEM_W, GOLEM_H}, gs.delta_time,
					GRAVITY, MAX_FALL_SPEED, &g.grounded, step_up = true)
				return
			}
			if !golem_exec_path_bridge(gs,g,id) && !golem_clear_path_obstruction(gs, g,id) {
				if g.path.cursor >= g.path.len {
					target := g.target
					if !golem_set_target(gs, g, target) do g.has_target = false
				}
				golem_follow_path(g, &gs.world)
			}
		}
	}

	move_body(&gs.world, &g.pos, &g.vel, {GOLEM_W, GOLEM_H}, gs.delta_time,
		GRAVITY, MAX_FALL_SPEED, &g.grounded, step_up = true)
}

update_golems :: proc(gs: ^Game_State) {
	for i in 0 ..< MAX_GOLEMS do golem_update_one(gs, i)
	golem_tick_quick_clay(gs)
}

// ─── Hearth, repair and upgrades ─────────────────────────────────────────────

replace_player_item :: proc(gs: ^Game_State, old, new: Item) -> bool {
	if gs.player.equipment[.Weapon] == old {gs.player.equipment[.Weapon] = new; return true}
	for &s in gs.player.inventory.slots do if s.item == old && s.count > 0 {s.item = new; return true}
	return false
}

golem_hearth_use :: proc(gs: ^Game_State) {
	for &g in gs.golems.data {
		if g.status != .Carried || g.hp > 0 do continue
		if !inventory_remove(&gs.player.inventory, .Clay, 2) {
			notify(gs, "A cracked golem needs 2 Clay")
			return
		}
		g.hp = GOLEM_HP
		gs.save_dirty = true
		notify(gs, "The Hearth seals a golem's cracks")
		return
	}

	if replace_player_item(gs, .Command_Wand, .Command_Wand_Emerald) {
		if !inventory_remove(&gs.player.inventory, .Emerald, 1) {
			_ = replace_player_item(gs, .Command_Wand_Emerald, .Command_Wand)
			notify(gs, "The five-slot binding needs 1 Emerald")
			return
		}
		gs.save_dirty = true
		audio_play(&gs.audio, .Fanfare)
		notify(gs, "Emerald binding awakened - 5 golem slots")
		return
	}
	if replace_player_item(gs, .Command_Wand_Emerald, .Command_Wand_Hel) {
		if !inventory_remove(&gs.player.inventory, .Hel_Gem, 1) {
			_ = replace_player_item(gs, .Command_Wand_Hel, .Command_Wand_Emerald)
			notify(gs, "The final binding needs 1 Hel Gem")
			return
		}
		gs.save_dirty = true
		audio_play(&gs.audio, .Fanfare)
		notify(gs, "Hel binding awakened - 15 golem slots")
		return
	}
	notify(gs, "The Hearth is quiet - bring a cracked golem or the next binding gem")
}

dimension_world_anchored :: proc(gs: ^Game_State) -> bool {
	if gs.dimension.miner.active do return true
	w := &gs.world if gs.level_index == LEVEL_DIMENSION else &gs.levels.worlds[LEVEL_DIMENSION]
	if gs.level_index != LEVEL_DIMENSION && !gs.levels.generated[LEVEL_DIMENSION] do return false
	for t in w.terrain do if t == .World_Anchor do return true
	return false
}
