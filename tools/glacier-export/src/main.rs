//! Converts a Hitman: Contracts scene into files Godot imports natively.
//!
//! `glacier-export [SCENE] [--out DIR]` reads `data/Scenes/<SCENE>` (default `C02-1`) and
//! writes into `game/imported/` (by default):
//! - `level/<SCENE>.glb`: every placed static mesh (models shared between instances), with the
//!   original textures embedded as PNG and the baked lighting as vertex colours; cut-outs and
//!   blended layers as in the original; plus `Collision_N-colonly` nodes that Godot's importer
//!   turns into static collision.
//! - `level/<SCENE>_markers.json`: every entity's name, class and world transform, for spawn
//!   points, lamps, triggers and anchors.
//!
//! Placement follows the Bevy project's `view.rs` exactly (see its module docs for the
//! coordinate conventions): world = composed scene tree, vertices `P`-swapped, instance
//! transform `S·R·0.01`, Z mirrored.

mod character;
mod gltf;
mod sound;

use anyhow::{Context, Result};
use glacier_export::glacier::{level::Level, prm};
use glam::{Mat3, Mat4, Vec2, Vec3};
use gltf::{Gltf, Primitive};
use serde_json::json;
use std::{collections::HashMap, path::PathBuf};

const CM_TO_M: f32 = 0.01;
const MIRROR: Vec3 = Vec3::new(1.0, 1.0, -1.0);
/// Engine classes that are pure volumes: room portals and room bounds.
const HELPER_TYPES: [u32; 2] = [0x200015, 0x20001c];
/// Placed static level geometry.
const STATIC_GEOM_TYPE: u32 = 0x200002;
/// Effect templates the engine spawns on demand.
const FLAG_FX_TEMPLATE: u32 = 0x400;
/// Vertical step between stacked coplanar layers, and the extra lift for blended decals (m).
const LAYER_STEP: f32 = 0.003;
const DECAL_LIFT: f32 = 0.008;
/// How far (cm) a big underlay quad is sunk below the layers drawn over it.
const UNDERLAY_SINK: f32 = 4.0;
/// Triangles per collision node (16-bit indices).
const COLLISION_CHUNK: usize = 20_000;

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let scene = args.iter().find(|a| !a.starts_with("--")).cloned().unwrap_or_else(|| "C02-1".into());
    let root = project_root();
    let out = args.iter().position(|a| a == "--out").and_then(|i| args.get(i + 1)).map(PathBuf::from).unwrap_or_else(|| root.join("game/imported"));
    let what = |flag: &str| args.iter().any(|a| a == flag) || !args.iter().any(|a| matches!(a.as_str(), "--level" | "--characters" | "--sounds"));
    let level = Level::load(&root.join("data/Scenes"), &scene).with_context(|| format!("loading {scene}"))?;
    let world = compose_world(&level);
    if what("--level") {
        std::fs::create_dir_all(out.join("level"))?;
        export_level(&level, &world, &out.join(format!("level/{scene}.glb")))?;
        export_markers(&level, &world, &out.join(format!("level/{scene}_markers.json")))?;
    }
    if what("--characters") {
        std::fs::create_dir_all(out.join("characters"))?;
        character::export(&level, &world, &out.join("characters"))?;
    }
    if what("--sounds") {
        std::fs::create_dir_all(out.join("sounds"))?;
        sound::export(&root, &scene, &out.join("sounds"))?;
    }
    Ok(())
}

/// The project root: two levels up from this crate.
fn project_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..").canonicalize().unwrap_or_else(|_| PathBuf::from("."))
}

pub fn swap_xz([x, y, z]: [f32; 3]) -> [f32; 3] {
    [z, y, x]
}

pub fn glacier_to_bevy(p: [f32; 3]) -> Vec3 {
    Vec3::from(p) * MIRROR * CM_TO_M
}

