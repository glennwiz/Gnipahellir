package game

// ─── Buffs: transient timed effects and their display registry ────────────────
//
//  A buff is a transient countdown somewhere in Game_State (never saved — a
//  reload drops running buffs, same accepted limit as steam cloud ages).  This
//  table drives the HUD row beside the HP bar (draw_buffs, ui.odin): every
//  running buff shows as its item's icon with the seconds left, hover for the
//  description.  New buff = one enum value, one table row, one case in
//  buff_remaining.  No update step: each buff's own system ticks its clock.

Buff :: enum u8 {
	Leaf_Fall,
	Flight,
	Soaked,
	Eel_Bite,
}

Buff_Info :: struct {
	name: string,
	desc: string,
	icon: Item, // drawn with the item's own pixel art
}

@(rodata)
buff_table := [Buff]Buff_Info{
	.Leaf_Fall = {
		"Leaf Fall",
		"You drift down like a leaf: slow fall, and no landing ever hurts.",
		.GreenBerrie,
	},
	.Flight = {
		"Flight",
		"The altar's swirl bears you aloft: move freely in any direction.",
		.Sky_Altar,
	},
	.Soaked = {
		"Soaked",
		"A rain wisp dripped on you: your stride drags until you dry off.",
		.Water_Bucket,
	},
	.Eel_Bite = {
		"Eel Bite",
		"An eel's bite has numbed your legs: you move slower for a moment.",
		.Eel_Skin,
	},
}

// Seconds left on a buff; 0 = not running.
buff_remaining :: proc(gs: ^Game_State, b: Buff) -> f32 {
	switch b {
	case .Leaf_Fall:
		return gs.leaf_fall_t
	case .Flight:
		return gs.flight_t
	case .Soaked:
		return gs.soak_t
	case .Eel_Bite:
		return gs.bite_slow_t
	}
	return 0
}
