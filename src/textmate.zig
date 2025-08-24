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

pub const StateContextSerial = struct { u64, u64, u64, u64 };
pub const LineParseData = struct {
    state: std.ArrayList(StateContextSerial),
    starting_hash: u64 = 0,
    hash: u64 = 0,
    valid: bool = false,

    pub fn init(allocator: std.mem.Allocator) !LineParseData {
        return LineParseData{
            .state = std.ArrayList(StateContextSerial).init(allocator),
        };
    }

    pub fn deinit(self: *const LineParseData) void {
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

    pub fn updateLine(self: *Textmate, ix: usize, block: Chars, previous_parse: ?*LineParseData, current_line_parse: *LineParseData) !bool {
        if (!self.ready) return false;
        // no need to re-render
        _ = ix;

        const previous_hash = current_line_parse.hash;
        var previous_lines_hash_changed = false;
        if (previous_parse) |pp| {
            if (pp.valid) {
                if (current_line_parse.starting_hash != pp.hash) {
                    try self.parser.deserialize(&self.parse_state, &pp.state);
                    current_line_parse.starting_hash = pp.hash;
                    previous_lines_hash_changed = true;
                }
            }
        }
        
        if (current_line_parse.valid and !previous_lines_hash_changed) return false;
        
        var buffer: [1024]u8 = [_]u8{0} ** 1024;
        @memcpy(buffer[0..block.items.len], block.items);
        buffer[block.items.len] = '\n';

        try self.parser.parseLine(&self.parse_state, &buffer);
        try self.parser.serialize(&self.parse_state, &current_line_parse.state);
        current_line_parse.valid = true;
        current_line_parse.hash = hashQuads(current_line_parse.state.items);

        return previous_hash != current_line_parse.hash;
    }
};