/// The entity's matrix: its nine floats act on row vectors, so each stored row is a column;
/// Z mirrored; centimetres to metres.
pub fn instance_transform(r: [[f32; 3]; 3], p: [f32; 3]) -> Mat4 {
    let r = Mat3::from_cols(Vec3::from(r[0]), Vec3::from(r[1]), Vec3::from(r[2]));
    Mat4::from_mat3_translation(Mat3::from_diagonal(MIRROR) * r * CM_TO_M, glacier_to_bevy(p))
}

fn mat3_mul(a: [[f32; 3]; 3], b: [[f32; 3]; 3]) -> [[f32; 3]; 3] {
    let mut out = [[0.0; 3]; 3];
    for (r, row) in out.iter_mut().enumerate() {
        for (c, v) in row.iter_mut().enumerate() {
            *v = (0..3).map(|k| a[r][k] * b[k][c]).sum();
        }
    }
    out
}

/// World position and rotation of every entity, composed through the scene tree.
pub struct World {
    pub positions: Vec<[f32; 3]>,
    pub rotations: Vec<[[f32; 3]; 3]>,
}

impl World {
    pub fn transform(&self, i: usize) -> Mat4 {
        instance_transform(self.rotations[i], self.positions[i])
    }
}

fn compose_world(level: &Level) -> World {
    struct Frame {
        pos: [f32; 3],
        rot: [[f32; 3]; 3],
        physical: bool,
    }
    let mut stack: Vec<Frame> = Vec::new();
    let (mut positions, mut rotations) = (Vec::new(), Vec::new());
    for e in &level.entities {
        for _ in 0..(e.tree_bits >> 1) {
            stack.pop();
        }
        let (pos, child_of_physical) = match stack.last() {
            Some(p) if p.physical => {
                let (v, r) = (e.position, p.rot);
                let rotated = [0, 1, 2].map(|c| v[0] * r[0][c] + v[1] * r[1][c] + v[2] * r[2][c]);
                ([p.pos[0] + rotated[0], p.pos[1] + rotated[1], p.pos[2] + rotated[2]], true)
            }
            _ => (e.position, false),
        };
        let physical = child_of_physical || e.position.iter().any(|c| c.abs() > 1.0);
        let rot = match stack.last() {
            Some(p) if child_of_physical => mat3_mul(e.rotation, p.rot),
            _ => e.rotation,
        };
        if e.tree_bits & 1 != 0 {
            stack.push(Frame { pos, rot, physical });
        }
        positions.push(pos);
        rotations.push(rot);
    }
    World { positions, rotations }
}

fn is_map_geometry(level: &Level, e: &glacier_export::glacier::gms::Entity, cache: &mut HashMap<u32, bool>) -> bool {
    if e.name.contains("MAP_") {
        return true;
    }
    let Ok(model) = level.prm.model(e.primitive) else { return false };
    let mut textures = model.submeshes.iter().filter(|sm| sm.texture != 0).map(|sm| sm.texture).peekable();
    textures.peek().is_some() && textures.all(|t| *cache.entry(t).or_insert_with(|| level.tex.decode(t).ok().flatten().is_some_and(|tex| tex.name.contains("IngameMap"))))
}

