//! The one enum `hud_placement` reads, copied from hex 3.4.0's app_settings.rs.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum IndicatorPosition {
    #[default]
    Top = 0,
    Bottom = 1,
    Hidden = 2,
}
