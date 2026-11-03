# Art and sound provenance

Inventory for board card 86, step 1, taken 2026-11-03 at commit 24d3530. It
lists everything players see, hear or read, and how each group was made.
Glenn's goal is no AI in shipped art, for Steam, before the store page (about
Dec 15). Nothing here has been replaced. Agents do not draw replacements.

The card's check, "nothing left marked unknown", is NOT met yet. It waits on
the questions in "Glenn to confirm". No maker below is a guess: each comes from
a file's embedded metadata or from git history, and anything else is a question.

## Findings

1. **Three concept PNGs are provably AI-made.** Each carries a signed C2PA
   credential: OpenAI Media Service, `gpt-image` 2.0, `trainedAlgorithmicMedia`.
   They do not load at runtime, but the Rune chest, the Bench and the Builder
   are drawn in code "translated from" them, and `pixel_style.md` makes the
   chest the style reference.
2. **Sound may be a bigger Steam risk than AI.** The sound folder has no licence
   file. Its names read as another game's abilities, and 9 files have tags naming
   other makers or libraries, one marked "All rights reserved". One of those 9
   is loaded by the game.
3. **The atlases have an AI prompt beside them in history, but no proof.**
   `sprites/prompt.md`, added with both atlases in 23f3068 and deleted in 190a876,
   asks an AI assistant to "Create a pixel-art sprite atlas" with a Pillow PNG
   and a manifest JSON, in the same cell sizes (80, 96). It says to "match
   existing atlases", so it is a template and does not show these files came
   from it. The handover at 8f5df69 says of the tile sheet "the PNG is his". The
   tile atlas is the only image the game loads, so question 2 matters most.
4. **Most code-drawn art and game text came from agent commits.** That includes
   every commit to the icon, player and item tables. Whether this counts as
   AI-made is Glenn's call (question 4).

## Assets

Status: **AI** = proven AI-made. **Agent** = git shows a Claude co-author, and
Glenn's share is not recorded. **Rights open** = maker or licence not shown.
**Clear** = no open question.

### Visual