/// Stacked coplanar flat pieces (snow sheets over ground tiles, puddles on floors), which the
/// original resolved by draw order: later ones sit a few millimetres higher, decals above.
fn layer_flats(level: &Level, world: &World) -> HashMap<usize, f32> {
    struct Flat {
        index: usize,
        height: i32,
        min: Vec2,
        max: Vec2,
        decal: bool,
    }
    let mut flats = Vec::new();
    let mut map_textures = HashMap::new();
    for (index, e) in level.entities.iter().enumerate() {
        if e.type_id != STATIC_GEOM_TYPE || !level.prm.is_record(e.primitive) || is_map_geometry(level, e, &mut map_textures) {
            continue;
        }
        let Ok(model) = level.prm.model(e.primitive) else { continue };
        let parts: Vec<_> = model.submeshes.iter().filter(|s| s.in_lod0() && !s.is_proxy()).collect();
        if parts.is_empty() {
            continue;
        }
        let m = world.transform(index);
        let (mut lo, mut hi) = (Vec3::MAX, Vec3::MIN);
        for v in parts.iter().flat_map(|s| s.vertices.iter()) {
            let w = m.transform_point3(Vec3::from(swap_xz(v.pos)));
            lo = lo.min(w);
            hi = hi.max(w);
        }
        if hi.y - lo.y > 0.015 {
            continue;
        }
        flats.push(Flat { index, height: (hi.y * 500.0).round() as i32, min: Vec2::new(lo.x, lo.z), max: Vec2::new(hi.x, hi.z), decal: parts.iter().all(|s| s.blended) });
    }
    let mut lifts = HashMap::new();
    for (k, f) in flats.iter().enumerate() {
        let below = flats[..k]
            .iter()
            .filter(|g| (g.height - f.height).abs() <= 2 && g.decal == f.decal && g.min.cmplt(f.max).all() && f.min.cmplt(g.max).all())
            .count()
            .min(4);
        let lift = below as f32 * LAYER_STEP + if f.decal { DECAL_LIFT } else { 0.0 };
        if lift > 0.0 {
            lifts.insert(f.index, lift);
        }
    }
    lifts
}

fn is_underlay(sm: &prm::SubMesh) -> bool {
    if sm.blended || sm.vertices.len() != 4 {
        return false;
    }
    let (lo, hi) = sm.vertices.iter().fold((Vec3::MAX, Vec3::MIN), |(a, b), v| (a.min(Vec3::from(v.pos)), b.max(Vec3::from(v.pos))));
    let size = hi - lo;
    size.y < 1.0 && size.x * size.z > 20.0 * 100.0 * 100.0
}

/// A submesh as glTF arrays, `P`-swapped.
pub fn submesh_arrays(sm: &prm::SubMesh) -> (Vec<[f32; 3]>, Vec<[f32; 3]>, Vec<[f32; 2]>, Vec<[f32; 4]>, Vec<u16>) {
    let sink = if is_underlay(sm) { UNDERLAY_SINK } else { 0.0 };
    let pos = sm.vertices.iter().map(|v| swap_xz([v.pos[0], v.pos[1] - sink, v.pos[2]])).collect();
    let nrm = sm.vertices.iter().map(|v| swap_xz(v.normal)).collect();
    let uv = sm.vertices.iter().map(|v| v.uv).collect();
    let col = sm.vertices.iter().map(|v| v.color.map(|c| c as f32 / 255.0)).collect();
    let idx = sm.triangles.iter().flatten().copied().collect();
    (pos, nrm, uv, col, idx)
}

/// How a submesh is blended. The original draws glows, flashes, fire, sparks, cloud sheets
/// and some glass additively: render-state bit `0x2` on a blended submesh (tallied in the Bevy
/// project's `examples/render_states.rs`: every `HMC_FX_Glow_*`, `HMC_FX_Clouds_01a`,
/// `MuzzleFire`, `Spark`, `Fire` carries it; smoke, blood and decals don't).
pub fn blend_mode(blended: bool, render_state: u32) -> u8 {
    match (blended, render_state & 0x2 != 0) {
        (false, _) => 0,
        (true, false) => 1,
        (true, true) => 2,
    }
}

/// Materials by (texture, blend mode), with their textures embedded once. Additive materials
/// are named `…_add`; Godot's loader (`main.gd`) turns them additive and unshaded, which glTF
/// can't express.
pub struct Materials {
    by_key: HashMap<(u32, u8), usize>,
}

impl Materials {
    pub fn new() -> Self {
        Self { by_key: HashMap::new() }
    }

