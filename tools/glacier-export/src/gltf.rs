//! A minimal binary glTF 2.0 (`.glb`) writer: meshes with positions, normals, UVs, vertex
//! colours and 16-bit indices, PBR materials with embedded PNG textures, and a node tree.
//! Enough for level geometry; skins and animations are added by `Gltf::skin` and
//! `Gltf::animation` for characters.

use serde_json::{Value, json};

#[derive(Default)]
pub struct Gltf {
    bin: Vec<u8>,
    buffer_views: Vec<Value>,
    accessors: Vec<Value>,
    pub meshes: Vec<Value>,
    pub materials: Vec<Value>,
    textures: Vec<Value>,
    images: Vec<Value>,
    pub nodes: Vec<Value>,
    pub skins: Vec<Value>,
    pub animations: Vec<Value>,
    pub scene_roots: Vec<usize>,
}

/// One triangle list to add as a mesh primitive.
pub struct Primitive<'a> {
    pub positions: &'a [[f32; 3]],
    pub normals: &'a [[f32; 3]],
    pub uvs: &'a [[f32; 2]],
    pub colors: Option<&'a [[f32; 4]]>,
    /// Skinning: four joint indices and weights per vertex.
    pub joints: Option<&'a [[u16; 4]]>,
    pub weights: Option<&'a [[f32; 4]]>,
    pub indices: &'a [u16],
    pub material: Option<usize>,
}

impl Gltf {
    fn align(&mut self) {
        while self.bin.len() % 4 != 0 {
            self.bin.push(0);
        }
    }

    /// Appends raw bytes as a buffer view; returns its index.
    pub fn view(&mut self, bytes: &[u8], target: Option<u32>) -> usize {
        self.align();
        let offset = self.bin.len();
        self.bin.extend_from_slice(bytes);
        let mut v = json!({ "buffer": 0, "byteOffset": offset, "byteLength": bytes.len() });
        if let Some(t) = target {
            v["target"] = json!(t);
        }
        self.buffer_views.push(v);
        self.buffer_views.len() - 1
    }

    fn accessor(&mut self, view: usize, component: u32, count: usize, kind: &str, minmax: Option<(Vec<f32>, Vec<f32>)>) -> usize {
        let mut a = json!({ "bufferView": view, "componentType": component, "count": count, "type": kind });
        if let Some((min, max)) = minmax {
            a["min"] = json!(min);
            a["max"] = json!(max);
        }
        self.accessors.push(a);
        self.accessors.len() - 1
    }

    pub fn floats<const N: usize>(&mut self, data: &[[f32; N]], kind: &str, bounds: bool, target: Option<u32>) -> usize {
        let bytes: Vec<u8> = data.iter().flatten().flat_map(|f| f.to_le_bytes()).collect();
        let minmax = bounds.then(|| {
            let mut lo = vec![f32::MAX; N];
            let mut hi = vec![f32::MIN; N];
            for v in data {
                for k in 0..N {
                    lo[k] = lo[k].min(v[k]);
                    hi[k] = hi[k].max(v[k]);
                }
            }
            (lo, hi)
        });
        let view = self.view(&bytes, target);
        self.accessor(view, 5126, data.len(), kind, minmax)
    }

    pub fn scalars(&mut self, data: &[f32], bounds: bool) -> usize {
        let bytes: Vec<u8> = data.iter().flat_map(|f| f.to_le_bytes()).collect();
        let minmax = bounds.then(|| (vec![data.iter().copied().fold(f32::MAX, f32::min)], vec![data.iter().copied().fold(f32::MIN, f32::max)]));
        let view = self.view(&bytes, None);
        self.accessor(view, 5126, data.len(), "SCALAR", minmax)
    }

    pub fn matrices(&mut self, data: &[[f32; 16]]) -> usize {
        let bytes: Vec<u8> = data.iter().flatten().flat_map(|f| f.to_le_bytes()).collect();
        let view = self.view(&bytes, None);
        self.accessor(view, 5126, data.len(), "MAT4", None)
    }

