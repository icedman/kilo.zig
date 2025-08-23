const std = @import("std");
const txmt = @import("textmate");

const oni = txmt.oni;

const ThemeLibrary = txmt.ThemeLibrary;
const Theme = txmt.Theme;
const GrammarLibrary = txmt.GrammarLibrary;
const Grammar = txmt.Grammar;
const Parser = txmt.Parser;
const ParseState = txmt.ParseState;
const Processor = txmt.Processor;

pub const ParseCapture = txmt.ParseCapture;
pub const ThemeColors = txmt.ThemeColors;
pub const Rgb = txmt.Rgb;

// Kilo's Chars
const Chars = std.ArrayList(u8);

const StateContextSerial = struct { u64, u64, u64, u64 };
const LineParseData = struct {
    state: std.ArrayList(StateContextSerial),
    valid: bool = false,

    pub fn init(allocator: std.mem.Allocator) !LineParseData {
        return LineParseData{
            .state = std.ArrayList(StateContextSerial).init(allocator),
        };
    }

    pub fn deinit(self: *LineParseData) void {
        self.state.deinit();
    }
};

fn hashQuads(quads: []const struct { u64, u64, u64, u64 }) u64 {
    var hasher = std.hash.Wyhash.init(0); // seed can be 0 or something else
    hasher.update(std.mem.sliceAsBytes(quads));
    return hasher.final();
}

pub const Textmate = struct {
    allocator: std.mem.Allocator,
    theme: Theme = undefined,
    grammar: Grammar = undefined,
    parser: Parser = undefined,
    parse_state: ParseState = undefined,
    processor: Processor = undefined,
    ready: bool = false,
    line_data: std.ArrayList(LineParseData),
    previous_ix: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !Textmate {
        try oni.init(&.{oni.Encoding.utf8});

        var theme: Theme = undefined;

        ThemeLibrary.initLibrary(allocator) catch {
            return error.UnableToLoadResources;
        };
        errdefer ThemeLibrary.deinitLibrary();
        if (ThemeLibrary.getLibrary()) |thl| {
            thl.addEmbeddedThemes() catch {
                std.debug.print("unable to add embedded themes\n", .{});
            };
            theme = thl.themeFromName("dracula") catch {
                return error.UnableToLoadResources;
            };
        }
        GrammarLibrary.initLibrary(allocator) catch {
            return error.UnableToLoadResources;
        };
        errdefer GrammarLibrary.deinitLibrary();
        if (GrammarLibrary.getLibrary()) |gml| {
            gml.addEmbeddedGrammars() catch {
                std.debug.print("unable to add embedded grammars\n", .{});
            };
        }

        return Textmate{
            .allocator = allocator,
            .theme = theme,
            .line_data = std.ArrayList(LineParseData).init(allocator),
        };
    }

    pub fn deinit(self: *Textmate) void {
        if (self.ready) {
            self.theme.deinit();
            self.grammar.deinit();
            self.parser.deinit();
            self.parse_state.deinit();
            self.processor.deinit();
        }
        ThemeLibrary.deinitLibrary();
        GrammarLibrary.deinitLibrary();
        for (self.line_data.items) |*item| {
            item.deinit();
        }
        self.line_data.deinit();
    }

    pub fn setup(self: *Textmate, path: []const u8) void {
        if (GrammarLibrary.getLibrary()) |gml| {
            self.ready = false;
            self.grammar = gml.grammarFromExtension(path) catch {
                return;
            };
            errdefer self.grammar.deinit();
            self.parser = Parser.init(self.allocator, &self.grammar) catch {
                return;
            };
            errdefer self.parser.deinit();
            self.parse_state = self.parser.initState() catch {
                return;
            };
            errdefer self.parse_state.deinit();
            self.processor = txmt.NullProcessor.init(self.allocator) catch {
                return;
            };
            self.parser.processor = &self.processor;
            self.processor.theme = &self.theme;
            self.ready = true;
        }
    }

    pub fn touch(self: *Textmate, ix: usize) void {
        while (self.line_data.items.len < ix) {
            const ln = LineParseData.init(self.allocator) catch {};
            self.line_data.append(ln) catch {};
            break;
        }
    }

    pub fn invalidate(self: *Textmate, ix: usize) void {
        self.touch(ix + 100);
        for (ix..self.line_data.items.len, 0..) |i, ctr| {
            self.line_data.items[i].valid = false;
            _ = ctr;
            break;
        }
    }

    pub fn updateLine(self: *Textmate, ix: usize, block: Chars) !bool {
        if (!self.ready) return false;
        // no need to re-render
        if (self.line_data.items[ix].valid) return false;

        var buffer: [1024]u8 = [_]u8{0} ** 1024;
        @memcpy(buffer[0..block.items.len], block.items);
        buffer[block.items.len] = '\n';

        if (self.previous_ix + 1 == ix) {
            if (self.line_data.items[self.previous_ix].valid) {
                try self.parser.deserialize(&self.parse_state, &self.line_data.items[self.previous_ix].state);
            }
        }

        const previous_hash = blk: {
            if (self.line_data.items[ix].valid) {
                break :blk hashQuads(self.line_data.items[ix].state.items);
            } else break :blk 0;
        };

        try self.parser.parseLine(&self.parse_state, &buffer);
        try self.parser.serialize(&self.parse_state, &self.line_data.items[ix].state);
        self.line_data.items[ix].valid = true;
        self.previous_ix = ix;

        const current_hash = blk: {
            if (self.line_data.items[ix].valid) {
                break :blk hashQuads(self.line_data.items[ix].state.items);
            } else break :blk 0;
        };

        return previous_hash != current_hash;
    }
};
