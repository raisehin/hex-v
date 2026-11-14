//! Stand-in for color-eyre: the copied 3.4.0 files only need `Result<T>`.
pub type Result<T> = std::io::Result<T>;