    /// A mesh made of `prims`; returns its index.
    pub fn mesh(&mut self, name: &str, prims: &[Primitive]) -> usize {
        let mut out = Vec::new();
        for p in prims {
            let pos = self.floats(p.positions, "VEC3", true, Some(34962));
            let nrm = self.floats(p.normals, "VEC3", false, Some(34962));
            let uv = self.floats(p.uvs, "VEC2", false, Some(34962));
            let mut attrs = json!({ "POSITION": pos, "NORMAL": nrm, "TEXCOORD_0": uv });
            if let Some(c) = p.colors {
                attrs["COLOR_0"] = json!(self.floats(c, "VEC4", false, Some(34962)));
            }
            if let (Some(j), Some(w)) = (p.joints, p.weights) {
                let bytes: Vec<u8> = j.iter().flatten().flat_map(|v| v.to_le_bytes()).collect();
                let view = self.view(&bytes, Some(34962));
                attrs["JOINTS_0"] = json!(self.accessor(view, 5123, j.len(), "VEC4", None));
                attrs["WEIGHTS_0"] = json!(self.floats(w, "VEC4", false, Some(34962)));
            }
            let bytes: Vec<u8> = p.indices.iter().flat_map(|i| i.to_le_bytes()).collect();
            let view = self.view(&bytes, Some(34963));
            let idx = self.accessor(view, 5123, p.indices.len(), "SCALAR", None);
            let mut prim = json!({ "attributes": attrs, "indices": idx, "mode": 4 });
            if let Some(m) = p.material {
                prim["material"] = json!(m);
            }
            out.push(prim);
        }
        self.meshes.push(json!({ "name": name, "primitives": out }));
        self.meshes.len() - 1
    }

    /// An embedded PNG texture; returns the texture index.
    pub fn texture(&mut self, name: &str, png: &[u8]) -> usize {
        let view = self.view(png, None);
        self.images.push(json!({ "name": name, "mimeType": "image/png", "bufferView": view }));
        self.textures.push(json!({ "source": self.images.len() - 1, "sampler": 0 }));
        self.textures.len() - 1
    }

    pub fn node(&mut self, node: Value) -> usize {
        self.nodes.push(node);
        self.nodes.len() - 1
    }

    pub fn write(mut self, path: &std::path::Path) -> anyhow::Result<()> {
        self.align();
        let mut doc = json!({
            "asset": { "version": "2.0", "generator": "glacier-export" },
            "scene": 0,
            "scenes": [{ "nodes": self.scene_roots }],
            "nodes": self.nodes,
            "meshes": self.meshes,
            "materials": self.materials,
            "textures": self.textures,
            "images": self.images,
            "samplers": [{ "magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497 }],
            "accessors": self.accessors,
            "bufferViews": self.buffer_views,
            "buffers": [{ "byteLength": self.bin.len() }],
        });
        if !self.skins.is_empty() {
            doc["skins"] = json!(self.skins);
        }
        if !self.animations.is_empty() {
            doc["animations"] = json!(self.animations);
        }
        let mut text = serde_json::to_vec(&doc)?;
        while text.len() % 4 != 0 {
            text.push(b' ');
        }
        let total = 12 + 8 + text.len() + 8 + self.bin.len();
        let mut out = Vec::with_capacity(total);
        out.extend_from_slice(b"glTF");
        out.extend_from_slice(&2u32.to_le_bytes());
        out.extend_from_slice(&(total as u32).to_le_bytes());
        out.extend_from_slice(&(text.len() as u32).to_le_bytes());
        out.extend_from_slice(b"JSON");
        out.extend_from_slice(&text);
        out.extend_from_slice(&(self.bin.len() as u32).to_le_bytes());
        out.extend_from_slice(b"BIN\0");
        out.extend_from_slice(&self.bin);
        std::fs::write(path, out)?;
        Ok(())
    }
}

/// Encodes straight RGBA8 as PNG.
pub fn png(width: u32, height: u32, rgba: &[u8]) -> anyhow::Result<Vec<u8>> {
    let mut out = Vec::new();
    {
        let mut enc = png::Encoder::new(&mut out, width, height);
        enc.set_color(png::ColorType::Rgba);
        enc.set_depth(png::BitDepth::Eight);
        let mut w = enc.write_header()?;
        w.write_image_data(rgba)?;
    }
    Ok(out)
}
