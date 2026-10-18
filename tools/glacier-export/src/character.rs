//! Characters as skinned glTF: model, skeleton (bone names as in the original: `PELVIS`,
//! `RIGHT_HAND`, …) and animation clips.
//!
//! Glacier character data is mirrored relative to ours (`P`, a swap of X and Z, plus the
//! level's Z mirror), and Godot's skeleton import dislikes mirrored (negative-scale) roots. So
//! the mirror `F = diag(1, 1, −1)` is folded into the data instead: positions `F·P(v)`, bone
//! rotations `F·R·F` (quaternion `(z, y, −x, w)` from the stored `(x, y, z, w)`), and the root
//! becomes `instance·F`, a proper rotation and scale.
//!
//! Looping locomotion clips (walk, run, sneak, idles) drop the `GROUND` root track so they play
//! in place and the game moves the character; one-off clips (deaths, kills, climbing) keep it.

use crate::{
    Materials,
    gltf::{Gltf, Primitive},
};
use anyhow::{Context, Result};
use glacier_export::glacier::{
    anm::{self, Animation},
    level::Level,
    skin::SkinnedModel,
};
use glam::{Mat4, Quat, Vec3};
use serde_json::json;
use std::path::Path;

/// Stored bone/track rotation `(x, y, z, w)` → ours.
fn rot([x, y, z, w]: [f32; 4]) -> Quat {
    Quat::from_xyzw(z, y, -x, w).normalize()
}

/// Stored position (cm) → ours.
fn pos([x, y, z]: [f32; 3]) -> Vec3 {
    Vec3::new(z, y, -x)
}

const F: Mat4 = Mat4::from_cols_array(&[1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 0.0, 1.0]);

/// Clips that play in place (the game moves the character).
/// Clips whose `GROUND` translation is dropped: loops the game moves through the world itself,
/// and `Climb_Ladder` (the ladder code lifts 47 at the clip's own 0.5 m per 23-frame stroke).
fn in_place(name: &str) -> bool {
    ["Walk", "Run", "Sneak", "Crouch", "Stand", "Drag", "Idle", "Ambient", "UB_", "Climb_Ladder"].iter().any(|k| name.starts_with(k) || name.contains("_Loop"))
}

pub fn export(level: &Level, _world: &crate::World, out: &Path) -> Result<()> {
    // 47: the `Ground` child of the `Hitman2` template carries his model.
    let (template, prim) = level
        .entities
        .windows(2)
        .find(|w| w[0].name == "Hitman2" && w[1].name == "Ground")
        .map(|w| (&w[0], w[1].primitive))
        .context("no Hitman2 template")?;
    let model = level.prm.skinned_model(prim)?;
    let hero = level.anm.sets.iter().find(|s| s.path.ends_with("Hero.anm")).context("no Hero.anm")?;
    let mut clips: Vec<&Animation> = hero.animations.values().collect();
    clips.sort_by(|a, b| a.name.cmp(&b.name));
    // The template's own orientation, turned to face −Z, with the mirror folded in.
    let root = crate::instance_transform(template.rotation, [0.0; 3]) * Mat4::from_rotation_y(std::f32::consts::PI) * F;
    write(level, &model, &clips, root, "Hitman", &out.join("hitman.glb"))?;
    tie(level, out)?;
    actors(level, out)?;
    Ok(())
}

/// How far in front of his centre line the knot sits beyond the mesh's own offset (cm), and how
/// far the hanging tie leans forward over his chest (per unit down): the Bevy project's values.
const KNOT_OUT: f32 = 2.0;
const TIE_LEAN: f32 = 0.44;

