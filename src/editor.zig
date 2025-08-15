//! Here are managed most of the editor functionalities.
//! Later it would be useful to make it only a container for the main window,
//! the statusline and the message area, and manage other functionalities
//! (buffer, key processing, etc) in separate modules.
//!
//! Note that there is a single instance of Editor, so it is statically
//! allocated. For now there is also a single buffer and a single window, so
//! they are also statically allocated.

var alc: std.mem.Allocator = undefined;

var E: t.Editor = undefined;
var V: t.View = undefined;
var B: t.Buffer = undefined;

///////////////////////////////////////////////////////////////////////////////
//
//                              Init/deinit
//
///////////////////////////////////////////////////////////////////////////////

/// Initialize the editor variables.
pub fn init(allocator: std.mem.Allocator, screen: t.Screen) !void {
    alc = allocator; // for now, the only allocator we'll ever use

    E.just_started = true;
    E.screen.rows = screen.rows - 2; // make room for statusline/statusMsg
    E.screen.cols = screen.cols;
    E.statusMsg = Chars.init(alc);
    E.welcomeMsg = Chars.init(alc);
    B = t.Buffer.init(alc);
}

/// Deinitialize the editor.
pub fn deinit() void {
    E.statusMsg.deinit();
    E.welcomeMsg.deinit();
    B.deinit();
}

/// Start up the editor: open the path in args if valid, start the event loop.
pub fn startUp(path: ?[]const u8) !void {
    try setStatusMessage(message.status.get("help").?, .{});
    if (path) |name| {
        const ms = time_ms();
        try openFile(name);
        std.debug.print("{s} loaded in {}ms\n", .{name, time_ms() - ms});
    }
    else {
        E.welcomeMsg = try getWelcome();
    }
    while (E.should_quit == false) {
        try refreshScreen();
        try processKeypress();
    }
}

///////////////////////////////////////////////////////////////////////////////
//
//                              File operations
//
///////////////////////////////////////////////////////////////////////////////

/// Open a file with `path`.
fn openFile(path: []const u8) !void {
    B.filename = try updateFilename(B.filename, path);
    B.syntax = try selectSyntax();

    // read lines if the file could be opened
    const file = linux.openFileHandle(path, .{ .mode = .read_only });
    if (file) |f| {
        defer f.close();
        try readLines(f);
    }
    else |err| switch (err) {
        error.FileNotFound => {}, // new unsaved file
        else => return ioerr(err),
    }

    B.dirty = false;
}

/// Try to save the current file, prompt for a file name if currently not set.
/// Currently saving the file fails if directory doesn't exist, and there is no
/// tilde expansion.
fn saveFile() !void {
    if (B.filename == null) {
        const al = try promptString(message.prompt.get("fname").?, .{}, null);
        defer al.deinit();

        if (al.items.len > 0) {
            B.filename = try updateFilename(B.filename, al.items);
        }
        else {
            try setStatusMessage("Save aborted", .{});
            return;
        }
    }

    B.syntax = try selectSyntax();

    // create an ArrayList with the file contents
    var buf = Chars.init(alc);
    defer buf.deinit();

    for (B.rows.items) |row| {
        try buf.appendSlice(row.chars.items);
        try buf.append('\n');
    }

    const file = linux.writeFileHandle(B.filename.?, .{ .truncate = true });
    if (file) |f| {
        defer f.close();
        f.writer().writeAll(buf.items) catch |err| return ioerr(err);
        try setStatusMessage(message.status.get("bufwrite").?, .{buf.items.len});
        B.dirty = false;
        return;
    }
    else |err|{
        alc.free(B.filename.?);
        B.filename = null;
        return ioerr(err);
    }
}

/// Read all lines from file.
fn readLines(file: std.fs.File) !void {
    var buffered = std.io.bufferedReader(file.reader());
    const reader = buffered.reader();

    while(try reader.readUntilDelimiterOrEofAlloc(alc, '\n', maxUsize)) |line| {
        defer alc.free(line);
        try insertRow(B.rows.items.len, line);
    }
}

/// Handle an error of type FileError by printing an error message, without
/// quitting the editor.
fn ioerr(err: t.FileError) !void {
    try setErrorMessage(message.errors.get("ioerr").?, .{@errorName(err)});
    return;
}

///////////////////////////////////////////////////////////////////////////////
//
//                              Row operations
//
///////////////////////////////////////////////////////////////////////////////

/// Insert a row at index `ix` with content `line`, then update it.
fn insertRow(ix: usize, line: []const u8) t.EditorError!void {
    var row = t.Row.init(alc);
    try row.chars.appendSlice(line);

    try B.rows.insert(ix, row);

    try updateRow(ix);
    B.dirty = true;
}

/// Delete a row and deinitialize it.
fn delRow(ix: usize) void {
    const row = B.rows.orderedRemove(ix);
    row.deinit();
    B.dirty = true;
}

/// Update row.render, that is the visual representation of the row.
/// Performs a syntax update at the end.
fn updateRow(ix: usize) !void {
    const row = rowAt(ix);
    const tabs = str.count(row.chars.items, '\t');
    const TS = opt.tabstop;

    // Each tab must be converted to spaces, and each can take up to (but not
    // necessarily as much) TABSTOP space characters. So we increase the amount
    // to allocate by the number of tabs, multiplied by (TABSTOP - 1),
    // subtracting one because one tab counts for one character in row.chars,
    // and it will be removed. Note that we don't use NUL terminator.
    const rsize = row.len() + tabs * (TS - 1);
    row.render = try alc.realloc(row.render, rsize);

    var idx: usize = 0;
    var i: usize = 0;

    while (i < row.len()) : (i += 1) {
        if (row.at(i) == '\t') {
            row.render[idx] = ' ';
            idx += 1;
            while (idx % TS != 0) {
                row.render[idx] = ' ';
                idx += 1;
            }
        }
        else {
            row.render[idx] = row.at(i);
            idx += 1;
        }
    }

    try updateSyntax(ix);
}