    pub fn get(&mut self, gltf: &mut Gltf, level: &Level, texture: u32, mode: u8) -> usize {
        if let Some(&m) = self.by_key.get(&(texture, mode)) {
            return m;
        }
        let blended = mode != 0;
        let suffix = ["", "_blend", "_add"][mode as usize];
        let mut mat = json!({
            "name": format!("tex{texture}{suffix}"),
            "doubleSided": true,
            "pbrMetallicRoughness": { "metallicFactor": 0.0, "roughnessFactor": 0.9 },
        });
        match level.tex.decode(texture) {
            Ok(Some(t)) => {
                mat["name"] = json!(format!("{}{suffix}", t.name));
                if let Ok(png) = gltf::png(t.width, t.height, &t.rgba) {
                    let tex = gltf.texture(&t.name, &png);
                    mat["pbrMetallicRoughness"]["baseColorTexture"] = json!({ "index": tex });
                }
                if blended {
                    mat["alphaMode"] = json!("BLEND");
                } else if t.rgba.chunks_exact(4).any(|p| p[3] < 128) {
                    mat["alphaMode"] = json!("MASK");
                    mat["alphaCutoff"] = json!(0.5);
                }
            }
            _ => mat["pbrMetallicRoughness"]["baseColorFactor"] = json!([0.6, 0.6, 0.6, 1.0]),
        }
        gltf.materials.push(mat);
        let m = gltf.materials.len() - 1;
        self.by_key.insert((texture, mode), m);
        m
    }
}

fn mat4_cols(m: Mat4) -> Vec<f32> {
    m.to_cols_array().to_vec()
}

