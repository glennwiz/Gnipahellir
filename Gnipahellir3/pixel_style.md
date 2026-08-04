# Gnipahellir Pixel Style

This is the preferred visual direction for future Gnipahellir art. The blueprint
chest is the current in-game reference: compact Norse pixel art with a strong
silhouette, dark contour, warm materials, and carefully placed highlights.

The tree and player experiments from 2026-08-04 explored this same direction but
were reverted. Reuse the style described here when revisiting them; do not assume
their old render implementations should be restored unchanged.

## Core look

- Crisp 16-bit-inspired pixel art with hard square pixels.
- Heavy, near-black outlines around the outside silhouette.
- Compact shapes that remain readable at normal gameplay zoom.
- A limited palette with two or three deliberate shades per material.
- Warm highlights against deep, slightly cool shadows.
- Small bright glints used sparingly on important edges, rivets, eyes, runes, or
  polished metal.
- Stepped curves and uneven silhouettes instead of smooth vector curves or large
  rectangular blocks.
- Norse character without excessive decoration: iron straps, carved wood, fur,
  leather, runes, knots, sturdy proportions, and weathered surfaces.

The result should feel handcrafted and substantial, not flat, noisy, cute, or
photorealistic.

## Pixel and scale rules

- The world grid uses 10x10-pixel terrain cells. Collision and art do not need to
  share the same silhouette.
- Small objects may visually spill a few pixels beyond their collision cell when
  that creates a better shape. Draw them in a later render pass so neighboring
  terrain cannot crop them.
- Keep gameplay objects readable around 16-32 screen pixels tall or wide.
- Build detail from pixel clusters, not isolated one-pixel noise.
- Use one logical pixel as the normal outline thickness at the asset's intended
  resolution.
- Scale with nearest-neighbor filtering only. Do not use antialiasing, blur, or
  smooth resampling.
- Animation should preserve the silhouette and palette. Prefer a few strong poses
  over many weak in-between frames.

## Shape language

### Silhouettes

- Start with a recognizable solid silhouette before adding interior detail.
- Use broad masses connected by stepped transitions.
- Break symmetry slightly so natural and worn objects do not look manufactured by
  a tile grid.
- Avoid perfectly square crowns, straight post-like trunks, featureless boxes, and
  characters made from uniform rectangles.
- Keep interactive objects visually grounded with feet, roots, corner blocks, or
  a dark lower edge.

### Outlines

- Use a very dark brown-charcoal rather than pure black when possible.
- Outline the complete object, not every internal pixel or tile.
- Use interior dark lines only where they separate materials or important forms.
- Let adjacent parts merge when they belong to the same mass, such as connected
  foliage or stacked trunk sections.

### Lighting

- Default light direction: upper-left/front.
- Put the brightest material edge on the upper-left or on a polished focal point.
- Keep lower and right-facing areas darker.
- Highlights should describe the form: a curved lid, rounded trunk, helmet dome,
  leaf clump, or stone plate.
- Do not use global gradients. Construct light with discrete color bands and pixel
  clusters.

## Material recipes

### Wood

- Dark umber outline.
- Deep reddish-brown shadow.
- Warm chestnut body.
- Amber-orange edge highlight.
- Add short grain marks, knots, or panel seams; avoid evenly repeated stripes.
- Trunks and branches should taper and fork. Chests and structures should feel
  thick, joined, and reinforced.

Reference chest colors:

- Outline: `#181418`
- Dark wood: `#4A2718`
- Mid wood: `#7E4424`
- Wood highlight: `#AE6636`

### Iron and steel

- Charcoal outline and deep blue-gray shadow.
- Mid gray body with a small cool highlight.
- Bright silver should occupy very little area.
- Use straps, rivets, rims, and corner plates to show construction.
- Metal highlights should be sharper than wood highlights.

Reference chest colors:

- Dark iron: `#363840`
- Iron highlight: `#6C707A`

### Foliage

- Deep blue-green or forest-green outer shadow.
- Mid fern green for the main mass.
- Mossy yellow-green on upper-facing clusters.
- Build crowns from overlapping stepped clumps so the outside edge is irregular.
- Avoid outlining every leaf tile; connected foliage should read as one crown.

### Stone

- Warm or neutral gray body with a dark brown-charcoal contour.
- Use broad plates and cracks rather than random speckles.
- A magical stone object may carry one restrained amber, teal, or violet glow.
- Put bright chips on upward edges and deeper shade between plates.

### Cloth, leather, fur, and skin

- Cloth uses a dark base, one body color, and one folded-edge highlight.
- Leather leans warm brown with dark seams and small brass fasteners.
- Fur uses an uneven stepped edge with a few pale tips, not dense noise.
- Skin should be warm and readable against hair, helmets, and hoods.
- Character faces need only a few strong pixels: brow, eyes, beard/mask edge, and
  one highlight.