///////////////////////////////////////////////////////////////////////////////
//
//                              Keys processing
//
///////////////////////////////////////////////////////////////////////////////

/// Process a keypress: will wait indefinitely for readKey, that loops until
/// a key is actually pressed.
fn processKeypress() !void {
    const k = try readKey();

    const static = struct {
        var q: u8 = opt.quit_times;
        var verbatim: bool = false;
    };

    if (static.verbatim) {
        static.verbatim = false;
        try insertChar(@intFromEnum(k));
        return;
    }

    switch (k) {
        .enter => try insertNewLine(),

        .ctrl_k => static.verbatim = true,

        .ctrl_f => try find(),

        .ctrl_q => {
            if (B.dirty and static.q > 0) {
                try setStatusMessage(message.status.get("unsaved").?, .{static.q});
                static.q -= 1;
                return;
            }
            try ansi.clearScreen();
            E.should_quit = true;
        },

        .ctrl_s => try saveFile(),

        .page_up, .page_down => {
            switch (k) {
                .page_up => V.cy = V.rowoff,
                else => {
                    V.cy = V.rowoff + E.screen.rows - 1;
                    V.cy = @min(V.cy, B.rows.items.len);
                },
            }
            var times = E.screen.rows - 1;
            while (times > 0) : (times -= 1) {
                moveCursorWithKey(if (k == .page_up) .up else .down);
            }
        },

        .home => V.cx = 0,

        .end => {
            if (V.cy < B.rows.items.len) {
                V.cx = B.rows.items[V.cy].len();
            }
        },

        .backspace, .ctrl_h, .del => {
            if (k == .del) {
                moveCursorWithKey(.right);
            }
            try delChar();
        },

        .left, .right, .up, .down => moveCursorWithKey(k),

        else => {
            const c = @intFromEnum(k);
            if (k == .tab or asc.isPrint(c)) {
                try insertChar(c);
            }
        },
    }

    // reset quit counter for any keypress that isn't Ctrl-Q
    static.q = opt.quit_times;
}

/// Read a character from stdin. Wait until at least one character is
/// available.
fn readKey() !t.Key {
    var c: u8 = undefined;
    try linux.readAtLeastOneChar(&c);

    const k: t.Key = @enumFromInt(c);

    if (k == .esc) {
        var seq: [3]u8 = undefined;
        _ = linux.readChar(&seq[0]) catch return .esc;
        _ = linux.readChar(&seq[1]) catch return .esc;

        if (seq[0] == '[') {
            if (asc.isDigit(seq[1])) {
                _ = linux.readChar(&seq[2]) catch return .esc;
                if (seq[2] == '~') {
                    switch (seq[1]) {
                        '1' => return .home,
                        '3' => return .del,
                        '4' => return .end,
                        '5' => return .page_up,
                        '6' => return .page_down,
                        '7' => return .home,
                        '8' => return .end,
                        else => {},
                    }
                }
            }
            switch (seq[1]) {
                'A' => return .up,
                'B' => return .down,
                'C' => return .right,
                'D' => return .left,
                'H' => return .home,
                'F' => return .end,
                else => {},
            }
        }
        else if (seq[0] == 'O') {
            switch (seq[1]) {
                'H' => return .home,
                'F' => return .end,
                else => {},
            }
        }
        return .esc;
    }
    switch (k) {
        .ctrl_d => return .page_down,
        .ctrl_u => return .page_up,
        else => {},
    }
    return k;
}

///////////////////////////////////////////////////////////////////////////////
//
//                              In-row operations
//
///////////////////////////////////////////////////////////////////////////////

/// Insert a character at current cursor position. Handle textwidth.
fn insertChar(c: u8) !void {
    // last row, insert a new row before inserting the character
    if (V.cy == B.rows.items.len) {
        try insertRow(B.rows.items.len, "");
    }

    // first, insert the character
    try rowInsertChar(V.cy, V.cx, c);
    V.cx += 1;

    //////////////////////////////////////////
    //              textwidth
    //////////////////////////////////////////

    if (V.cx > opt.textwidth and str.isWord(c)) {
        const row = rowAt(V.cy);
        const chars = row.chars.items;

        // will be 1 if a space before the wrapped word must be removed
        var skipw: usize = 0;

        // find the start of the current word
        var start: usize = V.cx - 1;

        while (start > 0) {
            if (!str.isWord(chars[start - 1])) {
                // we want to remove a space before the wrapped word, but not
                // other kinds of separators (not even a tab, just in case)
                if (chars[start - 1] == ' ') {
                    skipw = 1;
                }
                break;
            }
            start -= 1;
        }

        // only wrap if the word doesn't start at the beginning
        if (start > 0) {
            //            \/ text width
            //      word1 word2|  -> move cursor at start of the word
            //      word1 |word2  -> new line insertion
            //      word1 $
            //      |word2$
            //      word1$        -> deleted space before wrapped word
            //      word2|        -> move cursor at end of the word
            //
            const wlen = V.cx - start;
            V.cx = start - skipw;
            try insertNewLine();
            V.cx += wlen;
        }
    }
}

/// Insert character `c` in the row with index `ix`, at column `at`.
fn rowInsertChar(ix: usize, at: usize, c: u8) !void {
    try rowAt(ix).chars.insert(at, c);
    try updateRow(ix);
    B.dirty = true;
}

