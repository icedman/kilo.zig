//! Collection of types used by the editor.

///////////////////////////////////////////////////////////////////////////////
//
//                              Editor types
//
///////////////////////////////////////////////////////////////////////////////

/// Total size of the terminal screen where the editor runs.
pub const Screen = struct {
    rows: usize,
    cols: usize,
};

/// The state of the editor.
pub const Editor = struct {
    screen: Screen = Screen{ .rows = 0, .cols = 0 },
    should_quit: bool = false,
    just_started: bool = false,
    statusMsg: Chars,
    statusMsgTime: i64,
    welcomeMsg: Chars,
};

/// A 'view' of the current buffer, is what we can see of it, and where the
/// cursor lies in it. It's basically the editor window where the file is
/// shown.
pub const View = struct {
    cx: usize = 0, // cursor column
    cy: usize = 0, // cursor line
    rx: usize = 0, // column in the rendered row, greater than .cx if there are tabs
    cwant: usize = 0, // wanted column when moving vertically across shorter lines
    rowoff: usize = 0, // the top visible line, increases as we scroll down
    coloff: usize = 0, // the leftmost visible column
};

/// The contents of what we're working on, with all its attributes.
pub const Buffer = struct {
    allocator: std.mem.Allocator,
    dirty: bool = false, // modified state
    rows: std.ArrayList(Row), // buffer rows
    filename: ?[]u8 = null, // path of the file
    syntax: ?[]const u8 = null, // name of the syntax
    syndef: ?*const Syntax = null, // pointer to the syntax definition

    pub fn init(allocator: std.mem.Allocator) Buffer {
        return Buffer {
            .allocator = allocator,
            .rows = .init(allocator),
        };
    }

    pub fn deinit(self: *Buffer) void {
        freeOptional(self.allocator, self.filename);
        freeOptional(self.allocator, self.syntax);
        for (self.rows.items) |row| {
            row.deinit();
        }
        self.rows.deinit();
    }
};

/// Each row of a buffer.
pub const Row = struct {
    allocator: std.mem.Allocator,
    chars: Chars,
    render: []u8,
    hl: []Highlight,
    ml_comment_start: bool,

    pub fn init(allocator: std.mem.Allocator) Row{
        return Row{
            .allocator = allocator,
            .chars = .init(allocator),
            .render = &.{},
            .hl = &.{},
            .ml_comment_start = false,
        };
    }

    pub fn deinit(self: *const Row) void {
        self.chars.deinit();
        self.allocator.free(self.render);
        self.allocator.free(self.hl);
    }

    /// Length of the real row.
    pub fn len(self: *const Row) usize {
        return self.chars.items.len;
    }

    /// Length of the visual row.
    pub fn rlen(self: *const Row) usize {
        return self.render.len;
    }

    /// Get character at index `ix` of the real row.
    pub fn at(self: *const Row, ix: usize) u8 {
        return self.chars.items[ix];
    }
};

///////////////////////////////////////////////////////////////////////////////
//
//                              Other types
//
///////////////////////////////////////////////////////////////////////////////

pub const EditorError = error{
    InsertRow,
    OutOfMemory,
    EndOfStream,
};

pub const FileError = std.fs.File.OpenError || std.fs.File.WriteError;

/// ASCII codes of the keys, as they are read from stdin.
pub const Key = enum(u8) {
    ctrl_b = 2,
    ctrl_c = 3,
    ctrl_d = 4,
    ctrl_f = 6,
    ctrl_g = 7,
    ctrl_h = 8,
    tab = 9,
    ctrl_k = 11,
    ctrl_l = 12,
    enter = 13,
    ctrl_q = 17,
    ctrl_s = 19,
    ctrl_t = 20,
    ctrl_u = 21,
    esc = 27,
    backspace = 127,
    left = 128,
    right = 129,
    up = 130,
    down = 131,
    del = 132,
    home = 133,
    end = 134,
    page_up = 135,
    page_down = 136,
    _
};

pub const Direction = enum { forward, backward };

///////////////////////////////////////////////////////////////////////////////
//
//                              Callbacks
//
///////////////////////////////////////////////////////////////////////////////

/// Return value for all callbacks
pub const CbRetv = EditorError!void;

/// Arguments for the prompt callback
pub const PromptCbArgs = struct {
    input: *Chars, // current input entered by user
    key: Key, // last typed key
    saved: View, // saved view, in case it needs to be restored
    final: bool = false, // becomes true in the last callback invocation
};

/// The prompt callback function type
pub const PromptCb = fn(PromptCbArgs) CbRetv;

///////////////////////////////////////////////////////////////////////////////
//
//                              Syntax types
//
///////////////////////////////////////////////////////////////////////////////

pub const SyntaxFlags = packed struct {
    numbers: bool = false, // should highlight integer and floating point numbers
    hex: bool = false, // should highlight 0x[0-9a-fA-F]+ numbers
    bin: bool = false, // should highlight 0b[01]+ numbers
    octal: bool = false, // should highlight 0o[0-7]+ numbers
    uscn: bool = false, // supports undescores in numeric literals
    strings: bool = false, // should highlight strings
    dquotes: bool = false, // supports double-quoted strings
    squotes: bool = false, // supports single-quoted strings
    chars: bool = false, // single-quotes are used for char literals instead
    uppercase: bool = false, // should highlight uppercase words
};

pub const Syntax = struct {
    ft_name:  []const u8,          // name of filetype
    ft_ext:   []const []const u8,  // array of extensions for filetype detection
    ft_files: []const []const u8,  // array of full filenames for filetype detection
    lcmt:     []const []const u8,  // leaders for single-line comments
    mlcmt:    []const []const u8,  // [0] is start of block
                                   // [1] is leader for lines between start and end
                                   // [2] is end of block
    keywords: []const []const u8,  // array of words with 'Keywords' highlight
    types:    []const []const u8,  // array of words with 'Types' highlight
    builtin:  []const []const u8,  // array of words with 'Builtin' highlight
    constant: []const []const u8,  // array of words with 'Constant' highlight
    preproc:  []const []const u8,  // array of words with 'Preproc' highlight
    flags:    SyntaxFlags,         // bit field with supported syntax groups
};

pub const Highlight = enum(u8) {
    normal = 0,
    comment,
    mlcomment,
    number,
    string,
    keyword,
    types,
    builtin,
    constant,
    preproc,
    uppercase,
    escape,
    match,
};

pub const HlGroup = struct {
    attr: []const u8, // the highlight CSI escape sequence
    reverse: bool,
    bold: bool,
    underline: bool,
};

///////////////////////////////////////////////////////////////////////////////
//
//                              Functions
//
///////////////////////////////////////////////////////////////////////////////

/// Free an optional if not null.
pub fn freeOptional(allocator: std.mem.Allocator, sl: anytype) void {
    if (sl) |slice| {
        allocator.free(slice);
    }
}

///////////////////////////////////////////////////////////////////////////////
//
//                              Constants/variables
//
///////////////////////////////////////////////////////////////////////////////

const std = @import("std");

const Chars = std.ArrayList(u8);