### Magic and runes

- Give each magical object one dominant accent color.
- Surround the accent with a dark socket or plate so it remains readable against
  bright terrain.
- Use a tiny near-white core only at the brightest point.
- Glow is an accent, not a wash over the whole object.
- Rune shapes should be angular, simple, and legible at the final size.

## Palette discipline

- Prefer four to six colors for a simple object, plus one optional magic accent.
- Reuse the same outline color across related assets.
- Shift shadows slightly cooler/darker and highlights slightly warmer rather than
  only multiplying brightness.
- Reserve pure white for tiny glints and magical cores.
- Avoid full-saturation colors across large areas.
- Check the silhouette and value contrast in grayscale; the asset should remain
  readable without relying only on hue.

## Procedural-rendering guidance

Concept art is a visual target, not necessarily a sprite that ships directly.
When translating it into Odin drawing code:

1. Draw the backdrop or clear the owning terrain cell.
2. Draw the complete dark silhouette.
3. Fill the main material masses.
4. Add one shadow plane and one highlight plane per material.
5. Add only the identifying details needed at gameplay scale.
6. Draw glints, rivets, eyes, and runes last.
7. Keep the pass read-only; visual polish must not change collision, mining,
   storage, animation timing, or save data.

For shapes spanning multiple cells, draw all backdrop cells during the terrain
pass and then draw the connected object once in an overlay pass. This prevents
tile boundaries and debug grid lines from cutting through the art.

Player-placed construction blocks may deliberately retain a square silhouette for
building clarity even when natural versions of the same material use an organic
render pass.

## Character direction

Playable forms should share the same outline weight, proportions, and lighting,
while one or two details identify each form:

- Wizard: pointed hat, dark band, rune clasp, layered robe.
- Dwarf: stocky helmet, strong beard mass, beard ties, heavy belt.
- Ranger: hood opening, cloak clasp, layered leather and cloth.
- Viking: helmet or horn silhouette, fur shoulders, beard, round belt boss.
- Knight: cool steel plates, narrow dark visor, restrained gold trim.
- Golem: broad stone plates, cracks, small amber rune core.
- Plague Doctor: broad hat, dark coat, ivory beak, one luminous goggle.

Keep equipment overlays readable and separate from the body. A held pickaxe, wand,
or weapon should not destroy the character's base silhouette.

## Environment direction

- Trees: tapered knotty trunks, visible branch forks, stepped roots, and irregular
  overlapping crowns. Preserve clear harvesting/collision feedback.
- Chests: arched or stepped lids, warm oak panels, heavy iron reinforcement,
  corner rivets, and a single readable lock or rune accent.
- Machines: sturdy dark bases, clear material construction, and one animated focal
  point showing purpose or progress.
- Terrain: retain tile readability, but use clustered texture and connected
  silhouettes where the object represents a natural whole.

## Image-generation prompt template

Use the built-in image-generation path for future concept sheets. Save selected
project references under `sprites/` and translate them deliberately into the game
renderer.

```text
Use case: stylized-concept
Asset type: compact game pixel-art concept sheet for procedural rendering
Primary request: Design <subject> in Gnipahellir's richly shaded Norse pixel-art style.
Scene/backdrop: perfectly flat solid #ff00ff chroma-key background.
Style/medium: crisp 16-bit pixel art, hard square pixels, limited palette, heavy
dark brown-charcoal outline, warm material highlights, deep cool shadows, and
small bright glints. Strong compact silhouette readable around 16-32 pixels.
Materials/textures: weathered oak, dark iron, leather, fur, carved stone, or
layered foliage as appropriate; two or three deliberate shades per material.
Composition/framing: isolated full object, generous padding, no overlap.
Constraints: no text, no environment, no floor, no cast shadow, no antialiasing,
no blur, no watermark, uniform background, no magenta in the subject.
Avoid: flat single-color blocks, square natural silhouettes, smooth vector edges,
photorealism, excessive pixel noise, oversized details.
```

When matching the blueprint chest specifically, use
`sprites/blueprint_chests_concept.png` as the style reference.

## Acceptance checklist

- Reads clearly at normal gameplay zoom.
- Strong silhouette before interior detail.
- Consistent near-black outline.
- Two or three shades per material.
- Upper-left light and lower-right shadow are coherent.
- No smoothing, gradients, blur, or random noise.
- Norse details support the object rather than clutter it.
- Magic uses one restrained accent color.
- Visual spill does not alter collision or interaction behavior.
- Character-select, world, inventory, and preview versions remain stylistically
  consistent when the same asset appears in multiple places.