/// Delete a character before cursor position (backspace).
fn delChar() !void {
    if (V.cy == B.rows.items.len) {  // past the end of the file
        return;
    }
    if (V.cx == 0 and V.cy == 0) {
        return;
    }

    const row = rowAt(V.cy);

    if (V.cx > 0)  // delete character in current line
    {
        try rowDelChar(V.cy, V.cx - 1);
        V.cx -= 1;
    }
    else  // join with previous line
    {
        V.cx = B.rows.items[V.cy - 1].len();
        try rowAppendString(V.cy - 1, row.chars.items);
        delRow(V.cy);
        V.cy -= 1;
    }
}

/// Delete a character in the row with index `ix`, at column `at`.
fn rowDelChar(ix: usize, at: usize) !void {
    _ = rowAt(ix).chars.orderedRemove(at);
    try updateRow(ix);
    B.dirty = true;
}

/// Append a string to the end of the row at index `ix`.
fn rowAppendString(ix: usize, chars: []const u8) !void {
    try rowAt(ix).chars.appendSlice(chars);
    try updateRow(ix);
    B.dirty = true;
}

///////////////////////////////////////////////////////////////////////////////
//
//                              Insert lines
//
///////////////////////////////////////////////////////////////////////////////

/// Insert `n` lines above cursor position.
fn insertLinesAbove(n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try insertRow(V.cy, "");
        V.cy += 1;
    }
    V.cx = 0;
}

/// Insert `n` lines below cursor position.
fn insertLinesBelow(n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        V.cy += 1;
        try insertRow(V.cy, "");
    }
    V.cx = 0;
}

/// Insert a new line at cursor position. Will carry to the next line
/// everything that is after the cursor.
fn insertNewLine() !void {
    // make sure the beginning of the line is visible
    V.coloff = 0;

    // at first column, just insert an empty line above the cursor
    if (V.cx == 0) {
        try insertLinesAbove(1);
        return;
    }

    //**********************************************************
    //
    // we have to figure out how the new line will differ:
    //
    // 1. if there is indentation to add (or to remove)
    //
    // 2. if there is white space that should be skipped, eg:
    //          word| word$     ENTER->      word$
    //                                       |word
    //
    //**********************************************************

    var i: usize = 0;
    var ind: usize = 0; // extra chars for indent
    var skipw: usize = 0; // leading whitespace removed from text moved to new line

    var oldrow = rowAt(V.cy).chars.items;

    if (opt.autoindent) {
        ind = str.leadingWhites(oldrow);

        // any whitespace before the text that is going into the new row
        if (V.cx < oldrow.len) {
            skipw = str.leadingWhites(oldrow[V.cx..]);
        }

        // if the cursor lies in the middle of the indent, shorten the indent:
        //
        // ~  |  word$  ->
        // ~  |word$
        //
        // This doesn't happen if cursor is at column 1, because that case is
        // handled at the top of the function.
        if (V.cx < ind) {
            ind = V.cx;
        }
    }

    // will insert a row with the characters to the right of the cursor
    // if any whitespace was skipped, cut that too
    try insertRow(V.cy + 1, oldrow[V.cx + skipw..]);

    // proceed to the new row
    V.cy += 1;

    // currently this is positive only if opt.autoindent is enabled
    // things might change in the future if more options are added
    if (ind > 0) {
        // reassign pointer, invalidated by row insertion
        oldrow = rowAt(V.cy - 1).chars.items;

        // in new row, shift the old content forward, to make room for indent
        const newrow = try rowAt(V.cy).chars.addManyAt(0, ind);

        if (opt.autoindent) {
            // Copy the indent from the previous row.
            i = 0;
            while (i < ind) : (i += 1) {
                newrow[i] = oldrow[i];
            }
        }
    }

    // cut from the row above the content that we moved to the next row
    // we do this after indent has been copied!
    rowAt(V.cy - 1).chars.shrinkAndFree(V.cx);

    // row operations have been concluded, time to update rows
    try updateRow(V.cy - 1);
    try updateRow(V.cy);

    // set cursor position right after the indent in the new line
    V.cx = ind;
    V.cwant = ind;
}

///////////////////////////////////////////////////////////////////////////////
//
//                              Find
//
///////////////////////////////////////////////////////////////////////////////

/// Start the search prompt.
fn find() !void {
    const saved = saveView(V);
    const query = try promptString("/", saved, findCallback);
    query.deinit();
}

