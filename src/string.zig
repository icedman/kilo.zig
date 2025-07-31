//! Module with functions handling strings, for allocation and processing.

///////////////////////////////////////////////////////////////////////////////
//
//                              Functions
//
///////////////////////////////////////////////////////////////////////////////

/// Allocate a new string, fill it with some content and return it.
pub fn dup(allocator: Allocator, src: []const u8) ![]u8 {
    const buf = try allocator.alloc(u8, src.len);
    @memcpy(buf, src);
    return buf;
}

/// Reallocate `dst` to make `src` fit and return the slice.
pub fn copy(allocator: Allocator, dst: []u8, src: []const u8) ![]u8 {
    const buf = try allocator.realloc(dst, src.len);
    @memcpy(buf, src);
    return buf;
}

/// Count the occurrences of `needle` in `haystack`.
pub fn count(haystack: []const u8, needle: u8) usize {
    var n: usize = 0;
    for (haystack) |c| {
        if (c == needle) {
            n += 1;
        }
    }
    return n;
}

/// Return `true` if slices have the same content.
pub fn eql(a: []const u8, b: []const u8) bool {
    return mem.eql(u8, a, b);
}

/// Return `true` if the tail of haystack is exactly `needle`.
pub fn isTail(haystack: []const u8, needle: []const u8) bool {
    const idx = mem.lastIndexOfLinear(u8, haystack, needle);
    return idx != null and idx.? + needle.len == haystack.len;
}

/// Return the starting position of `needle` in haystack, starting from the end
/// of haystack, or `null` if needle is not found.
pub fn lastIndexOf(haystack: []const u8, needle: []const u8) ?usize {
    return mem.lastIndexOf(u8, haystack, needle);
}

/// Return the starting position of `needle` in haystack, or `null` if needle
/// is not found.
pub fn indexOf(haystack: []const u8, needle: []const u8) ?usize {
    return mem.indexOf(u8, haystack, needle);
}

/// Return the number of leading whitespace characters
pub fn leadingWhites(src: []u8) usize {
    var i: usize = 0;
    while (i < src.len and asc.isWhitespace(src[i])) : (i += 1) {}
    return i;
}

/// Get the extension of a filename.
pub fn getExtension(path: []u8) ?[]u8 {
    const ix = mem.lastIndexOfScalar(u8, path, '.');
    if (ix == null or ix == path.len - 1) {
        return null;
    }
    return path[ix.? + 1 ..];
}

/// Return true if character is a separator (not a word character).
pub fn isSeparator(c: u8) bool {
    return switch (c) {
        ' ', '\t' => true,
        '0'...'9', 'a'...'z', 'A'...'Z', '_' => false,
        else => true,
    };
}

/// Return true if character is a word character.
pub fn isWord(c: u8) bool {
    return switch (c) {
        '0'...'9', 'a'...'z', 'A'...'Z', '_' => true,
        else => false,
    };
}

/// Return true if character is valid for a file name.
pub fn isFilenameChar(c: u8) bool {
    return !asc.isControl(c) and c < 128;
}

///////////////////////////////////////////////////////////////////////////////
//
//                              Constants/variables
//
///////////////////////////////////////////////////////////////////////////////

const std = @import("std");
const asc = std.ascii;
const mem = std.mem;
const Allocator = mem.Allocator;
