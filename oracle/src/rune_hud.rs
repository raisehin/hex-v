//! The module tree hex 3.4.0 gives these files, minus everything that needs
//! Rune, wgpu or the app: only the simulation is compiled here.
pub mod dot_scope;
pub mod hud_placement;
pub mod spring;

pub(crate) use crate::dictation::indicator::DictationIndicatorEvent as HudEvent;
