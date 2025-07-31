//! Editor options. For now they are hard-coded and cannot be modified from
//! inside the editor, neither are read from a configuration file.

pub const quit_times = 3;
pub const query_len = 256;
pub const version_str = "0.1";
pub const version = 0.1;

pub var scroll_off: u8 = 2;
pub var tabstop: u8 = 8;
pub var textwidth: u8 = 79;
pub var autoindent = true;
pub var syntax = true;
pub var wrapscan = true;