| Asset group | Ships? | How it was made | Evidence | Licence | Status |
|---|---|---|---|---|---|
| `sprites/blueprint_chests_concept.png`, `builder_concept.png`, `crafting_bench_concept.png` | No, reference only | OpenAI gpt-image 2.0 | C2PA manifest in each PNG's `caBX` chunk; committed 93e1bdd, 0440249 | OpenAI terms | **AI** |
| Rune chest, Bench and Builder drawn in code (`draw_pixel_rune_scroll_chest`, `draw_pixel_crafting_bench`, the Builder draw; the Draugr reuses the Builder frame) | Yes | Translated from the AI concepts above | Comments at `src/render.odin:1161`, `:1245`, `:2683`, `:2891` | Game code | **AI**-derived (question 3) |
| `sprites/gnipahellir_tiles_atlas.png` and `.json` (22 cells, 80 px) | Yes, the only image loaded (`src/assets.odin:13`) | Not shown. No packing script in the repo; `sprites/prompt.md`, an AI atlas prompt, landed in the same commit (23f3068) and was deleted in 190a876 | No metadata in the PNG; commit has a Claude co-author | Not recorded | **Rights open** (question 2) |
| `sprites/gnipahellir_tile_spritesheet.png` | No, atlas source | Not shown. Labelled sheet, committed in 8f5df69. Root `HANDOVER.md` there: ask Glenn the layout, "the PNG is his, added 2026-07-05". `sprites/prompt.md` is the same style, but no record links them | No metadata in the PNG | Not recorded | **Rights open** (question 2) |
| `sprites/gnipahellir_items_atlas.png`, `.json`, `gnipahellir_item_spritesheet.png` | No, nothing loads them | Not shown; committed in 23f3068 with `sprites/prompt.md` (96 px cells match it), but no record links them | No metadata in the PNG | Not recorded | **Rights open** (question 2) |
| Item icons, `src/gen_item_icons.odin` (12x12 grids, written by `tools/gnipa_studio`) | Yes | Agent commits; some were Glenn's edits in the studio (2c2e453 pickaxe head and bench feet; 9c87e5a GreenBerrie) | 14 of 14 commits have a Claude co-author | Game code | **Agent** (questions 4, 5) |
| Player sprites, `src/gen_player_art.odin` (16x22) | Yes | Agent commits; began as a port of the Gnipahellir2 mage (dbd9927) | 4 of 4 commits have a Claude co-author | Game code | **Agent** (questions 4, 5) |
| World and enemy pixel art in `src/render.odin` (`draw_pixel_*`, `draw_fire_sprite`, gates, altar, smelter, enemies), Garm in `src/garm.odin` | Yes | Agent commits, some without a co-author | `render.odin` 61 of 90 commits have a Claude co-author, `garm.odin` 15 of 17 | Game code | **Agent** (questions 4, 5) |
| UI art and title screen in `src/ui.odin` (window frames, meters, hotbar, title word and runes) | Yes | Mixed. The title screen commit 18a6449 has no co-author | 47 of 76 commits have a Claude co-author | Game code | **Agent** (questions 4, 5) |
| Particles and effects: `src/particles.odin`, `src/fx.odin` (22 `rl.Draw` calls: raid rumble, cage spark, ghost maw, fire charge), `src/projectile.odin` (10), `src/floating_text.odin` (2) | Yes | Code-drawn pixels, no image data | Claude co-author on particles 16 of 22 commits, fx 2 of 3, projectile 3 of 4, floating_text 3 of 3 | Game code | **Agent** (question 4) |
| `pixel_art.dat`, in-game Pixel Art Editor saves (`src/pixel_art.odin`) | No, not in git | Debug tool output, applies only if the file exists | `git ls-files` | None | Clear unless a build packs it |
| Font | Yes | raylib's default font; the game loads no font (no `LoadFont` in `src`) | `src/ui.odin` uses `DrawText` | raylib zlib licence, `vendor/raylib/LICENSE` in the Odin install | Clear |

### Sound

| Asset group | Ships? | How it was made | Evidence | Licence | Status |
|---|---|---|---|---|---|
| 18 files loaded by `src/audio.odin` from `sounds/splash_bang_pop/` | Yes | Not recorded. `sound_loot_pickup.wav` is tagged Metal Sweeteners; the other 17 have no maker tag | Listed below | None in the repo | **Rights open** (question 1) |
| The other 181 files in `sounds/splash_bang_pop/` (199 wav, 35 MB in all) | Only if the folder is packed whole | Not recorded. 8 have third-party tags, listed below | RIFF `LIST` chunks | None in the repo | **Rights open** (question 1) |
| Cave ambience | Yes | Synthesized at runtime in `src/audio.odin` | `AMB_SR` stream filled by code; audio system commit 26bbbca has a Claude co-author | Game code | **Agent** (question 4) |