/// Called by promptString() for every valid inserted character.
/// The saved view is restored when the current query isn't found, or when
/// backspace clears the query, so that the search starts from the original
/// position.
fn findCallback(ca: t.PromptCbArgs) t.CbRetv {
    const static = struct {
        var direction: t.Direction = .forward;
        var found: bool = false;
        var view: t.View = undefined;
        var lnum: usize = 0;
        var match: []t.Highlight = &.{};
    };

    const empty = ca.input.items.len == 0;
    const numrows = B.rows.items.len;

    var col: usize = undefined;
    var line: usize = undefined;

    // restore line highlight before incsearch highlight, or clean up
    if (static.match.len > 0) {
        @memcpy(rowAt(static.lnum).hl, static.match);
    }

    // clean up
    if (ca.final) {
        alc.free(static.match);
        static.match = &.{};
        static.direction = .forward;
        if (empty or ca.key == .esc) {
            V = ca.saved;
        }
        if (!static.found and ca.key == .enter) {
            try setStatusMessage("No match found", .{});
        }
        static.found = false;
        return;
    }

    // Query is empty so no need to search, but restore position
    if (empty) {
        V = ca.saved;
        return;
    }

    // when pressing backspace we restore the previously saved view
    // cursor might move or not, depending on whether there is a match at
    // cursor position
    if (ca.key == .backspace or ca.key == .ctrl_h) {
        V = static.view;
    }

    const next = ca.key == .ctrl_g;
    const prev = ca.key == .ctrl_t;

    static.direction = if (prev) .backward else .forward;

    //----------------------------------------------------------------------
    // Find the starting line and the column offset for the search
    //----------------------------------------------------------------------

    const is_last_char_in_row = V.rx == rowAt(V.cy).rlen();

    // search in progress
    const stay_put = static.found or !empty and ca.key == .backspace;

    // must move the cursor forward before searching when we don't want to
    // match at cursor position
    const step_fwd = !stay_put and static.direction == .forward;

    if (step_fwd or next) {
        if (V.cy == numrows // past end of file
            or (V.cy == numrows - 1 and is_last_char_in_row)) // last row
        {
            if (opt.wrapscan) { // restart from the beginning of the file
                col = 0;
                line = 0;
            }
            else {
                return;
            }
        }
        else if (is_last_char_in_row) { // start searching from next line
            col = 0;
            line = V.cy + 1;
        }
        else { // start searching after current column
            col = V.rx + 1;
            line = V.cy;
        }
    }
    else {
        col = V.rx;
        line = V.cy;
    }

    //----------------------------------------------------------------------
    // Start the search
    //----------------------------------------------------------------------

    var match: ?[]const u8 = null;
    var match_lnr = line;

    if (static.direction == .forward) {
        match = findForward(ca.input.items, &match_lnr, col);
    }
    else {
        match = findBackward(ca.input.items, &match_lnr, col);
    }

    const row = rowAt(match_lnr);
    static.found = match != null;

    if (match) |m| {
        V.cy = match_lnr;
        V.rx = &m[0] - &row.render[0];
        V.cx = rxToCx(row, V.rx);
        std.debug.print("match: |{s}| at {},{}\n", .{m, match_lnr, V.rx});

        static.view = saveView(V);

        // do the highlight, but first make a copy of current highlight
        static.lnum = match_lnr;
        static.match = try alc.realloc(static.match, row.render.len);
        @memcpy(static.match, row.hl);
        @memset(row.hl[V.rx..V.rx + ca.input.items.len], t.Highlight.match);
    }
    else if (next or prev) {
        // the next match wasn't found in the searching direction
        // we still set the highlight for the current match, since the original
        // highlight has been restored at the top of the function
        @memset(row.hl[V.rx..V.rx + ca.input.items.len], t.Highlight.match);
    }
    else {
        // a match wasn't found because the input couldn't be found
        // restore the original view (from before the start of the search)
        V = ca.saved;
    }
}

/// Start a search forwards.
fn findForward(query: []const u8, lnr: *usize, col: usize) ?[]const u8 {
    var off = col;
    var i = lnr.*;

    while (i < B.rows.items.len) : (i += 1) {
        const rowchars = rowAt(i).render;

        if (str.indexOf(rowchars[off..], query)) |m| {
            lnr.* = i;
            return rowchars[(off + m)..(off + m + query.len)];
        }

        off = 0; // reset search column
    }

    if (!opt.wrapscan) {
        return null;
    }

    // wrapscan enabled, search from start of the file to current row
    i = 0;
    while (i <= lnr.*) : (i += 1) {
        const rowchars = rowAt(i).render;

        if (str.indexOf(rowchars, query)) |m| {
            lnr.* = i;
            return rowchars[m..m + query.len];
        }
    }
    return null;
}

/// Start a search backwards.
fn findBackward(query: []const u8, lnr: *usize, col: usize) ?[]const u8 {
    // first line, search up to col
    var rowchars = rowAt(lnr.*).render;
    var i: usize = undefined;

    if (str.lastIndexOf(rowchars[0..col], query)) |m| {
        return rowchars[m..m + query.len];
    }
    else if (lnr.* > 0) {
        // previous lines, search full line
        i = lnr.* - 1;
        while (true) : (i -= 1) {
            rowchars = rowAt(i).render;

            if (str.lastIndexOf(rowchars, query)) |m| {
                lnr.* = i;
                return rowchars[m..m + query.len];
            }
            if (i == 0) break;
        }
    }

    if (!opt.wrapscan) {
        return null;
    }

    i = B.rows.items.len - 1;
    while (i > lnr.*) : (i -= 1) {
        rowchars = rowAt(i).render;

        if (str.lastIndexOf(rowchars, query)) |m| {
            lnr.* = i;
            return rowchars[m..m + query.len];
        }
    }

    // check again the starting line, this time in the part after the offset
    rowchars = rowAt(lnr.*).render;

    if (str.lastIndexOf(rowchars[col..], query)) |m| {
        // m is the index in the substring starting from `col`, therefore we
        // must add `col` to get the real index in the row
        return rowchars[(m + col)..(m + col + query.len)];
    }
    else {
        return null;
    }
}

///////////////////////////////////////////////////////////////////////////////
//
//                              t.View operations
//
///////////////////////////////////////////////////////////////////////////////

