Create a pixel-art sprite atlas for my game "Gnipahellir" (Odin + Raylib).

STYLE (match existing atlases):
- Chunky retro pixel art, flat colors, no gradients/anti-aliasing
- Each sprite built from an 8x8 "cell" grid (or similar) using a base
  fill color + 2 shading layers (darker/lighter) scattered across cells
  for texture, plus small accent details (veins, cracks, sparkles,
  grain lines) where relevant
- Consistent lighting: shading implies texture, not a light source

CONTENT NEEDED:
- [list what you want, e.g. "5 grass tile variants, 3 dirt variants,
  air/void, and a graveyard headstone item"]
- Match existing palette family where the new sprite overlaps a category
  already established (stone = grays/browns, wood = warm browns,
  ore = stone-grey base + colored vein + white sparkle, liquids =
  saturated base + dark cracks + bright highlight)

WORKFLOW:
1. First show me an inline SVG preview (via the visualizer) so I can
   sign off on the look before you generate final files
2. Once approved, rasterize to a real PNG atlas using Pillow:
   - Uniform grid, one cell size for the whole atlas (say what size,
     e.g. 80x80 per tile or 96x96 per item — match my existing atlases
     if this is an addition to them)
   - RGBA, transparent background, no anti-aliasing (nearest/hard edges)
   - No padding between cells unless I ask for mipmap-safe padding
   - Save to /mnt/user-data/outputs/
3. Also output a manifest JSON alongside the PNG: array of
   {name, x, y, w, h} for every sprite, using snake_case names
4. If this extends an existing atlas, pack new sprites into any empty
   slots first, then append new rows — keep the column count consistent
   with the original atlas so old UV coordinates don't shift

Tell me before generating: what's the target cell size, and is this a
new atlas or an addition to an existing one?
