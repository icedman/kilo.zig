const std = @import("std");
const builtin = @import("builtin");
const linux = @import("linux.zig");
const editor = @import("editor.zig");
const types = @import("types.zig");
const ansi = @import("ansi.zig");

var orig_termios: std.os.linux.termios = undefined;

/// Our panic handler disables terminal raw mode and calls the default panic
/// handler.
fn crashed(msg: []const u8, trace: ?usize) noreturn {
    linux.disableRawMode(orig_termios);
    std.debug.defaultPanic(msg, trace);
}

pub const panic = std.debug.FullPanic(crashed);

pub fn main() !void {
    orig_termios = try linux.enableRawMode();
    defer linux.disableRawMode(orig_termios);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = switch (builtin.mode) {
        .Debug => gpa.allocator(),
        else => std.heap.smp_allocator,
    };

    try editor.init(allocator, try ansi.getWindowSize());
    defer editor.deinit();

    var args = std.process.args();
    _ = args.next(); // ignore first arg

    try editor.startUp(args.next()); // possible file to open
}