/// Update the cursor position after a key has been pressed.
fn moveCursorWithKey(key: t.Key) void {
    const numrows = B.rows.items.len;

    switch (key) {
        .left => {
            if (V.cx != 0) {
                V.cx -= 1;
            }
            else if (V.cy > 0) {
                V.cy -= 1;
                V.cx = rowAt(V.cy).len();
            }
        },
        .right => {
            if (V.cy < numrows) {
                const row = rowAt(V.cy);
                if (V.cx < row.len()) {
                    V.cx += 1;
                }
                else {
                    V.cy += 1;
                    V.cx = 0;
                }
            }
        },
        .up => {
            if (V.cy != 0) {
                V.cy -= 1;
            }
        },
        .down => {
            if (V.cy < numrows) {
                V.cy += 1;
            }
        },
        else => {},
    }

    // respect wanted column if possible
    if (key == .up or key == .down) {
        if (V.cy == numrows) { // past end of file
            V.cx = 0;
        }
        else {
            const row = rowAt(V.cy);
            const rowlen = row.len();
            if (rowlen == 0) {
                V.cx = 0;
            }
            else {
                V.cx = rxToCx(row, V.cwant);
                if (V.cx > rowlen) {
                    V.cx = rowlen;
                }
            }
        }
    }
    else if (key == .right or key == .left) {
        V.cwant = if (V.cy < numrows) cxToRx(rowAt(V.cy), V.cx) else 0;
    }
}

/// Scroll the view, respecting scroll_off.
fn scroll() void {
    const numrows = B.rows.items.len;

    if (opt.scroll_off > 0 and numrows > E.screen.rows) {
        while (V.rowoff + E.screen.rows < numrows
               and V.cy + opt.scroll_off >= E.screen.rows + V.rowoff)
        {
            V.rowoff += 1;
        }
        while (V.rowoff > 0 and V.rowoff + opt.scroll_off > V.cy) {
            V.rowoff -= 1;
        }
    }

    V.rx = 0;
    if (V.cy < numrows) {
        V.rx = cxToRx(rowAt(V.cy), V.cx);
    }

    // cursor is above the visible window
    if (V.cy < V.rowoff) {
        V.rowoff = V.cy;
    }
    // cursor is below the visible window
    if (V.cy >= V.rowoff + E.screen.rows) {
        V.rowoff = V.cy - E.screen.rows + 1;
    }
    // cursor goes beyond the left edge of the window
    if (V.rx < V.coloff) {
        V.coloff = V.rx;
    }
    // cursor goes beyond the right edge of the window
    if (V.rx >= V.coloff + E.screen.cols) {
        V.coloff = V.rx - E.screen.cols + 1;
    }
}

/// Calculate the position of the current column in the rendered row.
fn cxToRx(row: *t.Row, cx: usize) usize {
    var rx: usize = 0;
    var i: usize = 0;
    while (i < cx) : (i += 1) {
        if (row.at(i) == '\t') {
            rx += (opt.tabstop - 1) - (rx % opt.tabstop);
        }
        rx += 1;
    }
    return rx;
}

/// Calculate the position of the current visual column in the actual row.
fn rxToCx(row: *t.Row, rx: usize) usize {
    var cur_rx: usize = 0;
    var cx: usize = 0;
    while (cx < row.len()) : (cx += 1) {
        if (row.at(cx) == '\t') {
            cur_rx += (opt.tabstop - 1) - (cur_rx % opt.tabstop);
        }
        cur_rx += 1;

        if (cur_rx > rx) {
            return cx;
        }
    }
    return cx;
}

/// Return a copy of the current view.
fn saveView(v: t.View) t.View {
    return t.View {
        .cx = v.cx,
        .rx = v.rx,
        .cy = v.cy,
        .cwant = v.rx, // no point in preserving cwant here
        .coloff = v.coloff,
        .rowoff = v.rowoff,
    };
}

///////////////////////////////////////////////////////////////////////////////
//
//                              Screen update
//
///////////////////////////////////////////////////////////////////////////////

/// Full refresh of the screen.
fn refreshScreen() !void {
    scroll();

    var ab = Chars.init(alc);
    defer ab.deinit();

    try ab.appendSlice(ansi.BgColor);
    try ab.appendSlice(ansi.HideCursor);
    try ab.appendSlice(ansi.CursorTopLeft);

    try drawRows(&ab);
    try drawStatusline(&ab);
    try drawMessageBar(&ab);

    // move cursor to its current position (could have been moved with keys)
    var buf: [32]u8 = undefined;
    const row = V.cy - V.rowoff + 1;
    const col = V.rx - V.coloff + 1;
    try ab.appendSlice(try ansi.moveCursorTo(&buf, row, col));

    try ab.appendSlice(ansi.ShowCursor);

    try ansi.printToScreen(ab);
}