fn export_level(level: &Level, world: &World, path: &std::path::Path) -> Result<()> {
    let lifts = layer_flats(level, world);
    let mut gltf = Gltf::default();
    let mut materials = Materials::new();
    let mut map_textures = HashMap::new();
    // Per (model, collision hull?, non-solid?): its glTF mesh, and its collision triangles.
    struct Cached {
        mesh: Option<usize>,
        solid: Vec<[Vec3; 3]>,
        surface: Vec<[Vec3; 3]>,
    }
    let mut cache: HashMap<(u32, bool, bool), Cached> = HashMap::new();
    let mut collision: Vec<[Vec3; 3]> = Vec::new();
    let level_root = gltf.node(json!({ "name": "Level" }));
    let mut children = Vec::new();
    let (mut placed, mut prims) = (0usize, 0usize);

    for (index, e) in level.entities.iter().enumerate() {
        if e.primitive == 0 || !level.prm.is_record(e.primitive) || is_map_geometry(level, e, &mut map_textures) {
            continue;
        }
        if HELPER_TYPES.contains(&e.type_id) || e.flags & FLAG_FX_TEMPLATE != 0 {
            continue;
        }
        let coli = e.name.contains("Coli");
        let effect = ["Sky", "Blowing", "Fog", "Glitter", "GlowVol", "GlowRain", "Snow_", "SnowBlowing"].iter().any(|k| e.name.contains(k));
        let non_solid = effect || ["Cable", "Decal", "Light", "Lamp", "Wire", "Icicle", "Shadow", "Glow", "Corona"].iter().any(|k| e.name.contains(k));
        let cached = match cache.entry((e.primitive, coli, non_solid)) {
            std::collections::hash_map::Entry::Occupied(o) => o.into_mut(),
            std::collections::hash_map::Entry::Vacant(v) => {
                let entry = match level.prm.model(e.primitive) {
                    Ok(model) => {
                        let lod0: Vec<&prm::SubMesh> = model.submeshes.iter().filter(|sm| sm.in_lod0()).collect();
                        let (proxies, visible): (Vec<&prm::SubMesh>, Vec<&prm::SubMesh>) = lod0.iter().copied().partition(|sm| sm.is_proxy());
                        let local = |sm: &prm::SubMesh| sm.triangles.iter().map(|t| t.map(|i| Vec3::from(swap_xz(sm.vertices[i as usize].pos)))).collect::<Vec<_>>();
                        let solid_parts: Vec<&prm::SubMesh> = if visible.is_empty() {
                            if coli { proxies.clone() } else { Vec::new() }
                        } else if non_solid {
                            Vec::new()
                        } else if !proxies.is_empty() {
                            proxies.clone()
                        } else {
                            visible.clone()
                        };
                        let solid = solid_parts.iter().filter(|sm| sm.is_proxy() || !sm.blended).flat_map(|sm| local(sm)).collect();
                        let surface = if non_solid { Vec::new() } else { visible.iter().flat_map(|sm| local(sm)).collect() };
                        let mesh = (!visible.is_empty()).then(|| {
                            let arrays: Vec<_> = visible.iter().map(|sm| (submesh_arrays(sm), materials.get(&mut gltf, level, sm.texture, blend_mode(sm.blended, sm.render_state)))).collect();
                            let prims: Vec<Primitive> = arrays
                                .iter()
                                .map(|((p, n, u, c, i), m)| Primitive { positions: p, normals: n, uvs: u, colors: Some(c), joints: None, weights: None, indices: i, material: Some(*m) })
                                .collect();
                            gltf.mesh(&e.name, &prims)
                        });
                        Cached { mesh, solid, surface }
                    }
                    Err(_) => Cached { mesh: None, solid: Vec::new(), surface: Vec::new() },
                };
                v.insert(entry)
            }
        };
        let m = world.transform(index);
        if e.type_id == STATIC_GEOM_TYPE {
            for t in &cached.solid {
                collision.push(t.map(|v| m.transform_point3(v)));
            }
            // Up-facing visible triangles are floors; big structures also keep their walls.
            if !cached.surface.is_empty() {
                let (lo, hi) = cached.surface.iter().flatten().fold((Vec3::MAX, Vec3::MIN), |(a, b), v| (a.min(*v), b.max(*v)));
                let big = (hi - lo).x.max((hi - lo).z) * CM_TO_M > 6.0;
                for t in &cached.surface {
                    let w = t.map(|v| m.transform_point3(v));
                    let n = (w[1] - w[0]).cross(w[2] - w[0]).normalize_or_zero();
                    if n.y.abs() > 0.7 || big {
                        collision.push(w);
                    }
                }
            }
        }
        let Some(mesh) = cached.mesh else { continue };
        let lift = lifts.get(&index).copied().unwrap_or(0.0);
        let node = gltf.node(json!({ "name": e.name, "mesh": mesh, "matrix": mat4_cols(Mat4::from_translation(Vec3::Y * lift) * m) }));
        children.push(node);
        placed += 1;
        prims += gltf.meshes[mesh]["primitives"].as_array().map_or(0, |p| p.len());
    }

    // Collision, in chunks Godot turns into static concave shapes (`-colonly`).
    let collision_root = gltf.node(json!({ "name": "Collision" }));
    let mut col_children = Vec::new();
    for (k, chunk) in collision.chunks(COLLISION_CHUNK).enumerate() {
        let positions: Vec<[f32; 3]> = chunk.iter().flatten().map(|v| v.to_array()).collect();
        let normals = vec![[0.0, 1.0, 0.0]; positions.len()];
        let uvs = vec![[0.0, 0.0]; positions.len()];
        let indices: Vec<u16> = (0..positions.len() as u16).collect();
        let mesh = gltf.mesh(&format!("Collision_{k}"), &[Primitive { positions: &positions, normals: &normals, uvs: &uvs, colors: None, joints: None, weights: None, indices: &indices, material: None }]);
        col_children.push(gltf.node(json!({ "name": format!("Collision_{k}-colonly"), "mesh": mesh })));
    }
    export_heights(&collision, &path.with_file_name(format!("{}_heights.bin", path.file_stem().unwrap_or_default().to_string_lossy())))?;
    gltf.nodes[collision_root]["children"] = json!(col_children);
    gltf.nodes[level_root]["children"] = json!(children);
    gltf.scene_roots = vec![level_root, collision_root];
    println!("level: {placed} placed meshes ({} unique, {prims} primitives), {} materials, {} collision triangles", gltf.meshes.len(), gltf.materials.len(), collision.len());
    gltf.write(path)?;
    println!("wrote {}", path.display());
    Ok(())
}

