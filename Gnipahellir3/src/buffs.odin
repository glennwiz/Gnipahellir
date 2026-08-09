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
}

// Seconds left on a buff; 0 = not running.
buff_remaining :: proc(gs: ^Game_State, b: Buff) -> f32 {
	switch b {
	case .Leaf_Fall:
		return gs.leaf_fall_t
	}
	return 0
}