/// Append rows to be drawn to the `ab` slice. Handles escape sequences for
/// syntax highlighting.
fn drawRows(ab: *Chars) !void {
    var has_reverse = false;
    var has_bold = false;
    var has_underline = false;

    const rows = B.rows.items;

    var y: usize = 0;

    while (y < E.screen.rows) : (y += 1) {
        const ix: usize = y + V.rowoff;

        if (ix >= rows.len)  // past buffer content
        {
            if (E.just_started and y == E.screen.rows / 3) {
                E.just_started = false;
                try ab.appendSlice(E.welcomeMsg.items);
            }
            else {
                try ab.append('~');
            }
        }
        else  // within buffer content
        {
            // `len` is the length of the rendered part of the line
            const rowlen = rows[ix].render.len;
            var len = if (V.coloff > rowlen) 0 else rowlen - V.coloff;
            len = @min(len, E.screen.cols);

            // visible part of the line and its highlight
            const rline = if (len > 0) rows[ix].render[V.coloff..] else &.{};
            const hl = if (len > 0) rows[ix].hl[V.coloff..] else &.{};

            var current_color = t.Highlight.normal;

            var j: usize = 0;
            while (j < len) : (j += 1) {
                if (asc.isControl(rline[j])) {
                    const c = rline[j];
                    // for example, turn Ctrl-A into 'A' with reversed colors
                    const symbol = if (c <= 26) '@' + c else '?';
                    if (!has_reverse) {
                        try ab.appendSlice(ansi.InvertColors);
                        try ab.append(symbol);
                        try ab.appendSlice(ansi.ReverseColors);
                    }
                    else {
                        try ab.appendSlice(ansi.ReverseColors);
                        try ab.append(symbol);
                        try ab.appendSlice(ansi.InvertColors);
                    }
                }
                else if (hl[j] != current_color) {
                    const color = hl[j];
                    current_color = color;
                    const hlg = syndefs.hlGroups[@intFromEnum(color)];
                    try ab.appendSlice(hlg.attr);
                    if (hlg.reverse and !has_reverse) {
                        try ab.appendSlice(ansi.InvertColors);
                        has_reverse = true;
                    }
                    else if (!hlg.reverse and has_reverse) {
                        try ab.appendSlice(ansi.ReverseColors);
                        has_reverse = false;
                    }
                    if (hlg.bold and !has_bold) {
                        try ab.appendSlice(ansi.Bold);
                        has_bold = true;
                    }
                    else if (!hlg.bold and has_bold) {
                        try ab.appendSlice(ansi.NoBold);
                        has_bold = false;
                    }
                    if (hlg.underline and !has_underline) {
                        try ab.appendSlice(ansi.Underline);
                        has_underline = true;
                    }
                    else if (!hlg.underline and has_underline) {
                        try ab.appendSlice(ansi.NoUnderline);
                        has_underline = false;
                    }
                }
                try ab.append(rline[j]);
            }
            try ab.appendSlice(ansi.FgColor);
        }

        try ab.appendSlice(ansi.ClearLine);
        try ab.appendSlice("\r\n");  // end the line
    }
}

/// Append the statusline to the `ab` slice.
fn drawStatusline(ab: *Chars) !void {
    try ab.appendSlice(ansi.InvertColors);

    var lbuf: [200]u8 = undefined;
    var rbuf: [80]u8 = undefined;

    var left = try std.fmt.bufPrint(
        &lbuf,
        "{s} - {} lines {s}", .{
            getStatuslineFilename(),
            B.rows.items.len,
            if (B.dirty) "[modified]" else ""
        });

    const right = try std.fmt.bufPrint(
        &rbuf,
        "{s} | col {}, ln {}/{} ", .{
            if (B.syntax) |syntax| syntax else "no ft",
            V.cx + 1,
            V.cy + 1,
            B.rows.items.len
        });

    if (left.len > E.screen.cols) {
        left = left[0..E.screen.cols];
    }
    try ab.appendSlice(left);

    var len = left.len;

    while (len < E.screen.cols) {
        if (E.screen.cols - len > right.len) { // left side
            try ab.append(' ');
            len += 1;
        }
        else {
            try ab.appendSlice(right);
            break;
        }
    }

    try ab.appendSlice(ansi.ResetColors);
    try ab.appendSlice("\r\n"); // next line will be the message area
}

/// Append the message bar to the `ab` slice.
fn drawMessageBar(ab: *Chars) !void {
    try ab.appendSlice(ansi.ClearLine);

    var msglen = E.statusMsg.items.len;
    if (msglen > E.screen.cols) {
        msglen = E.screen.cols;
    }
    if (msglen > 0 and time() - E.statusMsgTime < 5) {
        try ab.appendSlice(E.statusMsg.items);
    }
}

///////////////////////////////////////////////////////////////////////////////
//
//                              Message area
//
///////////////////////////////////////////////////////////////////////////////

/// Start a prompt in the message area, return the user input.
/// At each keypress, the prompt callback is invoked, with a final invocation
/// after the prompt has been terminated with either .esc or .enter keys.
/// Prompt is also terminated by .backspace if there is no character left in
/// the input.
fn promptString(prompt: []const u8, saved: t.View, cb: ?t.PromptCb) !Chars {
    var al = Chars.init(alc);

    var k: t.Key = undefined;
    var c: u8 = undefined;
    var cb_args: t.PromptCbArgs = undefined;

    while (true) {
        try setStatusMessage("{s}{s}", .{prompt, al.items});
        try refreshScreen();

        k = try readKey();
        c = @intFromEnum(k);
        cb_args = .{ .input = &al, .key = k, .saved = saved };

        // after a break, callback will be called one last time,
        // with .final = true
        switch (k) {
            .ctrl_h, .backspace => {
                if (al.items.len == 0) {
                    break;
                }
                _ = al.pop();
            },

            .esc, .enter => break,

            else => if (asc.isPrint(c)) {
                try al.append(c);
            },

        }

        try promptCallback(cb, cb_args);
    }

    clearStatusMessage();
    cb_args.final = true;
    try promptCallback(cb, cb_args);
    return al;
}

/// Invoke the optional callback for the promptString function.
fn promptCallback(cb: ?t.PromptCb, args: t.PromptCbArgs) !void {
    if (cb) |callback| {
        try callback(args);
    }
}

/// Set a status message, using regular highlight.
pub fn setStatusMessage(comptime format: []const u8, args: anytype) !void {
    E.statusMsg.clearRetainingCapacity();
    if (format.len > 0) {
        const buf = try std.fmt.allocPrint(alc, format, args);
        defer alc.free(buf);
        try E.statusMsg.appendSlice(buf);
        E.statusMsgTime = time();
    }
}

/// Print an error message, using error highlight.
pub fn setErrorMessage(comptime format: []const u8, args: anytype) !void {
    std.debug.assert(format.len > 0);
    E.statusMsg.clearRetainingCapacity();
    const buf = try std.fmt.allocPrint(alc, format, args);
    defer alc.free(buf);
    try E.statusMsg.appendSlice(ansi.ErrorColor);
    try E.statusMsg.appendSlice(buf);
    try E.statusMsg.appendSlice(ansi.ResetColors);
    E.statusMsgTime = time();
}

