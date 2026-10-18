# Hitman: Contracts — The Bjarkhov Bomb, in Godot

A Godot 4.7 rebuild of *Hitman: Contracts*' Bjarkhov Bomb (scene `C02-1`), made from the
original game's own data. Sister project of the Rust/Bevy clone in `../hitman-clone`, whose
reverse-engineered format readers it reuses.

Not affiliated with IO Interactive or Square Enix; no game content is in this repository.
You need your own copy of Hitman: Contracts.

## How it fits together

1. **`tools/glacier-export`** (Rust) reads the original files from `data/` and writes what
   Godot imports natively into `game/imported/`:
   - `level/C02-1.glb`: the whole level (4,325 placed meshes, 902 models, the original
     textures and baked vertex lighting), plus collision Godot turns into static bodies.
   - `level/C02-1_markers.json`: every entity's name, class and position (lamps, triggers…).
   - `characters/`: 47 with all 228 of his clips, the 56 characters with their models, and the
     animation sets as shared libraries; `actors.json` places them.
   - `sounds/`: the score, wind, footsteps, voices and effects (643 files).
2. **`game/`** is the Godot project: GDScript, code-first (scenes are minimal).

## Running it

Copy `Scenes/` and `streams.wav` from your Hitman: Contracts install into `data/`, then:

```sh
cd tools/glacier-export && cargo run --release        # writes game/imported/
cd ../../game && godot --headless --import && godot   # import, then play
```

Controls: mouse to look (click to capture, Esc to release), WASD, Shift to run, Ctrl to sneak.

## What's there

- The level, lit by its 369 lamps (sodium outdoors, fluorescent under roofs), in volumetric fog,
  with the original's additive glows and light cones.
- The blizzard, rebuilt from the original's snow system (`docs/BLIZZARD.md`): 200,000 streaks
  driven almost flat by one wind, faint blowing sheets and ground powder, squalls every half
  minute; it snows under the plane's wing but never indoors.
- 47 in third person with the original animations, playback matched to his speed, and
  footsteps timed to his feet touching down (snow or concrete). He walks up stairs and over
  kerbs and humps up to 0.45 m.
- The base's 56 characters at their posts, playing their original idles.
- Wind and Jesper Kyd's score.

`media/demo_walk.mp4` is a 14-second capture made with Godot's movie writer;
`media/blizzard.mp4` a 20-second walk through the storm.

## Testing without a human

The same environment variables as the Bevy project: `HITMAN_SCREENSHOT=out.png`
(with `HITMAN_SHOT_FRAME`), `HITMAN_CAM="x,y,z,tx,ty,tz"`, `HITMAN_START`, `HITMAN_YAW`,
`HITMAN_AUTOWALK=secs@start`, `HITMAN_AUTORUN`, `HITMAN_NO_SNOW`, `HITMAN_TRACE`, plus
`HITMAN_GUST=0..1` (hold a squall) and `HITMAN_SNOW_LAYERS=streaks,sheets,powder`, `HITMAN_SNOW_DEBUG` (sheltered flakes in red). Video:
`godot --write-movie out.avi --fixed-fps 30 --quit-after 420`.