`Gnipahellir2/sounds/battle.zip` holds 149 wavs and is not used by this game. It
is still in the repo, and its names (`WAV_16_GUESS_SE_BTL_TREASURE`, "antenna
use") look extracted from another game. Keep it out of any build.

**The 18 loaded files:** `sfx_ar_primary_attack`, `sfx_br_flamehook_attack`,
`sfx_br_footwork_trigger_2`, `sfx_sr_magickedfleche_attack`,
`sfx_sr_novidark_attack`, `sound_chain`, `sound_enemy_charge`,
`sound_enemy_defeat`, `sound_enemy_defeat_small`, `sound_enrage_blast`,
`sound_enrage_start`, `sound_hit_ally`, `sound_hit_shield`, `sound_level_up`,
`sound_loot_pickup`, `sound_magnus_start`, `sound_melee_hit`, `sound_woosh`.

**Why the pack does not read as made for Gnipahellir:** the folder came over from
Gnipahellir2 (633421b). Its names follow class prefixes and abilities this game
does not have, such as `sfx_dr_twirlingrose`, `sfx_sr_rabbitsnare`,
`sfx_ar_pet_primary_attack`, `sound_hit_ally_nonlocal`, `sound_dps_display` and
`sound_magnus_start`. No tag names the pack or who assembled it.

**Third-party tags (23 of 199 files have a tag; 9 name a library or maker):**

| File | Tag says |
|---|---|
| `sound_cooldown_finished_l`, `sound_loot_pickup` | Metal Sweeteners, Gun Hyper-Realism |
| `sound_dialog_next` | Paperlife SFX Pack |
| `sound_horror_ambience` | klankbeeld 2016, freesound.org |
| `sound_menu_cursor` | Epic Stock Media, 2017 |
| `sound_purchase` | Heiko Lohmann / The Sound Pack Tree, "All rights reserved" |
| `sound_slice` | Rock The Speakerbox, 2018 |
| `sound_store_open` | Articulated Sounds, 2017 |
| `sound_upgrade_hit` | pmsfx.com, 2018 |

The other 14 tagged files name no maker. Most carry only a date and an editor
such as Pro Tools or REAPER, which shows a session and not a licence.

### Text players read

| Asset group | Ships? | How it was made | Evidence | Licence | Status |
|---|---|---|---|---|---|
| Item names and descriptions, `src/gen_items.odin` (including the Scroll of Waters lore) | Yes | Agent commits | 12 of 12 commits have a Claude co-author | Game text | **Agent** (questions 4, 6) |
| Terrain descriptions, `src/gen_terrain.odin` | Yes | Agent commits | 13 of 13 commits have a Claude co-author | Game text | **Agent** (questions 4, 6) |
| Buff text, `src/buffs.odin`; prompts, notifications and logs across `src` | Yes | Mixed, not separated per line | `items.odin` 27 of 37 commits have a Claude co-author | Game text | **Agent** (questions 4, 6) |
| Names from Norse myth (Garm, Draugr, Gnipahellir) | Yes | Public-domain myth | None needed | Public domain | Clear |

### Tools

`tools/gnipa_studio` is an editor and does not ship. What it writes is counted
above. `pixel_style.md` still has an image-generation prompt template for new
concept sheets, which conflicts with the goal if it stays in use.

## Glenn to confirm

1. **`splash_bang_pop`:** where did you get it, and do you hold a licence or
   receipt that allows it in a paid game? If you don't, those 18 sounds need
   replacing whatever their maker. Did you mean to use it only as a placeholder?
2. **Tile and item sheets:** did `gnipahellir_tile_spritesheet.png` and
   `gnipahellir_item_spritesheet.png` come from your own hand or from a tool?
   Was `sprites/prompt.md` (deleted in 190a876) used to make these atlases or
   only to extend them later? Git calls the tile sheet yours, but the tile atlas
   is on screen all game, so this needs your word.
3. **Chest, Bench, Builder:** do you agree these count as AI-made because they
   were translated from the gpt-image concepts? Recommendation: yes, replace
   them and the Draugr that reuses the Builder frame.
4. **Agent-written art and text:** does "no AI" cover sprites, grids and text
   that Claude wrote as code? Recommendation: yes. A sprite grid is art even
   when it sits in a source file, and `steam_research.md` says AI-made sprites,
   lore and in-game text must be disclosed; only code itself seems exempt. If
   you agree, this is most of the game's art and text, so the replacement scope
   is far larger than the three concepts. Decide before hiring.
5. **Your own pixels:** which sprites did you draw yourself, in the studio or
   the editor? Name them and they move to Clear. Did you draw the Gnipahellir2
   mage that the player sprite started from?
6. **Your own words:** which item, lore or terrain lines did you write yourself?

## Step 2, after the answers

Each row still marked AI, Agent or Rights open is replaced by a human artist or
by Glenn, per his call, and gets its maker and licence recorded here.