///////////////////////////////////////////////////////////////////////////////
//
//                              Syntax highlighting
//
///////////////////////////////////////////////////////////////////////////////

/// Return the syntax name for the current file, or null.
fn selectSyntax() !?[]const u8 {
    t.freeOptional(alc, B.syntax);
    B.syntax = null;

    // we might allow setting a syntax even without a filename, actually...
    if (B.filename == null) {
        return null;
    }

    const extension = str.getExtension(B.filename.?);

    for (&syndefs.Syntaxes) |*syntax| {
        if (extension) |e| {
            for (syntax.ft_ext) |ext| {
                if (str.eql(ext, e)) {
                    B.syndef = syntax;
                    return try str.dup(alc, syntax.ft_name);
                }
            }
        }
        for (syntax.ft_files) |name| {
            if (str.eql(B.filename.?, name) or str.isTail(B.filename.?, name)) {
                B.syndef = syntax;
                return try str.dup(alc, syntax.ft_name);
            }
        }
    }
    return null;
}

/// Apply syntax highlighting to a row.
fn updateSyntax(ix: usize) !void {
    const row = rowAt(ix);

    row.hl = try alc.realloc(row.hl, row.render.len);
    @memset(row.hl, t.Highlight.normal);

    if (B.syntax == null or opt.syntax == false) {
        return;
    }

    // length of the rendered row
    const rowlen = row.render.len;

    const s = B.syndef.?;
    const cl = s.lcmt;
    const cb = s.mlcmt;
    const flags = s.flags;

    // character is preceded by a separator
    var prev_sep = true;

    // character is preceded by a backslash
    var escaped = false;

    // character is inside a string or char literal
    var in_string = false;
    var in_char = false;
    var delimiter: u8 = 0;

    // character is in a ML comment
    var in_mlcomment = ix > 0 and B.rows.items[ix - 1].ml_comment_start;

    // all keywords in the syntax definition, along with the highlight they use
    const keywords = [_]struct {
        kws: []const []const u8, // array of string with keywords
        hl: t.Highlight,
    }{
        .{ .kws = s.keywords, .hl = t.Highlight.keyword },
        .{ .kws = s.types, .hl = t.Highlight.types },
        .{ .kws = s.builtin, .hl = t.Highlight.builtin },
        .{ .kws = s.constant, .hl = t.Highlight.constant },
        .{ .kws = s.preproc, .hl = t.Highlight.preproc },
    };

    var prev_hl = t.Highlight.normal;

    var i: usize = 0;
    toplevel: while (i < rowlen) {
        if (asc.isWhitespace(row.render[i])) {
            prev_sep = true;
            i += 1;
            continue;
        }

        prev_hl = if (i > 0) row.hl[i - 1] else t.Highlight.normal;

        // ML comments
        if (cb.len > 0 and !in_string) {
            if (in_mlcomment) {
                const len = cb[2].len;
                row.hl[i] = t.Highlight.mlcomment;

                if (i + len <= rowlen and str.eql(row.render[i..i + len], cb[2])) { // END
                    @memset(row.hl[i..i + len], t.Highlight.mlcomment);
                    i += len;
                    in_mlcomment = false;
                    prev_sep = true;
                    continue;
                }
                else {
                    i += 1;
                    continue;
                }

            }
            else {
                const len = cb[0].len;

                if (i + len <= rowlen and str.eql(row.render[i..i + len], cb[0])) { // START
                    @memset(row.hl[i..i + len], t.Highlight.mlcomment);
                    i += len;
                    in_mlcomment = true;
                    continue;
                }
            }
        }

        // single-line comment
        if (cl.len > 0 and !in_string and !in_mlcomment) {
            for (cl) |ldr| {
                if (i + ldr.len <= rowlen and str.eql(row.render[i..i + ldr.len], ldr)) {
                    @memset(row.hl[i..], t.Highlight.comment);
                    break :toplevel;
                }
            }
        }

        if (flags.strings) {
            if (in_string or in_char) {
                if (escaped or row.render[i] == '\\') {
                    escaped = !escaped;
                    row.hl[i] = if (in_char) t.Highlight.number else t.Highlight.escape;
                }
                else {
                    row.hl[i] = if (in_char) t.Highlight.number else t.Highlight.string;
                    if (row.render[i] == delimiter) {
                        in_string = false;
                        in_char = false;
                    }
                }
                i += 1;
                prev_sep = true;
                continue;
            }
            else if (flags.dquotes and row.render[i] == '"') {
                in_string = true;
                delimiter = row.render[i];
                row.hl[i] = t.Highlight.string;
                i += 1;
                continue;
            }
            else if (flags.squotes and row.render[i] == '\'') {
                in_string = true;
                delimiter = row.render[i];
                row.hl[i] = t.Highlight.string;
                i += 1;
                continue;
            }
            else if (flags.chars and row.render[i] == '\'') {
                in_char = true;
                delimiter = row.render[i];
                row.hl[i] = t.Highlight.number;
                i += 1;
                continue;
            }
        }

        // numbers
        if (flags.numbers and prev_sep) {
            var prev_digit = false;
            var is_float = false;
            var has_exp = false;
            var is_hex = false;
            var is_bin = false;
            var is_octal = false;
            var NaN = false;

            const begin = i;

            // hex, binary, octal notations
            if (i + 1 < rowlen) {
                if (row.render[i] == '0') {
                    switch (row.render[i + 1]) {
                        'x' => if (flags.hex) {
                            is_hex = true;
                            i += 2;
                        },
                        'b' => if (flags.bin) {
                            is_bin = true;
                            i += 2;
                        },
                        'o' => if (flags.octal) {
                            is_octal = true;
                            i += 2;
                        },
                        else => {},
                    }
                }
            }

            // accept consecutive digits, or a dot followed by a number
            while (true) : (i += 1) {
                if (i == rowlen) break;

                switch (row.render[i]) {
                    '0'...'1' => prev_digit = true,

                    // invalid for binary numbers
                    '2'...'7' => {
                        if (!is_bin) {
                            prev_digit = true;
                        }
                        else {
                            prev_digit = false;
                            break;
                        }
                    },

                    // invalid for binary and octal numbers
                    '8'...'9' => {
                        if (!is_bin and !is_octal) {
                            prev_digit = true;
                        }
                        else {
                            prev_digit = false;
                            break;
                        }
                    },

                    // underscores as delimiters in numeric literals
                    '_' => {
                        if (prev_digit and flags.uscn) {
                            prev_digit = false;
                        }
                        else {
                            break;
                        }
                    },

                    // could be an exponent, or a hex digit
                    'e', 'E' => {
                        if (is_float and !has_exp) {
                            has_exp = true;
                            prev_digit = false;
                        }
                        else if (is_hex) {
                            prev_digit = true;
                        }
                        else {
                            break;
                        }
                    },

                    // hex digits
                    'a'...'d', 'f', 'A'...'D', 'F' => {
                        if (is_hex) prev_digit = true else break;
                    },

                    // floating point
                    '.' => {
                        prev_sep = true;
                        prev_digit = false;
                        if (!is_float and !is_hex and !is_bin) {
                            is_float = true;
                        }
                        else {
                            break;
                        }
                    },

                    else => break,
                }
            }
            // previous separator could be invalid if any character was
            // processed
            prev_sep = i == begin or str.isSeparator(row.render[i - 1]);

            // no matter the type of number, last character should be a digit
            if (!prev_digit) {
                NaN = true;
            }
            // after our number comes something that isn't a separator
            else if (i != rowlen and !str.isSeparator(row.render[i])) {
                NaN = true;
            }
            if (!NaN) {
                for (begin..i) |idx| {
                    row.hl[idx] = t.Highlight.number;
                }
            }
        }
        if (i == rowlen) break;

        // keywords
        if (prev_sep) {
            for (keywords) |kws| {
                for (kws.kws) |kw| {
                    const kwend = i + kw.len; // index where keyword would end

                    if ( //                 separator is after keyword
                        (kwend < rowlen and str.isSeparator(row.render[kwend]))
                        or kwend == rowlen) // or end of string after keyword
                    {
                        if (str.eql(row.render[i..kwend], kw)) {
                            @memset(row.hl[i..kwend], kws.hl);
                            i += kw.len;
                            break;
                        }
                    }
                }
            }

            if (flags.uppercase) {
                var upper = false;
                const begin = i;
                while (i < rowlen and !str.isSeparator(row.render[i])) {
                    if (!asc.isUpper(row.render[i]) and row.render[i] != '_') {
                        upper = false;
                        break;
                    }
                    upper = true;
                    i += 1;
                }
                if (upper and i - begin > 1) {
                    @memset(row.hl[begin..i], t.Highlight.uppercase);
                }
            }

            prev_sep = false;
            continue;
        }

        prev_sep = str.isSeparator(row.render[i]);

        i += 1;
    }

    const changed = row.ml_comment_start != in_mlcomment;
    row.ml_comment_start = in_mlcomment;
    if (changed and ix + 1 < B.rows.items.len) {
        try updateSyntax(ix + 1);
    }
}