/// 47's tie (`tie.glb`, `tie.json`). The original keeps it out of the suit's mesh: it's its own
/// object (`Tie`, class 0x2000FF, in the `Hitman2_Tie` group), authored jutting out at 45° from
/// the knot and simulated (gravity and three collision planes lay it on his shirt). As in the
/// Bevy project, it's hung at rest instead: the mesh is written with its knot (the mean of its
/// top vertices) at the origin, hanging straight down (towards the mean of its bottom
/// vertices), its 6 cm width along X; `tie.json` says where the knot sits on 47 (height above
/// his feet and distance in front of his centre line, from the nearest `Hitman2` template's
/// offset) and how far it leans forward. `player.gd` hangs it from his chest bone.
fn tie(level: &Level, out: &Path) -> Result<()> {
    let Some(e) = level.entities.iter().find(|e| e.name == "Tie" && e.type_id == 0x2000ff) else {
        println!("tie: none in the level");
        return Ok(());
    };
    let d = |a: [f32; 3]| (a[0] - e.position[0]).powi(2) + (a[1] - e.position[1]).powi(2) + (a[2] - e.position[2]).powi(2);
    let template = level.entities.iter().filter(|t| t.name == "Hitman2" && t.position != [0.0; 3]).min_by(|a, b| d(a.position).total_cmp(&d(b.position))).context("no Hitman2 near the tie")?;
    let sm = level.prm.model(e.primitive)?.submeshes.into_iter().find(|s| s.in_lod0() && !s.is_proxy()).context("tie has no mesh")?;
    let local = |p: [f32; 3]| Vec3::from(crate::swap_xz(p));
    let (top, bottom) = sm.vertices.iter().fold((f32::MIN, f32::MAX), |(t, b), v| (t.max(v.pos[1]), b.min(v.pos[1])));
    let mean_of = |sel: &dyn Fn(f32) -> bool| {
        let vs: Vec<Vec3> = sm.vertices.iter().filter(|v| sel(v.pos[1])).map(|v| local(v.pos)).collect();
        vs.iter().copied().sum::<Vec3>() / vs.len().max(1) as f32
    };
    let (knot, tip) = (mean_of(&|y| y > top - 2.0), mean_of(&|y| y < bottom + 2.0));
    let frame = |length: Vec3, width: Vec3| {
        let a = length.normalize();
        let b = (width - a * width.dot(a)).normalize();
        glam::Mat3::from_cols(a, b, a.cross(b))
    };
    let r = frame(Vec3::NEG_Y, Vec3::X) * frame(tip - knot, Vec3::Z).transpose();
    let positions: Vec<[f32; 3]> = sm.vertices.iter().map(|v| (r * (local(v.pos) - knot) * 0.01).to_array()).collect();
    let normals: Vec<[f32; 3]> = sm.vertices.iter().map(|v| (r * local(v.normal)).normalize_or_zero().to_array()).collect();
    let uvs: Vec<[f32; 2]> = sm.vertices.iter().map(|v| v.uv).collect();
    let indices: Vec<u16> = sm.triangles.iter().flatten().copied().collect();
    let mut gltf = Gltf::default();
    let mut materials = Materials::new();
    let m = materials.get(&mut gltf, level, sm.texture, crate::blend_mode(sm.blended, sm.render_state));
    let mesh = gltf.mesh("Tie", &[Primitive { positions: &positions, normals: &normals, uvs: &uvs, colors: None, joints: None, weights: None, indices: &indices, material: Some(m) }]);
    let node = gltf.node(json!({ "name": "Tie", "mesh": mesh }));
    gltf.scene_roots = vec![node];
    gltf.write(&out.join("tie.glb"))?;
    let offset_y = e.position[1] - template.position[1];
    let meta = json!({
        "knot_height": (offset_y + knot.y) * 0.01,
        "knot_front": (knot.with_y(0.0).length() + KNOT_OUT) * 0.01,
        "lean": TIE_LEAN,
        "length": (tip - knot).length() * 0.01,
    });
    std::fs::write(out.join("tie.json"), serde_json::to_vec_pretty(&meta)?)?;
    println!("tie: {}", meta);
    Ok(())
}

