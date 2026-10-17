# Escape from Canuckov (Roblox) art brief

Canonical visual brief for the native Roblox build. Other documents point here.

## Authority

| System | Authority | Notes |
| --- | --- | --- |
| World layout, colliders, scale, spawns, loot, exits | Web build decoded data (`src/world/levels/ground_zero.json`) | 1:1 positions and sizes, meters -> studs at the fixed ratio below |
| Gameplay, 3C, timings, values | Web build source (`src/entities`, `src/game`, `src/systems`, `src/game/gz/*.json`) | Game feel must match 1:1 |
| Look (palette, materials, lighting, UI language, VFX) | This brief (robloxification grammar, Canuckov theme) | Deliberately distinct from the web build's dark muted render |
| Characters | Beaver player, goose enemies (theme memory) | Blocky toy rigs, same silhouettes and proportions as the web models |

The robloxification reference frames in the skill pack are not available locally (Git LFS pointers), so the
palette below is the skill's documented starting swatches adapted to Canuckov. All numbers are proposed
defaults until checked in the Studio renderer.

## Units

1 m (web) = 3.5 studs (proposed). The web beaver is 1.107 m tall -> 3.9 studs, close to a short R15 avatar, so
Roblox default physics, jump and camera scale stay sensible. Every distance, speed and range converts with the
same factor; time values are unchanged.

## Look in one line

A bright plastic Canadian wilderness: lime studded meadows, warm sand paths, cyan river, chunky toy pines and
log cabins, in which raids still read as dangerous. Danger comes from coral/red accents, honking goose squads
and the storm's purple wall, not from dark grading.

## Palette roles (proposed sRGB)

| Role | Swatch | Use |
| --- | --- | --- |
| Meadow lime | `#80DE25` | Main ground, safe open grass |
| Meadow variation | `#68C91F` | Checker variation, grass tufts |
| Forest green | `#2F9E3A` | Pine canopies, dense woods |
| River cyan | `#13D5F4` | River surface |
| River depth | `#079BD7` | River banks/secondary planes |
| Trail sand | `#DFC988` | Paths, camp clearings, farm yard |
| Sand variation | `#D0BA78` | Tile alternation |
| Log brown | `#8A5A2B` | Cabins, fences, crates, beaver fur base |
| Bark dark | `#5A3A1E` | Trunks, structural contrast |
| Maple red | `#E8322E` | Canuckov accent, danger, enemy health |
| Danger coral | `#F34543` | Warnings, damage, hostile markers |
| Storm violet | `#9938F2` | Storm wall, extraction beacon glow, rare loot |
| Reward gold | `#FFD83D` | Rare loot, level up, money |
| Money green | `#50FF19` | Cash/gain text (black outline) |
| Concrete | `#B9BCC4` | Container yard, shelters, walls |
| Ink | `#16151D` | UI stroke, signs |
| Toy white | `#FFF8E9` | Canopies, goose body, UI fill |

Each view keeps two or three dominant families (lime + sand + one structure colour). Props get a body colour,
a neutral and one accent.

## Materials

- Ground and big flat surfaces: `Enum.Material.Plastic` with world-aligned studs via a shared `Studs` texture
  on top faces only (fixed pitch of 1 stud per stud tile, never stretched per part). Walls and props smooth plastic.
- Wood: `Enum.Material.Wood` is too realistic at gameplay distance; use Plastic in log brown with a darker
  top-edge strip instead.
- Metal (cars, containers): `SmoothPlastic` with a broad colour and one darker band. No `DiamondPlate`/`Metal`.
- Water: `SmoothPlastic` cyan slab, slight transparency 0.15, with a white foam strip at the banks. No Terrain water.
- Neon only for power and objectives: beacon pad, extraction column, muzzle flash core, rare loot glint.

## Lighting

`Lighting.Technology = Future`, ClockTime driven by the raid clock (day / dusk / night from the web game).
Day: bright blue sky, `Brightness 2.5`, soft `OutdoorAmbient (140,140,150)`, light `Atmosphere` density 0.25
for depth only. Night: navy sky, not black; the player's view cone stays readable. Storm: violet colour
correction and the purple storm wall. No brown grading, no heavy bloom.

## Shape language

Broad cuboids, wedges and cylinders with clear toy silhouettes. Pines are stacked green wedges/cones on a
brown trunk. Cabins are log stacks with a red roof. The goose: white/grey body, black neck, white cheek
patch, orange beak and feet, with gear colour swaps per preset (as in the web PREFAB_LOOKS). The beaver:
brown chunky body, tan belly, big front teeth, flat paddle tail. Identity-bearing secondary forms (tail,
beak, teeth, cheek patch) are enlarged rather than detailed.

## UI language

Chunky rounded display font (`Enum.Font.FredokaOne` / `GothamBlack` fallback), white fill with a 2-3 px
near-black `UIStroke`. Health uses a maple-red plate, hydration cyan, energy gold, stamina lime ring.
Hotbar slots are rounded toy plates with thick dark borders and numbered keycaps. Interaction prompts are
white pill plates with a keycap (F). Keep the web HUD's layout and states; restyle only.

## VFX grammar

White core, coloured body, timed expansion, clean decay. Muzzle flash: white core + gold rays, 2 frames.
Bullet tracer: bright yellow-white beam, 0.06 s. Hit: white star + coral chunks. Goose death: feather puff
(white squares) + coin-pop of loot. Extraction: violet column with rising rings, then a white flash.
Storm: violet wall with vertical streaks. Effects stay local; no screen-wide haze.

## Forbidden drift

Dark/desaturated grading copied from the web build; realistic textures (Grass, Wood, Brick materials);
neon on ordinary props; tiny details that vanish at the top-down camera; generic graybox props called
finished; studs stretched across scaled parts.

## Approved anchors

None yet. After the first Studio pass, record the spawn view and the extraction effect here as the
drift-comparison frames.
