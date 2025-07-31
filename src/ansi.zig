//! Module that handles ansi terminal sequences.

///////////////////////////////////////////////////////////////////////////////
//
//                              Functions
//
///////////////////////////////////////////////////////////////////////////////

/// Clear the screen.
pub fn clearScreen() !void {
    try linux.write(ClearScreen);
}

/// Write a buffer to stdout (our screen).
pub fn printToScreen(buf: std.ArrayList(u8)) !void {
    try linux.write(buf.items);
}

/// Get the window size.
pub fn getWindowSize() !Screen {
    var screen: Screen = undefined;
    var wsz: std.posix.winsize = undefined;

    if (linux.winsize(&wsz) == -1 or wsz.col == 0) {
        screen = try getCursorPosition();
    } else {
        screen = Screen{
            .rows = wsz.row,
            .cols = wsz.col,
        };
    }
    std.debug.print("screen size: {} {}\n", .{screen.rows, screen.cols});
    return screen;
}

/// Get the cursor position, to determine the window size.
pub fn getCursorPosition() !Screen {
    var buf: [32]u8 = undefined;

    try linux.write(WinMaximize);
    try linux.write(ReadCursorPos);

    var i: usize = 0;

    while (i < buf.len - 1) {
        if (try linux.readChar(&buf[i]) != 1) break;
        if (buf[i] == 'R') break;
        i += 1;
    }

    if (buf[0] != ESC or buf[1] != '[') return error.CursorError;
    std.debug.print("{s}\n", .{buf[2..i]});

    var screen = Screen{ .rows = 0, .cols = 0 };
    var semicolon: bool = false;
    var digits: u8 = 0;

    // no sscanf, format to read is "row;col"
    // read it right to left, so we can read number of digits
    // stop before the ESC character, so at index 2
    while (i > 2) {
        i -= 1;
        std.debug.print("reading: {c}\n", .{buf[i]});
        if (buf[i] == ';') {
            semicolon = true;
            digits = 0;
        }
        else if (semicolon) {
            screen.rows += (buf[i] - '0') * try std.math.powi(usize, 10, digits);
            std.debug.print("rows is now: {}\n", .{screen.rows});
            digits += 1;
        } else {
            screen.cols += (buf[i] - '0') * try std.math.powi(usize, 10, digits);
            std.debug.print("cols is now: {}\n", .{screen.cols});
            digits += 1;
        }
    }
    if (screen.cols == 0 or screen.rows == 0) {
        return error.CursorError;
    }
    return screen;
}

/// Return the escape sequence to move the cursor to a position.
pub fn moveCursorTo(buf: []u8, row: usize, col: usize) ![]const u8 {
    return std.fmt.bufPrint(buf, CSI ++ "{};{}H", .{row, col});
}

///////////////////////////////////////////////////////////////////////////////
//
//                              Constants
//
///////////////////////////////////////////////////////////////////////////////

const std = @import("std");
const linux = @import("linux.zig");
const os = std.os;

const Screen = @import("types.zig").Screen;

pub const CSI = "\x1b[";
pub const ESC = '\x1b';
pub const NUL = '\x00';

// Sets the number of column and rows to very high numbers, trying to maximize
// the window.
pub const WinMaximize = CSI ++ "999C" ++ CSI ++ "999B";

// CSI sequence to clear the screen.
pub const ClearScreen = CSI ++ "2J" ++ CSI ++ "H";

// Reports the cursor position (CPR) by transmitting ESC[n;mR, where n is the
// row and m is the column
pub const ReadCursorPos = CSI ++ "6n";

pub const ShowCursor = CSI ++ "?25h";

pub const BgColor = CSI ++ "40m";   // background color
pub const FgColor = CSI ++ "39m";   // foreground color
pub const HideCursor = CSI ++ "?25l";  // hide cursor
pub const CursorTopLeft = CSI ++ "H";     // move cursor to position 1,1
pub const InvertColors = CSI ++ "7m";
pub const ReverseColors = CSI ++ "27m";
pub const Bold = CSI ++ "1m";
pub const NoBold = CSI ++ "22m";
pub const Underline = CSI ++ "4m";
pub const NoUnderline = CSI ++ "24m";
pub const ResetColors = CSI ++ "m";
pub const ClearLine = CSI ++ "K";
pub const ErrorColor = CSI ++ "91m";
