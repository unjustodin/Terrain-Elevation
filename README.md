# Terrain Elevation

A [Zenith](https://github.com/unjustodin/Zenith) add-on that draws hills under Factorio's flat
world: gentle rises and valleys, the ground sloping down to lakes and the sea, and Factorio's
cliffs as real steps, with the high ground on the side Factorio gives them.

**Drawn only.** Factorio itself stays flat: nothing this add-on does changes the game, and other
players see nothing of it. Zenith lifts everything it draws by the height under it: the ground,
buildings, belts and the items on them, ghosts, wires, icons and effects. The mouse and the camera
follow the hills.

Needs Zenith with add-on API 1.2 (`api.terrain`).

**Early and untried.** This first version hasn't been run yet. Expect rough edges (see below).

## Installing

Put this folder (or a zip of it) in Zenith's add-ons folder:

- Windows: `%APPDATA%\Godot\app_userdata\Zenith\addons\terrain-elevation\`
- Linux: `~/.local/share/godot/app_userdata/Zenith/addons/terrain-elevation/`

Then switch it on in Zenith's **Add-ons** menu.

## Settings

On its page of the Add-ons menu:

| Setting | Default | |
|---|---|---|
| Hills | on | Draws the hills |
| Hill height | 4 tiles | The highest they rise. Keep it low: belts and rails tilt with the ground |
| Hill size | 160 tiles | How wide a hill is; wider is gentler |
| Small bumps | 0.35 | Little rises and dips on top |
| Flat ground by water | 24 tiles | How far from water the ground slopes down to the water's level |
| Cliff height | 2.2 tiles | How much higher a cliff's high side is (0: cliffs just sit on the hills) |

## How it works

`main.gd` reads, a few chunks a frame, where the client's loaded chunks have water and cliffs
(`api.terrain.chunk_kinds`, `api.terrain.cliffs_in_chunk`). When that or a setting changes, or
the camera moves far, `scripts/heights.gd` works out a new height field on a worker thread: a
grid of 768 x 768 heights, 2 tiles apart, round the camera's focus (1,536 tiles across):

- **Hills:** fractal noise over the map, seeded by the save and planet, so a spot always has the
  same height.
- **Cliffs:** terraces. Near the cliffs the ground blends every cliff round it (which side it is on), so a chain
  of pieces makes one smooth edge; further out the high side stays high, so a ring of cliffs stands up as a
  plateau, and past the end of a line the step ramps back down. The rock sits on the low ground and the high
  ground stays level right up into it, so the rock's face is the drop (Cliff height, 2.2 tiles by default).
- **Water:** everything eases down to 0 near water, so lakes keep their level.
- **Edges:** the grid fades to flat at its border.

It hands the grid to Zenith with `api.terrain.set_heights`, and Zenith's shaders lift every
vertex by it.

## Known gaps

- The hills don't come from Factorio's own elevation (the noise Factorio places water and cliffs
  by), so they don't follow the map's real shape; cliffs only get steps where they are.
- Buildings follow the slope rather than sitting on levelled pads.
- When new water or cliffs load, the hills there change at once rather than blending.
- Some things Zenith draws on the CPU still sit at the old height: the character's lights,
  health bars, selection boxes, Alt-mode's screen icons, lamps' lights.
- Off on space platforms.

## Licence

MIT (LICENSE). Zenith's add-on exception lets add-ons that use only its API pick their own licence.