/// Cell size of the height map (m).
const HEIGHT_CELL: f32 = 0.5;
/// How far a covered cell looks for open sky (m), and how many of its 16 rays (8 directions,
/// at 15° and 35° up) must reach it for snow to blow in.
const SKY_REACH: f32 = 80.0;
const SKY_RAYS: usize = 3;

/// Two maps over every `HEIGHT_CELL` square of the level, for the blizzard (`blizzard.gd`):
/// - **top**: the highest solid surface (sheets of blowing snow stand on it);
/// - **shelter**: the lowest height snow reaches there. Where there's room under the top
///   (surfaces more than 1.5 m apart), a cell sees the sky when at least `SKY_RAYS` of 16 rays
///   from 1 m above its floor, tilted 15° and 35° up, get out within `SKY_REACH`: under the
///   AN-124's wing, a canopy or a walkway the snow blows in to the floor. Otherwise (a building,
///   a tunnel: deep in a tunnel, level rays still escape along it, so they don't count) snow
///   stops at the top. Elsewhere shelter is the top. (Earlier versions cast rays upwind for a
///   lee behind every obstacle, which sliced flakes at flat heights, then counted walls in 8
///   level directions, which let snow deep into tunnels.)
///
/// Layout: six little-endian f32 (min x, min z, cell, width, height, unused), then
/// width × height pairs (top, shelter) in rows of increasing z; cells nothing covers hold −1000.
fn export_heights(collision: &[[Vec3; 3]], path: &std::path::Path) -> Result<()> {
    let (lo, hi) = collision.iter().flatten().fold((Vec3::MAX, Vec3::MIN), |(a, b), v| (a.min(*v), b.max(*v)));
    let (w, h) = (((hi.x - lo.x) / HEIGHT_CELL).ceil() as usize + 1, ((hi.z - lo.z) / HEIGHT_CELL).ceil() as usize + 1);
    let mut top = vec![-1000.0f32; w * h];
    let mut low = vec![f32::MAX; w * h];
    let cell = |x: f32, z: f32| (((x - lo.x) / HEIGHT_CELL).floor().max(0.0) as usize).min(w - 1) + (((z - lo.z) / HEIGHT_CELL).floor().max(0.0) as usize).min(h - 1) * w;
    for t in collision {
        // Corners count (thin walls and posts), and every cell centre the triangle covers at its
        // height there.
        for v in t {
            let c = cell(v.x, v.z);
            top[c] = top[c].max(v.y);
        }
        let (a, b, c) = (t[0], t[1], t[2]);
        let det = (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z);
        if det.abs() < 1e-6 {
            continue;
        }
        let (tlo, thi) = (a.min(b).min(c), a.max(b).max(c));
        let (x0, x1) = (((tlo.x - lo.x) / HEIGHT_CELL).floor() as usize, ((thi.x - lo.x) / HEIGHT_CELL).ceil() as usize);
        let (z0, z1) = (((tlo.z - lo.z) / HEIGHT_CELL).floor() as usize, ((thi.z - lo.z) / HEIGHT_CELL).ceil() as usize);
        for cz in z0..=z1.min(h - 1) {
            for cx in x0..=x1.min(w - 1) {
                let (px, pz) = (lo.x + (cx as f32 + 0.5) * HEIGHT_CELL, lo.z + (cz as f32 + 0.5) * HEIGHT_CELL);
                let l1 = ((b.z - c.z) * (px - c.x) + (c.x - b.x) * (pz - c.z)) / det;
                let l2 = ((c.z - a.z) * (px - c.x) + (a.x - c.x) * (pz - c.z)) / det;
                let l3 = 1.0 - l1 - l2;
                if l1 >= -1e-4 && l2 >= -1e-4 && l3 >= -1e-4 {
                    let y = l1 * a.y + l2 * b.y + l3 * c.y;
                    let k = cx + cz * w;
                    top[k] = top[k].max(y);
                    low[k] = low[k].min(y);
                }
            }
        }
    }

    // Shelter: triangles bucketed on a coarse grid; rays cast around each covered cell.
    let grid = Grid::new(collision, lo, hi, 2.0);
    let around: Vec<Vec3> = (0..16)
        .map(|i| {
            let a = (i % 8) as f32 * std::f32::consts::FRAC_PI_4;
            let up = if i < 8 { 15f32 } else { 35f32 }.to_radians();
            Vec3::new(a.cos() * up.cos(), up.sin(), a.sin() * up.cos())
        })
        .collect();
    let rows: Vec<Vec<f32>> = std::thread::scope(|s| {
        let threads = std::thread::available_parallelism().map_or(4, |n| n.get());
        let chunk = h.div_ceil(threads);
        let handles: Vec<_> = (0..threads)
            .map(|t| {
                let (top, low, grid, around) = (&top, &low, &grid, &around);
                s.spawn(move || {
                    let mut out = Vec::new();
                    for cz in (t * chunk)..((t + 1) * chunk).min(h) {
                        for cx in 0..w {
                            let k = cx + cz * w;
                            let (t_k, l_k) = (top[k], low[k]);
                            if t_k <= -999.0 {
                                out.push(-1000.0);
                                continue;
                            }
                            let (px, pz) = (lo.x + (cx as f32 + 0.5) * HEIGHT_CELL, lo.z + (cz as f32 + 0.5) * HEIGHT_CELL);
                            // No room under the top (open ground, a slope, a wall): snow reaches it.
                            if t_k - l_k < 1.5 {
                                out.push(t_k);
                                continue;
                            }
                            let from = Vec3::new(px, l_k + 1.0, pz);
                            let sky = around.iter().filter(|d| !grid.hits(from, **d, SKY_REACH)).count();
                            out.push(if sky >= SKY_RAYS { l_k } else { t_k });
                        }
                    }
                    out
                })
            })
            .collect();
        handles.into_iter().map(|h| h.join().unwrap()).collect()
    });
    let mut shelter: Vec<f32> = rows.into_iter().flatten().collect();

    // Rays slip out through seams in rock and walls, leaving thin lines and specks of "sky"
    // deep in a tunnel. Real openings (under a wing, an overhang) are wide: keep only open
    // cells whose whole 5 × 5 neighbourhood sees the sky, then grow those back out to the
    // cells that saw it too (a morphological opening).
    let covered = |k: usize| top[k] > -999.0 && top[k] - low[k] >= 1.5;
    // (Only covered cells count: walls and rails sampled at their corners alone look
    // uncovered and would prop the seams up.)
    let sky: Vec<bool> = (0..w * h).map(|k| covered(k) && shelter[k] < top[k]).collect();
    let near = |k: usize, f: &dyn Fn(usize) -> bool| {
        let (x, z) = ((k % w) as isize, (k / w) as isize);
        (-2..=2).all(|dz| (-2..=2).all(|dx| {
            let (nx, nz) = (x + dx, z + dz);
            nx < 0 || nz < 0 || nx >= w as isize || nz >= h as isize || f(nx as usize + nz as usize * w)
        }))
    };
    let core: Vec<bool> = (0..w * h).map(|k| sky[k] && near(k, &|n| sky[n])).collect();
    for k in 0..w * h {
        if covered(k) && shelter[k] < top[k] && near(k, &|n| !core[n]) {
            shelter[k] = top[k];
        }
    }

    let mut out = Vec::with_capacity((6 + 2 * w * h) * 4);
    for v in [lo.x, lo.z, HEIGHT_CELL, w as f32, h as f32, 0.0] {
        out.extend_from_slice(&v.to_le_bytes());
    }
    for k in 0..w * h {
        out.extend_from_slice(&top[k].to_le_bytes());
        out.extend_from_slice(&shelter[k].to_le_bytes());
    }
    std::fs::write(path, out)?;
    println!("wrote {} ({w} x {h} cells)", path.display());
    Ok(())
}

