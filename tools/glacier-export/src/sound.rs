//! Sounds and music, decoded from the level's own bank (`<SCENE>_MAIN.WHD/WAV`) and
//! `streams.wav`, written as `.wav` / `.ogg` (whichever the original stores) for Godot.
//!
//! By default the score's cues, the wind, footsteps, impacts, weapons, voices and the base's
//! public address; `--sounds-all` writes the whole bank.

use anyhow::Result;
use glacier_export::glacier::audio::AudioArchive;
use std::path::Path;

/// Jesper Kyd's score for the level, one loop per mood (as the Bevy project's `music.rs`).
const MUSIC: [&str; 6] = ["Music_Winter&Night", "Music_Submarine", "Music_Suspense3", "Music_Sus1_High_Intense", "Music_Death_Loop", "Music_Main_Title_No_Intro"];
/// Name prefixes of the sounds the game uses.
const PREFIXES: [&str; 12] = ["Wind_", "Step_", "Impact_", "W_", "Pain_", "Die_", "Door_", "Body_", "Drop_", "PickUp_", "02-1_", "C02-1_"];

pub fn export(root: &Path, scene: &str, out: &Path) -> Result<()> {
    let dir = root.join("data/Scenes").join(scene);
    let bank = AudioArchive::load(&dir.join(format!("{scene}_MAIN.WHD")), &dir.join(format!("{scene}_MAIN.WAV")), &root.join("data/streams.wav"))?;
    let all = std::env::args().any(|a| a == "--sounds-all");
    let mut names: Vec<&String> = bank
        .entries
        .keys()
        .filter(|n| all || MUSIC.iter().any(|m| n.trim_end_matches(".wav") == *m) || PREFIXES.iter().any(|p| n.starts_with(p)))
        .collect();
    names.sort();
    let mut written = 0;
    for name in names {
        let Some(bytes) = bank.decode(name) else { continue };
        let ext = if bytes.starts_with(b"OggS") { "ogg" } else { "wav" };
        // Godot resource names: no `&`.
        let file = name.trim_end_matches(".wav").replace('&', "_and_");
        std::fs::write(out.join(format!("{file}.{ext}")), bytes)?;
        written += 1;
    }
    println!("sounds: {written} written to {}", out.display());
    Ok(())
}
