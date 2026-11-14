//! Replays hex 3.4.0's offscreen frame schedule through the real Dot scope
//! simulation and writes the u16 dot buffer, frame by frame.
//!
//! The schedule is `src/rune_hud/tests.rs:50-77` verbatim: 330 frames at
//! 1/60 s, `demo_loudness` as the meter for 3 s, then Submitted, Processing,
//! JobCompleted. The buffer layout is the one `rune_hud.rs:824 packed_dots`
//! writes: per frame, 4096 bytes of little-endian `[u16 power, u16 fresh]`
//! pairs, zero-padded to MAX_DOTS.

mod app_paths;
mod app_settings;
mod durable;
mod dictation;
mod macos_rune;
mod rune_hud;

use std::time::{Duration, Instant};

use dictation::indicator::{DictationIndicatorEvent as HudEvent, DotFrame, IndicatorModel};
use rune_hud::dot_scope::{self, Tuning};

const MAX_DOTS: usize = dot_scope::MAX_DOTS;
const DOT_BYTES: usize = MAX_DOTS * 4;

fn schedule(model: &mut IndicatorModel, start: Instant) -> Vec<DotFrame> {
    let mut events = vec![
        (0.0, HudEvent::Started),
        (3.0, HudEvent::Submitted { job_id: 1 }),
        (3.6, HudEvent::Processing { job_id: 1 }),
        (4.4, HudEvent::JobCompleted { job_id: 1 }),
    ];
    events.reverse();
    (0..330)
        .map(|n| {
            let t = n as f32 / 60.0;
            let now = start + Duration::from_secs_f32(t);
            while events.last().is_some_and(|(at, _)| *at <= t) {
                model.handle(events.pop().unwrap().1, now, false);
            }
            if t < 3.0 {
                // A microphone's RMS for the demo voice's loudness.
                let rms = 10_f32.powf(dot_scope::demo_loudness(t) / 20.0);
                let meter = HudEvent::Meter {
                    average: rms,
                    peak: (rms * 3.0).min(1.0),
                };
                model.handle(meter, now, false);
            }
            model.step(now, 1.0 / 60.0, false)
        })
        .collect()
}

fn main() {
    let out_dir = std::env::args().nth(1).unwrap_or_else(|| "out".into());
    std::fs::create_dir_all(&out_dir).unwrap();
    let start = Instant::now();
    let mut model = IndicatorModel::new(Tuning::default(), start);
    let frames = schedule(&mut model, start);

    let mut dots = Vec::with_capacity(frames.len() * DOT_BYTES);
    let mut meta = String::new();
    meta.push_str("frame\tt\tcolumns\trows\twidth\theight\topacity\tscale\tsoftness\tcool\tglow\tgrid\tlive\tdone\treveal\n");
    for (n, frame) in frames.iter().enumerate() {
        let mut packed: Vec<u8> = frame
            .dots
            .iter()
            .take(MAX_DOTS)
            .flat_map(|[power, fresh]| [power.to_le_bytes(), fresh.to_le_bytes()])
            .flatten()
            .collect();
        assert!(packed.len() <= DOT_BYTES, "frame {n}: {} dot bytes", packed.len());
        packed.resize(DOT_BYTES, 0);
        dots.extend_from_slice(&packed);
        let p = &frame.pose;
        meta.push_str(&format!(
            "{n}\t{:.6}\t{}\t{}\t{:.6}\t{:.6}\t{:.6}\t{:.6}\t{:.6}\t{:.6}\t{:.6}\t{:.6}\t{:.6}\t{:.6}\t{:.6}\n",
            n as f32 / 60.0,
            frame.columns,
            frame.rows,
            p.width,
            p.height,
            p.opacity,
            p.scale,
            p.softness,
            p.cool,
            p.glow,
            p.grid,
            p.live,
            p.done,
            p.reveal,
        ));
    }
    std::fs::write(std::path::Path::new(&out_dir).join("dots.bin"), &dots).unwrap();
    std::fs::write(std::path::Path::new(&out_dir).join("meta.tsv"), &meta).unwrap();
    let last = frames.last().unwrap();
    println!(
        "frames={} dot_bytes_per_frame={} total={} columns={} rows={} file={}",
        frames.len(),
        DOT_BYTES,
        dots.len(),
        last.columns,
        last.rows,
        std::path::Path::new(&out_dir).join("dots.bin").display()
    );
}
