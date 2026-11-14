//! Stand-in for `crate::app_paths`, which needs the hex app's data dir.
use std::path::PathBuf;

pub fn support_dir() -> color_eyre::Result<PathBuf> {
    Ok(std::env::temp_dir().join("hex-v-oracle"))
}