/// Triangles bucketed by their x/z bounds, for casting rays.
struct Grid<'a> {
    tris: &'a [[Vec3; 3]],
    lo: Vec3,
    cell: f32,
    w: usize,
    h: usize,
    buckets: Vec<Vec<u32>>,
}

impl<'a> Grid<'a> {
    fn new(tris: &'a [[Vec3; 3]], lo: Vec3, hi: Vec3, cell: f32) -> Self {
        let (w, h) = (((hi.x - lo.x) / cell) as usize + 1, ((hi.z - lo.z) / cell) as usize + 1);
        let mut buckets = vec![Vec::new(); w * h];
        for (i, t) in tris.iter().enumerate() {
            let (a, b) = (t[0].min(t[1]).min(t[2]), t[0].max(t[1]).max(t[2]));
            for z in ((a.z - lo.z) / cell) as usize..=(((b.z - lo.z) / cell) as usize).min(h - 1) {
                for x in ((a.x - lo.x) / cell) as usize..=(((b.x - lo.x) / cell) as usize).min(w - 1) {
                    buckets[x + z * w].push(i as u32);
                }
            }
        }
        Grid { tris, lo, cell, w, h, buckets }
    }

    /// Whether a ray from `from` along unit `dir` hits a triangle within `reach`.
    fn hits(&self, from: Vec3, dir: Vec3, reach: f32) -> bool {
        let step = self.cell * 0.5;
        let mut last = usize::MAX;
        let mut d = 0.0;
        while d <= reach + step {
            let p = from + dir * d;
            d += step;
            if p.x < self.lo.x || p.z < self.lo.z {
                return false;
            }
            let (x, z) = (((p.x - self.lo.x) / self.cell) as usize, ((p.z - self.lo.z) / self.cell) as usize);
            if x >= self.w || z >= self.h {
                return false;
            }
            let k = x + z * self.w;
            if k == last {
                continue;
            }
            last = k;
            for &i in &self.buckets[k] {
                if let Some(t) = ray_triangle(from, dir, &self.tris[i as usize]) {
                    if t > 1e-3 && t <= reach {
                        return true;
                    }
                }
            }
        }
        false
    }
}

