//! Stand-in for `crate::durable`: atomic-ish write of a small file.
use std::path::Path;

pub fn write(path: &Path, bytes: &[u8]) -> color_eyre::Result<()> {
    std::fs::create_dir_all(path.parent().unwrap_or(Path::new(".")))?;
    std::fs::write(path, bytes)?;
    Ok(())
}
