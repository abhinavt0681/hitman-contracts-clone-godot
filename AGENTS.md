# Notes for contributors and AI agents

Read `README.md` first. The format knowledge lives in `docs/` (copied from the Bevy project)
and in `tools/glacier-export/src/glacier/` (the readers).

- **No game content in git:** `data/`, `game/imported/` and `game/.godot/` are ignored.
  Regenerate `game/imported/` with the exporter.
- **Conventions:** exported glTF uses the Bevy project's world axes (Y up, metres; Glacier's Z
  mirrored). Characters have the mirror folded into their data (see
  `tools/glacier-export/src/character.rs`), so roots are clean rotations and scales. Every
  character's glTF root is named `Character`, so animation libraries fit any model.
- **Collision:** nodes named `Collision_N-colonly` become static concave bodies on import.
- **Atmosphere over performance:** never thin the snow, fog or lights for frame rate unless
  asked. The look is a dark night blizzard, teal and blue-grey with sodium lamp pools.
- **Look, don't assume:** check changes with `HITMAN_SCREENSHOT` renders (see the README).
- **GDScript:** typed, code-first. `scripts/main.gd` builds the world, `player.gd` is 47,
  `actors.gd` the characters, `blizzard.gd` + `shaders/snow_*.gdshader` the snow (see
  `docs/BLIZZARD.md`), `soundscape.gd` the wind and score.
- **Additive surfaces:** the exporter names materials with render-state bit `0x2` `…_add`;
  `main.gd` swaps them for `shaders/additive.gdshader`, which fogs them toward black (fogging
  them toward the fog colour draws every glow card as a box).
- **Height maps:** the exporter writes `C02-1_heights.bin` (top surface and snow shelter per
  0.5 m). Re-export when collision changes.
- **Lights:** `0x800023` entities are spots aiming along their local X (`SpotLight3D` with
  soft shadows and volumetric shafts); `0x800024` omnis are fill. Their property blobs are
  empty, so colour, angle and range come from names (`TunnelLamp`, `NeonTurquoise`, `Fspot`)
  and are set by eye. `Omni_Explosion` / `Omni_Reticle` are effect lights and stay off.
- **Glow sprites:** `GlowVol` (stacked lamp-cone discs), `GlowRain`, `Glow` and the beacons
  are camera-facing in the engine; `additive_glow.gdshader` restores that, with soft edges.
- **Doors** (`scripts/doors.gd`): each leaf an `AnimatableBody3D` at its hinge, built *before*
  entering the tree with `sync_to_physics = false` (a synced body moved after entering snaps
  back). Single doors use the level's placement; double doors are re-hung from the jambs found
  by rays and stretched to the opening (the level's own placement stands some across it).
  `HITMAN_DOOR_LIST`, `HITMAN_DOOR_PROBE`, `HITMAN_DOOR_ASIS` for debugging.
- **Ladders** (`scripts/ladders.gd`): ported from the Bevy project, guides from the exporter's
  `C02-1_ladders.json`; `Climb_Ladder` has its root motion stripped and is posed by hand.
- **Steam** (`scripts/steam.gd`): the original's static steam cards (`FC005_Steam…`) are hidden
  and replaced by GPU particle plumes plus a small lit fog volume; sources have `stop()` and
  `cool(seconds)` for when dishes are taken or eaten.
- **Interaction:** E is the `interact` action; offers set `player.prompt`; `HITMAN_KEYS="E@2"`
  taps it in scripted runs.
- **Transparent draw order:** shader-placed meshes (the snow) need an explicit
  `render_priority`; their bounds don't give Godot a meaningful sort distance.

## Next steps

Guard AI and patrols (routes are in the level's GMS), weapons, the HUD, dialogue scenes,
ladders, ragdolls (Godot has Jolt built in), the mission flow, and the script VM. The Bevy
project's code is the reference for each.
