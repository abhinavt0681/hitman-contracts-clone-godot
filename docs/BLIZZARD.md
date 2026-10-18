# The blizzard

How Hitman: Contracts draws the Bjarkhov Bomb's snow, and how `game/scripts/blizzard.gd`
rebuilds it. Findings come from the level data (`C02-1_MAIN.GMS` properties), the exe's
embedded snow vertex shader and its particle code (Ghidra), and gameplay footage.

## The original

### Level data

| Entity | Class | What it holds |
|---|---|---|
| `Snow_Flakes_Base` [7910] | `0x2000e2` ZParticleBox | vSize (100, 100, 100), vSpawnMul (0.7, 0.6, 0.8), **vSpawnAdd (5, −1, 0)**, fSpeedScale 3, lNrParticles 1000, fParticleSize 1.5, fParticleDepth 1000, texture `FX_Snow_01a` |
| `Snow_Flakes_Airport` [7911] | `0x2000e2` | the same, but vSpawnAdd **(−5, −0.5, 0)** |
| `Snow_Box_Base` [7909], `Snow_Box_Airport` [7912] | `0x2000e8` | zones (polygon data, not decoded yet) choosing which flakes apply where |
| particle controller [9534] | `0x2000e4` | `rParticleBox`, `Alpha` 255, `Color` 0xA0A0A0 (flat grey; its stored block is 6 bytes, so the class defaults apply) |

The schema defaults: vSize (100, 100, 100), vSpawnAdd (0, −1, 0), fSpeedScale 0,
lNrParticles 1000, fParticleSize 10, fParticleDepth 2000.

Textures: `HMC_FX_Snow_01a` at 128×128 (TEX id 415) and a 64×16 elongated streak (id 471).

### The vertex shader (`vssnow`, vs_1_1, disassembled with `tools/re/vsh_disasm.py`)

- A particle's position is a trilinear blend of a box's 8 corners (c4–c11) by its stored
  0..1 coordinates, so the CPU only moves 0..1 values and the box is placed around the view.
- Screen-aligned quads: the corner offset is added in clip space, so they shrink with
  distance.
- Particles beyond c14.x (fParticleDepth: 1000 = 10 m) get a zero size: **no flakes past
  ~10 m**.
- One constant colour (c13: the controller's colour and alpha); linear fog.

### The CPU update (Ghidra)

| What | Where |
|---|---|
| Per-frame update: position += velocity × dt; each axis wraps at ±1.0 (`DAT_0070e418`) | `FUN_0044a150` |
| Wrap history (3 bits) and the visibility mask over a 3×3×3 block of tiled boxes | `FUN_0044a0b0`, `FUN_00449ff0` |
| dt = frame time × 60 (`DAT_00712914`) | `FUN_0044a0e0` |
| Velocity seed: three randoms in −1..1 (`FUN_0044a4d0`), scaled (likely by vSpawnMul, `FUN_0061d7b0`), plus vSpawnAdd (+0x50..+0x58) | `FUN_0044a3e0` |
| Up to 4 boxes drawn per frame (0xa0 stride) | `FUN_0044a110` |

### What it adds up to

Flakes only within ~10 m, as thin grey streaks all moving one way: sideways five times faster
than they fall, with a little spread. The base and the airfield blow in opposite directions.
Everything farther away is fog plus the additive cloud cards (`HMC_FX_Clouds_01a`, the
"Blowing FogLarge/Huge" and `SnowBlowing` entities 20–80 m up, `Snow_Fog_Emitter`), and
`SnowGlitter` patches on the ground.

Gameplay footage (720p) agrees. Streak orientation, measured with a structure tensor over
outdoor frames, peaks within ~10° of horizontal. The haze at the horizon is ≈ (0.16, 0.26,
0.29) sRGB, and the snow ground ≈ (0.13, 0.23, 0.27).

## The rebuild

The original's method, with more of it:

- **Streaks** (200,000 in a 40 × 16 × 40 m box, one layer). As in the original, flakes keep
  fixed random spots in a box that wraps around the camera and slides with the wind, so
  nothing pops. Every edge of the box fades softly; past ~10 m the fog takes over. Wind
  (12, −2.4, 0) m/s keeps vSpawnAdd's direction and 5 : 1 ratio; the speed is set by eye.
  Spread (±1.68, ±1.44, ±1.92) m/s is vSpawnMul on the same scale. The colour is the
  controller's grey, cooled. Each streak runs from the flake back along its velocity × a
  45 ms "shutter", at least 1.2 px wide (thinner ones fade rather than fatten).
- **Sheets and powder:** faint noise cards riding the same wind (the original's cloud cards,
  done as in the Bevy project's `veil.wesl`). They stand on the ground under the camera and
  are clipped by buildings per pixel.
- **Squalls** every 18–40 s, lasting 3–8 s: the wind ×1.6, streaks and sheets thicker, the fog
  closing in, the wind sound up 6 dB.
- **Lamps** light the flakes and sheets near them (the 16 nearest).
- **Shelter:** the exporter's `C02-1_heights.bin` stores, per 0.5 m cell, the top surface and
  the lowest height snow reaches. A covered cell lets snow in only if it sees the sky: 3 of
  16 rays from 1 m above its floor, tilted 15° and 35° up, get out. Open patches narrower
  than ~2 m are dropped (rays leak through seams in rock). Snow stays out of hangars, the
  plane's hold and tunnels, even deep in a straight tunnel; under the wing it still snows. The
  camera's own shelter thins the fog and muffles the wind (−14 dB, low-pass to 450 Hz).
- **Drifting fog** (`shaders/drifting_fog.gdshader`): a fog volume around the camera with
  3D noise banks carried by the same wind, thickest near the ground, glowing faintly like the
  original's additive cloud cards, absent indoors. Thicker in squalls.
- **Grade:** the fog is the footage's haze, a shade darker. Ambient light is low enough that
  the snow reads dim blue-grey, as in the original.

## Mistakes not to repeat

- **Draw order.** The snow meshes' centres mean nothing (the shader places every flake), so
  Godot's distance sort drew them before the level's alpha-blended snow layers on the ground,
  which then erased the streaks in straight-edged patches. The snow materials have the
  highest `render_priority`.
- **Layers of different density.** A dense near layer and a sparse far layer showed a hard
  ring where they met. Keep one even layer.
- **Lee shelter.** Casting rays upwind to hide flakes in the lee of every obstacle sliced the
  snow at flat heights along cell edges. Only enclosed spaces hide snow now.
- **Level rays for enclosure.** Counting walls in 8 level directions let snow deep into a
  straight tunnel (its ends are open). Look for the sky instead.
- **Per-card hiding.** Hiding or lifting a whole 20 m sheet by what's under its centre made it
  pop.

## Open

- Decode the `Snow_Box_*` polygons and give the airfield its reversed wind; for now the
  base's wind blows everywhere (`WIND` in `blizzard.gd`).
- Confirm `FUN_0061d7b0` and the box corners' placement (c4–c11), which would give the
  original's true flake speed.
- `SnowGlitter` patches.