/// The level's characters: each distinct model once (`npc_<model>.glb`, no clips), each
/// animation set once (`anims_<set>.glb`, on a reference model), and `actors.json` saying who
/// stands where, facing which way, with which model and animation set.
fn actors(level: &Level, out: &Path) -> Result<()> {
    // Model roots: centimetres to metres, mirror folded in (a plain scale).
    let root = crate::instance_transform([[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]], [0.0; 3]) * F;
    let sets = [("Bjarkhov", "Bjarkov.anm"), ("BombWorker", "Bomb_Builder.anm"), ("FabianFuchs", "FabianFuchs.anm"), ("ServiceWorker", "Worker_C2-1.anm"), ("Chef", "Chef_C2-1.anm")];
    let mut written: std::collections::HashMap<u32, String> = std::collections::HashMap::new();
    let mut list = Vec::new();
    let mut reference: Option<SkinnedModel> = None;
    for w in level.entities.windows(2) {
        let (actor, ground) = (&w[0], &w[1]);
        if ground.name != "Ground" || level.prm.kind_at(ground.primitive) != Some(1) || actor.position == [0.0; 3] {
            continue;
        }
        if actor.name.ends_with("_HMas") || actor.name.ends_with("_NUDE") || actor.name.starts_with("Hitman") {
            continue;
        }
        let file = match written.get(&ground.primitive) {
            Some(f) => f.clone(),
            None => {
                let Ok(model) = level.prm.skinned_model(ground.primitive) else { continue };
                let file = format!("npc_{:x}.glb", ground.primitive);
                write(level, &model, &[], root, &actor.name, &out.join(&file))?;
                if reference.is_none() && actor.name.contains("Soldier") {
                    reference = Some(model);
                }
                written.insert(ground.primitive, file.clone());
                file
            }
        };
        // Facing: the actor's own rotation, mirror folded in (a proper rotation).
        let m = crate::instance_transform(actor.rotation, [0.0; 3]) * F;
        let (_, q, _) = m.to_scale_rotation_translation();
        let set = sets.iter().find(|(k, _)| actor.name.contains(k)).map_or("Reg_Male.anm", |(_, s)| *s);
        let script = actor.props.as_ref().map(|p| p.script.clone()).unwrap_or_default();
        list.push(json!({ "name": actor.name, "model": file, "pos": crate::glacier_to_bevy(actor.position).to_array(), "rot": q.to_array(), "set": set, "script": script }));
    }
    std::fs::write(out.join("actors.json"), serde_json::to_vec_pretty(&list)?)?;
    println!("actors: {} characters, {} models", list.len(), written.len());
    // Animation sets as shared libraries (every model has the same bone names).
    let reference = reference.context("no soldier model for the animation libraries")?;
    for set in ["Reg_Male.anm"].into_iter().chain(sets.iter().map(|(_, s)| *s)) {
        let Some(anims) = level.anm.sets.iter().find(|s| s.path.ends_with(set)) else { continue };
        let mut clips: Vec<&Animation> = anims.animations.values().collect();
        clips.sort_by(|a, b| a.name.cmp(&b.name));
        let stem = set.trim_end_matches(".anm");
        write(level, &reference, &clips, root, stem, &out.join(format!("anims_{stem}.glb")))?;
    }
    Ok(())
}