///////////////////////////////////////////////////////////////////////////////
//
//                              Helpers
//
///////////////////////////////////////////////////////////////////////////////

/// Filename as it will be displayed in the statusline.
fn getStatuslineFilename() []const u8 {
    if (B.filename) |name| {
        return name[0..@min(E.screen.cols * 2 / 3, name.len)];
    }
    return "[No Name]";
}

/// Update the filename, by (re)allocating from `path`.
fn updateFilename(filename: ?[]u8, path: []const u8) ![]u8 {
    if (filename) |name|
        return try str.copy(alc, name, path)
    else
        return try str.dup(alc, path);
}

/// Generate the welcome string.
fn getWelcome() !Chars {
    const msg = message.status.get("welcome").?;

    var welcome = Chars.init(alc);

    try welcome.append('~');

    const padding: usize =
        if (E.screen.cols < msg.len) 0 else (E.screen.cols - msg.len) / 2;
    for (0..padding) |_| {
        try welcome.append(' ');
    }
    try welcome.appendSlice(msg);
    if (welcome.items.len > E.screen.cols) {
        welcome.shrinkAndFree(E.screen.cols);
    }
    return welcome;
}

/// Get the row pointer at index `ix`.
fn rowAt(ix: usize) *t.Row {
    return &B.rows.items[ix];
}

/// Clear the message area. Can't fail because it won't reallocate.
fn clearStatusMessage() void {
    setStatusMessage("", .{}) catch {};
}

///////////////////////////////////////////////////////////////////////////////
//
//                              Imports, constants
//
///////////////////////////////////////////////////////////////////////////////

const std = @import("std");
const ansi = @import("ansi.zig");
const syndefs = @import("syndefs.zig");
const opt = @import("option.zig");
const t = @import("types.zig");
const message = @import("message.zig");
const str = @import("string.zig");
const linux = @import("linux.zig");

const asc = std.ascii;
const time = std.time.timestamp;
const time_ms = std.time.milliTimestamp;

const ArrayList = std.ArrayList;
const Chars = ArrayList(u8);

const maxUsize = std.math.maxInt(usize);