/// Möller–Trumbore: distance along the ray to the triangle, if it hits.
fn ray_triangle(o: Vec3, d: Vec3, t: &[Vec3; 3]) -> Option<f32> {
    let (e1, e2) = (t[1] - t[0], t[2] - t[0]);
    let p = d.cross(e2);
    let det = e1.dot(p);
    if det.abs() < 1e-8 {
        return None;
    }
    let inv = 1.0 / det;
    let s = o - t[0];
    let u = s.dot(p) * inv;
    if !(0.0..=1.0).contains(&u) {
        return None;
    }
    let q = s.cross(e1);
    let v = d.dot(q) * inv;
    if v < 0.0 || u + v > 1.0 {
        return None;
    }
    Some(e2.dot(q) * inv)
}

/// Every entity's name, class and world transform (Bevy/Godot axes, metres).
fn export_markers(level: &Level, world: &World, path: &std::path::Path) -> Result<()> {
    let items: Vec<_> = level
        .entities
        .iter()
        .enumerate()
        .map(|(i, e)| {
            let (_, rot, pos) = world.transform(i).to_scale_rotation_translation();
            // `local`: the entity's own position, uncomposed (templates and actors are placed by it).
            json!({ "i": i, "name": e.name, "type": format!("{:#x}", e.type_id), "pos": pos.to_array(), "rot": rot.to_array(), "local": glacier_to_bevy(e.position).to_array() })
        })
        .collect();
    std::fs::write(path, serde_json::to_vec(&items)?)?;
    println!("wrote {} ({} entities)", path.display(), items.len());
    Ok(())
}