fn write(level: &Level, model: &SkinnedModel, clips: &[&Animation], root: Mat4, name: &str, path: &Path) -> Result<()> {
    let mut gltf = Gltf::default();
    let mut materials = Materials::new();
    // Skeleton: bind pose per bone, relative to its parent.
    let locals: Vec<(Vec3, Quat)> = model.bones.iter().map(|b| (pos(b.translation), rot(b.rotation))).collect();
    let mut globals: Vec<Mat4> = Vec::with_capacity(locals.len());
    for (b, (t, r)) in model.bones.iter().zip(&locals) {
        let m = Mat4::from_rotation_translation(*r, *t);
        globals.push(b.parent.map_or(m, |p| globals[p] * m));
    }
    // One root name for every character, so animation tracks (`Character/Skeleton3D:PELVIS`)
    // fit any model.
    let root_node = gltf.node(json!({ "name": "Character", "matrix": root.to_cols_array() }));
    let first_joint = gltf.nodes.len();
    for (t, r) in &locals {
        gltf.node(json!({ "translation": t.to_array(), "rotation": r.to_array() }));
    }
    for (i, b) in model.bones.iter().enumerate() {
        gltf.nodes[first_joint + i]["name"] = json!(b.name);
    }
    let joint = |i: usize| first_joint + i;
    let mut root_children = Vec::new();
    for (i, b) in model.bones.iter().enumerate() {
        let children: Vec<usize> = model.bones.iter().enumerate().filter(|(_, c)| c.parent == Some(i)).map(|(k, _)| joint(k)).collect();
        if !children.is_empty() {
            gltf.nodes[joint(i)]["children"] = json!(children);
        }
        if b.parent.is_none() {
            root_children.push(joint(i));
        }
    }
    let ibm: Vec<[f32; 16]> = globals.iter().map(|g| g.inverse().to_cols_array()).collect();
    let ibm_acc = gltf.matrices(&ibm);
    gltf.skins.push(json!({ "joints": (0..model.bones.len()).map(joint).collect::<Vec<_>>(), "inverseBindMatrices": ibm_acc, "skeleton": joint(0) }));

    // The mesh: every part, skinned.
    let arrays: Vec<_> = model
        .submeshes
        .iter()
        .map(|sm| {
            let p: Vec<[f32; 3]> = sm.vertices.iter().map(|v| pos(v.pos).to_array()).collect();
            let n: Vec<[f32; 3]> = sm.vertices.iter().map(|v| pos(v.normal).to_array()).collect();
            let uv: Vec<[f32; 2]> = sm.vertices.iter().map(|v| v.uv).collect();
            let j: Vec<[u16; 4]> = sm.vertices.iter().map(|v| v.bones).collect();
            let w: Vec<[f32; 4]> = sm
                .vertices
                .iter()
                .map(|v| {
                    let s: f32 = v.weights.iter().sum();
                    if s > 0.0 { v.weights.map(|x| x / s) } else { [1.0, 0.0, 0.0, 0.0] }
                })
                .collect();
            let idx: Vec<u16> = sm.triangles.iter().flatten().copied().collect();
            (p, n, uv, j, w, idx, sm.texture, crate::blend_mode(sm.blended, 0))
        })
        .collect();
    let mats: Vec<usize> = arrays.iter().map(|a| materials.get(&mut gltf, level, a.6, a.7)).collect();
    let prims: Vec<Primitive> = arrays
        .iter()
        .zip(&mats)
        .map(|((p, n, uv, j, w, idx, _, _), m)| Primitive { positions: p, normals: n, uvs: uv, colors: None, joints: Some(j), weights: Some(w), indices: idx, material: Some(*m) })
        .collect();
    let mesh = gltf.mesh(name, &prims);
    root_children.push(gltf.node(json!({ "name": format!("{name}_Mesh"), "mesh": mesh, "skin": 0 })));
    gltf.nodes[root_node]["children"] = json!(root_children);
    gltf.scene_roots = vec![root_node];

    // Animations: every track sampled once per frame.
    let by_name: std::collections::HashMap<&str, usize> = model.bones.iter().enumerate().map(|(i, b)| (b.name.as_str(), i)).collect();
    let mut exported = 0;
    for clip in clips {
        let frames = clip.frames.max(1) as usize;
        let times: Vec<f32> = (0..=frames).map(|f| f as f32 / anm::FPS).collect();
        let time_acc = gltf.scalars(&times, true);
        let (mut channels, mut samplers) = (Vec::new(), Vec::new());
        let place = in_place(&clip.name);
        for t in &clip.tracks {
            let Some(&b) = by_name.get(t.bone.as_str()) else { continue };
            if !t.rotations.is_empty() {
                let q: Vec<[f32; 4]> = (0..=frames).map(|f| rot(anm::sample_rot(&t.rotations, f as f32)).to_array()).collect();
                let out = gltf.floats(&q, "VEC4", false, None);
                samplers.push(json!({ "input": time_acc, "output": out, "interpolation": "LINEAR" }));
                channels.push(json!({ "sampler": samplers.len() - 1, "target": { "node": joint(b), "path": "rotation" } }));
            }
            if !t.positions.is_empty() && !(place && t.bone == "GROUND") {
                let p: Vec<[f32; 3]> = (0..=frames).map(|f| pos(anm::sample_pos(&t.positions, f as f32)).to_array()).collect();
                let out = gltf.floats(&p, "VEC3", false, None);
                samplers.push(json!({ "input": time_acc, "output": out, "interpolation": "LINEAR" }));
                channels.push(json!({ "sampler": samplers.len() - 1, "target": { "node": joint(b), "path": "translation" } }));
            }
        }
        if !channels.is_empty() {
            gltf.animations.push(json!({ "name": clip.name, "channels": channels, "samplers": samplers }));
            exported += 1;
        }
    }
    // Each clip's length and root speed (m/s, from its `GROUND` track), so the game can match
    // playback to movement and keep feet from sliding.
    let meta: serde_json::Map<String, serde_json::Value> = clips
        .iter()
        .map(|c| {
            let secs = c.frames.max(1) as f32 / anm::FPS;
            let ground = c.tracks.iter().find(|t| t.bone == "GROUND" && !t.positions.is_empty());
            let speed = ground.map_or(0.0, |t| {
                let (a, b) = (pos(anm::sample_pos(&t.positions, 0.0)), pos(anm::sample_pos(&t.positions, c.frames as f32)));
                (b - a).with_y(0.0).length() * 0.01 / secs
            });
            (c.name.clone(), json!({ "seconds": secs, "root_speed": speed }))
        })
        .collect();
    std::fs::write(path.with_extension("json"), serde_json::to_vec_pretty(&meta)?)?;
    gltf.write(path)?;
    println!("character {name}: {} bones, {} parts, {exported} clips -> {}", model.bones.len(), model.submeshes.len(), path.display());
    Ok(())
}
