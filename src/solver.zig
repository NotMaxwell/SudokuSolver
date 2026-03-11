const std = @import("std");

pub const SudokuError = error{
    InvalidLength,
    InvalidCharacter,
    InvalidPuzzle,
    Unsolvable,
    MissingArgument,
    InvalidArgument,
    CsvFormatError,
    UnsupportedSize,
};

/// Returns the integer square root of n, or null if n is not a perfect square.
pub fn isqrt(n: usize) ?usize {
    if (n == 0) return 0;
    var s: usize = 1;
    while (s * s < n) s += 1;
    if (s * s == n) return s;
    return null;
}

/// A Sudoku board parameterized by `size` (e.g. 9 for classic, 16, 25, 100).
/// Requires `size` to be a perfect square so box_size = sqrt(size) is integral.
/// Values are stored as u16 (covers all supported sizes up to 128).
/// Bitmasks use u128, supporting up to 128 distinct values.
pub fn Board(comptime size: comptime_int) type {
    comptime {
        if (size < 1 or size > 128) @compileError("Board size must be between 1 and 128");
        if (isqrt(@intCast(size)) == null) @compileError("Board size must be a perfect square");
    }

    return struct {
        const Self = @This();
        pub const SIZE: usize = @intCast(size);
        pub const BOX_SIZE: usize = isqrt(@intCast(size)).?;
        pub const CELL_COUNT: usize = SIZE * SIZE;
        /// Bitmask with the lowest `size` bits set (bit i-1 represents value i).
        pub const FULL_MASK: u128 = (@as(u128, 1) << @intCast(SIZE)) - 1;

        /// Cell values: 0 = empty, 1..SIZE = filled.
        cells: [CELL_COUNT]u16,
        row_mask: [SIZE]u128,
        col_mask: [SIZE]u128,
        box_mask: [SIZE]u128,

        pub fn initEmpty() Self {
            return .{
                .cells = [_]u16{0} ** CELL_COUNT,
                .row_mask = [_]u128{0} ** SIZE,
                .col_mask = [_]u128{0} ** SIZE,
                .box_mask = [_]u128{0} ** SIZE,
            };
        }

        /// Parse a puzzle string.
        ///   size <= 9 : dense ASCII digits, '0' or '.' = empty
        ///   size > 9  : comma-separated decimal integers, '0' or '.' = empty
        pub fn fromString(input: []const u8) SudokuError!Self {
            if (SIZE <= 9) {
                return fromDenseString(input);
            } else {
                return fromDelimitedString(input);
            }
        }

        fn fromDenseString(input: []const u8) SudokuError!Self {
            if (input.len != CELL_COUNT) return SudokuError.InvalidLength;
            var board = Self.initEmpty();
            var i: usize = 0;
            while (i < CELL_COUNT) : (i += 1) {
                const ch = input[i];
                if (ch == '0' or ch == '.') continue;
                if (ch < '1' or ch > '0' + SIZE) return SudokuError.InvalidCharacter;
                const value: u16 = ch - '0';
                const row = i / SIZE;
                const col = i % SIZE;
                if (!board.canPlace(row, col, value)) return SudokuError.InvalidPuzzle;
                board.place(row, col, value);
            }
            return board;
        }

        fn fromDelimitedString(input: []const u8) SudokuError!Self {
            var board = Self.initEmpty();
            var cell: usize = 0;
            var i: usize = 0;
            while (i < input.len and cell < CELL_COUNT) {
                while (i < input.len and (input[i] == ',' or input[i] == ' ' or
                    input[i] == '\n' or input[i] == '\r' or input[i] == '\t'))
                {
                    i += 1;
                }
                if (i >= input.len) break;

                if (input[i] == '.') {
                    cell += 1;
                    i += 1;
                    continue;
                }

                const start = i;
                while (i < input.len and input[i] >= '0' and input[i] <= '9') : (i += 1) {}
                if (i == start) return SudokuError.InvalidCharacter;

                const token = input[start..i];
                const value = std.fmt.parseUnsigned(u16, token, 10) catch return SudokuError.InvalidCharacter;
                if (value > SIZE) return SudokuError.InvalidCharacter;

                if (value != 0) {
                    const row = cell / SIZE;
                    const col = cell % SIZE;
                    if (!board.canPlace(row, col, value)) return SudokuError.InvalidPuzzle;
                    board.place(row, col, value);
                }
                cell += 1;
            }

            // Consume trailing whitespace/commas
            while (i < input.len and (input[i] == ',' or input[i] == ' ' or
                input[i] == '\n' or input[i] == '\r' or input[i] == '\t'))
            {
                i += 1;
            }

            if (cell != CELL_COUNT) return SudokuError.InvalidLength;
            return board;
        }

        inline fn cellIndex(row: usize, col: usize) usize {
            return row * SIZE + col;
        }

        inline fn boxIndex(row: usize, col: usize) usize {
            return (row / BOX_SIZE) * BOX_SIZE + (col / BOX_SIZE);
        }

        inline fn bit(value: u16) u128 {
            return @as(u128, 1) << @intCast(value - 1);
        }

        pub fn get(self: *const Self, row: usize, col: usize) u16 {
            return self.cells[cellIndex(row, col)];
        }

        fn set(self: *Self, row: usize, col: usize, value: u16) void {
            self.cells[cellIndex(row, col)] = value;
        }

        pub fn canPlace(self: *const Self, row: usize, col: usize, value: u16) bool {
            const used = self.row_mask[row] | self.col_mask[col] | self.box_mask[boxIndex(row, col)];
            return (used & bit(value)) == 0;
        }

        pub fn place(self: *Self, row: usize, col: usize, value: u16) void {
            const b = bit(value);
            self.set(row, col, value);
            self.row_mask[row] |= b;
            self.col_mask[col] |= b;
            self.box_mask[boxIndex(row, col)] |= b;
        }

        pub fn remove(self: *Self, row: usize, col: usize, value: u16) void {
            const b = bit(value);
            self.set(row, col, 0);
            self.row_mask[row] &= ~b;
            self.col_mask[col] &= ~b;
            self.box_mask[boxIndex(row, col)] &= ~b;
        }

        pub fn candidatesMask(self: *const Self, row: usize, col: usize) u128 {
            const used = self.row_mask[row] | self.col_mask[col] | self.box_mask[boxIndex(row, col)];
            return FULL_MASK & ~used;
        }

        /// Serialize solved board to a digit string (allocated; caller frees).
        ///   size <= 9 : one ASCII digit per cell, no separator
        ///   size > 9  : comma-separated decimal numbers
        pub fn toDigitString(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
            if (SIZE <= 9) {
                const buf = try allocator.alloc(u8, CELL_COUNT);
                for (self.cells, 0..) |v, idx| {
                    buf[idx] = @intCast(v + '0');
                }
                return buf;
            } else {
                var list = std.ArrayList(u8).empty;
                for (self.cells, 0..) |v, idx| {
                    if (idx > 0) try list.append(allocator, ',');
                    try std.fmt.format(list.writer(allocator), "{d}", .{v});
                }
                return list.toOwnedSlice(allocator);
            }
        }

        pub fn print(self: *const Self) void {
            var row: usize = 0;
            while (row < SIZE) : (row += 1) {
                if (row != 0 and row % BOX_SIZE == 0) {
                    var sc: usize = 0;
                    while (sc < SIZE) : (sc += 1) {
                        if (sc != 0 and sc % BOX_SIZE == 0) std.debug.print("+", .{});
                        std.debug.print("--", .{});
                    }
                    std.debug.print("\n", .{});
                }
                var col: usize = 0;
                while (col < SIZE) : (col += 1) {
                    if (col != 0 and col % BOX_SIZE == 0) std.debug.print("| ", .{});
                    const value = self.get(row, col);
                    if (SIZE <= 9) {
                        if (value == 0) {
                            std.debug.print(". ", .{});
                        } else {
                            std.debug.print("{d} ", .{value});
                        }
                    } else {
                        std.debug.print("{d:>4} ", .{value});
                    }
                }
                std.debug.print("\n", .{});
            }
        }
    };
}

pub fn Solver(comptime size: comptime_int) type {
    const B = Board(size);
    return struct {
        const Self = @This();
        board: B,

        pub fn init(board: B) Self {
            return .{ .board = board };
        }

        pub fn solve(self: *Self) bool {
            const next = self.findBestCell() orelse return true;
            if (next.mask == 0) return false;

            var mask = next.mask;
            while (mask != 0) {
                const low_bit = mask & (~mask +% 1);
                const value: u16 = @as(u16, @intCast(@ctz(low_bit))) + 1;

                self.board.place(next.row, next.col, value);
                if (self.solve()) return true;
                self.board.remove(next.row, next.col, value);

                mask &= mask - 1;
            }

            return false;
        }

        const BestCell = struct {
            row: usize,
            col: usize,
            mask: u128,
        };

        fn findBestCell(self: *const Self) ?BestCell {
            var found = false;
            var best_row: usize = 0;
            var best_col: usize = 0;
            var best_mask: u128 = 0;
            var best_count: u32 = B.SIZE + 1;

            var row: usize = 0;
            while (row < B.SIZE) : (row += 1) {
                var col: usize = 0;
                while (col < B.SIZE) : (col += 1) {
                    if (self.board.get(row, col) != 0) continue;

                    const mask = self.board.candidatesMask(row, col);
                    const count: u32 = @popCount(mask);

                    if (count == 0) {
                        return .{ .row = row, .col = col, .mask = 0 };
                    }

                    if (!found or count < best_count) {
                        found = true;
                        best_row = row;
                        best_col = col;
                        best_mask = mask;
                        best_count = count;

                        if (count == 1) {
                            return .{ .row = best_row, .col = best_col, .mask = best_mask };
                        }
                    }
                }
            }

            if (!found) return null;
            return .{ .row = best_row, .col = best_col, .mask = best_mask };
        }
    };
}

//  Convenience aliases

pub const Board4 = Board(4);
pub const Board9 = Board(9);
pub const Board16 = Board(16);
pub const Board25 = Board(25);
pub const Board36 = Board(36);
pub const Board49 = Board(49);
pub const Board64 = Board(64);
pub const Board81 = Board(81);
pub const Board100 = Board(100);

pub const Solver4 = Solver(4);
pub const Solver9 = Solver(9);
pub const Solver16 = Solver(16);
pub const Solver25 = Solver(25);
pub const Solver36 = Solver(36);
pub const Solver49 = Solver(49);
pub const Solver64 = Solver(64);
pub const Solver81 = Solver(81);
pub const Solver100 = Solver(100);

//  Shared helpers

const CsvStats = struct {
    attempted: usize = 0,
    solved: usize = 0,
    matched: usize = 0,
    unsolved: usize = 0,
    parse_errors: usize = 0,
    mismatches: usize = 0,
};

const CsvDebugConfig = struct {
    max_detailed_logs: usize = 5,
    row_result_log_limit: usize = 20,
};

fn truncForLog(value: []const u8, max_len: usize) []const u8 {
    if (value.len <= max_len) return value;
    return value[0..max_len];
}

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  solver --puzzle "<puzzle string>" [--compact] [--size <n>]
        \\  solver --csv <path> [--limit <n>] [--size <n>]
        \\
        \\Options:
        \\  --puzzle   Solve a single puzzle
        \\  --compact  Output only the compact solution string (no grid)
        \\  --csv      Solve puzzles from a CSV file (puzzle,solution columns)
        \\  --limit    Max puzzles from CSV (default: 100)
        \\  --size     Board size: 4, 9, 16, 25, 36, 49, 64, 81, 100.
        \\             Auto-detected from puzzle length when omitted.
        \\
        \\Puzzle string formats:
        \\  size 4, 9   : dense digits (e.g. "530070000..." for 9x9)
        \\  size >=16   : comma-separated numbers (e.g. "0,1,0,9,..." for 16x16)
        \\  '0' or '.'  = empty cell in both formats
        \\
    , .{});
}

fn parseUsize(value: []const u8) SudokuError!usize {
    return std.fmt.parseUnsigned(usize, value, 10) catch SudokuError.InvalidArgument;
}

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trimRight(u8, line, "\r");
}

/// Infer board size from a puzzle string.
fn inferSize(puzzle: []const u8) ?usize {
    const len = puzzle.len;
    if (std.mem.indexOfScalar(u8, puzzle, ',') == null) {
        // Dense format: length must equal size*size for size <= 9
        const s = isqrt(len) orelse return null;
        if (s <= 9) return s;
        return null;
    }
    // Delimited: count tokens (commas + 1)
    var count: usize = 1;
    for (puzzle) |ch| {
        if (ch == ',') count += 1;
    }
    return isqrt(count);
}

fn runSinglePuzzleForSize(comptime size: usize, puzzle: []const u8, compact: bool, allocator: std.mem.Allocator) !void {
    const B = Board(size);
    const S = Solver(size);

    const board = B.fromString(puzzle) catch |err| {
        switch (err) {
            SudokuError.InvalidLength => std.debug.print("Error: puzzle must be {d} cells for a {d}x{d} board.\n", .{ B.CELL_COUNT, size, size }),
            SudokuError.InvalidCharacter => std.debug.print("Error: invalid characters in puzzle.\n", .{}),
            SudokuError.InvalidPuzzle => std.debug.print("Error: conflicting givens in puzzle.\n", .{}),
            else => std.debug.print("Error parsing puzzle: {any}\n", .{err}),
        }
        return err;
    };

    if (!compact) {
        std.debug.print("Input puzzle ({d}x{d}):\n", .{ size, size });
        board.print();
        std.debug.print("\n", .{});
    }

    var solver = S.init(board);

    if (solver.solve()) {
        if (compact) {
            const out = try solver.board.toDigitString(allocator);
            defer allocator.free(out);
            var stdout_buf: [65536]u8 = undefined;
            var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
            try stdout_writer.interface.print("{s}\n", .{out});
            try stdout_writer.interface.flush();
        } else {
            std.debug.print("Solved:\n", .{});
            solver.board.print();
        }
    } else {
        std.debug.print("Error: puzzle is unsolvable.\n", .{});
        return SudokuError.Unsolvable;
    }
}

fn runSinglePuzzle(puzzle: []const u8, compact: bool, size_hint: ?usize, allocator: std.mem.Allocator) !void {
    const size = size_hint orelse inferSize(puzzle) orelse {
        std.debug.print("Error: could not auto-detect size from puzzle length {d}. Use --size.\n", .{puzzle.len});
        return SudokuError.InvalidArgument;
    };
    switch (size) {
        4 => try runSinglePuzzleForSize(4, puzzle, compact, allocator),
        9 => try runSinglePuzzleForSize(9, puzzle, compact, allocator),
        16 => try runSinglePuzzleForSize(16, puzzle, compact, allocator),
        25 => try runSinglePuzzleForSize(25, puzzle, compact, allocator),
        36 => try runSinglePuzzleForSize(36, puzzle, compact, allocator),
        49 => try runSinglePuzzleForSize(49, puzzle, compact, allocator),
        64 => try runSinglePuzzleForSize(64, puzzle, compact, allocator),
        81 => try runSinglePuzzleForSize(81, puzzle, compact, allocator),
        100 => try runSinglePuzzleForSize(100, puzzle, compact, allocator),
        else => {
            std.debug.print("Error: unsupported board size {d}. Supported: 4,9,16,25,36,49,64,81,100.\n", .{size});
            return SudokuError.UnsupportedSize;
        },
    }
}

fn runCsvModeForSize(comptime size: usize, csv_path: []const u8, limit: usize, allocator: std.mem.Allocator) !void {
    const B = Board(size);
    const S = Solver(size);

    const debug_config = CsvDebugConfig{};
    const progress_every: usize = if (limit <= 100) 1 else if (limit <= 1000) 100 else 1000;

    const file = try std.fs.cwd().openFile(csv_path, .{});
    defer file.close();

    var buf: [1024]u8 = undefined;
    var reader = file.reader(&buf);

    const header_opt = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => return SudokuError.CsvFormatError,
        else => return err,
    };
    const header = header_opt orelse return SudokuError.CsvFormatError;
    const trimmed_header = trimLine(header);

    const known1 = std.mem.eql(u8, trimmed_header, "puzzle,solution");
    const known2 = std.mem.eql(u8, trimmed_header, "quizzes,solutions");
    if (!known1 and !known2) {
        std.debug.print("Warning: unexpected CSV header: {s}\n", .{trimmed_header});
    }

    std.debug.print("CSV: file={s} size={d}x{d} limit={d}\n", .{ csv_path, size, size, limit });

    var stats = CsvStats{};
    const start_ns = std.time.nanoTimestamp();
    var csv_line_number: usize = 1;

    while (stats.attempted < limit) {
        const line_opt = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                stats.parse_errors += 1;
                continue;
            },
            else => return err,
        };
        const line = line_opt orelse break;
        csv_line_number += 1;

        const trimmed = trimLine(line);
        if (trimmed.len == 0) continue;

        // Find the comma that splits puzzle from solution.
        // Dense (size<=9): first comma splits two CELL_COUNT-char strings.
        // Delimited (size>9): puzzle occupies CELL_COUNT comma-separated tokens,
        //   so split at the (CELL_COUNT)-th comma.
        const split_idx: usize = blk: {
            if (size <= 9) {
                break :blk std.mem.indexOfScalar(u8, trimmed, ',') orelse {
                    stats.parse_errors += 1;
                    continue;
                };
            } else {
                var comma_count: usize = 0;
                var idx: usize = 0;
                while (idx < trimmed.len) : (idx += 1) {
                    if (trimmed[idx] == ',') {
                        comma_count += 1;
                        if (comma_count == B.CELL_COUNT) break :blk idx;
                    }
                }
                stats.parse_errors += 1;
                continue;
            }
        };

        const puzzle_str = trimmed[0..split_idx];
        const solution_str = trimmed[split_idx + 1 ..];

        stats.attempted += 1;

        if (stats.attempted % progress_every == 0) {
            const now = std.time.nanoTimestamp();
            const elapsed_ns: i128 = now - start_ns;
            const rate: i128 = if (elapsed_ns > 0)
                @divTrunc(@as(i128, @intCast(stats.attempted)) * 1_000_000_000, elapsed_ns)
            else
                0;
            std.debug.print(
                "progress: {d}/{d} solved:{d} matched:{d} rate:{d}/s\n",
                .{ stats.attempted, limit, stats.solved, stats.matched, rate },
            );
        }

        const board = B.fromString(puzzle_str) catch {
            stats.parse_errors += 1;
            if (stats.parse_errors <= debug_config.max_detailed_logs) {
                std.debug.print(
                    "detail[parse_error #{d}] csv_line={d} sample=\"{s}\"\n",
                    .{ stats.parse_errors, csv_line_number, truncForLog(puzzle_str, 40) },
                );
            }
            continue;
        };

        var solver = S.init(board);

        if (!solver.solve()) {
            stats.unsolved += 1;
            if (stats.unsolved <= debug_config.max_detailed_logs) {
                std.debug.print(
                    "detail[unsolved #{d}] csv_line={d} sample=\"{s}\"\n",
                    .{ stats.unsolved, csv_line_number, truncForLog(puzzle_str, 40) },
                );
            }
            continue;
        }

        stats.solved += 1;

        const solved_str = try solver.board.toDigitString(allocator);
        defer allocator.free(solved_str);

        if (std.mem.eql(u8, solved_str, solution_str)) {
            stats.matched += 1;
        } else {
            stats.mismatches += 1;
            if (stats.mismatches <= debug_config.max_detailed_logs) {
                std.debug.print(
                    "detail[mismatch #{d}] csv_line={d} got=\"{s}\" expected=\"{s}\"\n",
                    .{
                        stats.mismatches,
                        csv_line_number,
                        truncForLog(solved_str, 32),
                        truncForLog(solution_str, 32),
                    },
                );
            }
        }
    }

    const elapsed_ns: i128 = std.time.nanoTimestamp() - start_ns;
    const elapsed_ms = @divTrunc(elapsed_ns, 1_000_000);

    std.debug.print("CSV run complete.\n", .{});
    std.debug.print("attempted:  {d}\n", .{stats.attempted});
    std.debug.print("solved:     {d}\n", .{stats.solved});
    std.debug.print("matched:    {d}\n", .{stats.matched});
    std.debug.print("unsolved:   {d}\n", .{stats.unsolved});
    std.debug.print("parse_err:  {d}\n", .{stats.parse_errors});
    std.debug.print("mismatch:   {d}\n", .{stats.mismatches});
    std.debug.print("elapsed_ms: {d}\n", .{elapsed_ms});
    if (stats.attempted > 0) {
        const avg_us = @divTrunc(elapsed_ns, @as(i128, @intCast(stats.attempted)) * 1_000);
        std.debug.print("avg_us_per_puzzle: {d}\n", .{avg_us});
    }
}

fn runCsvMode(csv_path: []const u8, limit: usize, size: usize, allocator: std.mem.Allocator) !void {
    switch (size) {
        4 => try runCsvModeForSize(4, csv_path, limit, allocator),
        9 => try runCsvModeForSize(9, csv_path, limit, allocator),
        16 => try runCsvModeForSize(16, csv_path, limit, allocator),
        25 => try runCsvModeForSize(25, csv_path, limit, allocator),
        36 => try runCsvModeForSize(36, csv_path, limit, allocator),
        49 => try runCsvModeForSize(49, csv_path, limit, allocator),
        64 => try runCsvModeForSize(64, csv_path, limit, allocator),
        81 => try runCsvModeForSize(81, csv_path, limit, allocator),
        100 => try runCsvModeForSize(100, csv_path, limit, allocator),
        else => {
            std.debug.print("Error: unsupported board size {d}.\n", .{size});
            return SudokuError.UnsupportedSize;
        },
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var puzzle_arg: ?[]const u8 = null;
    var csv_arg: ?[]const u8 = null;
    var limit: usize = 100;
    var compact: bool = false;
    var size_arg: ?usize = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--puzzle")) {
            puzzle_arg = args.next() orelse return SudokuError.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--compact")) {
            compact = true;
        } else if (std.mem.eql(u8, arg, "--csv")) {
            csv_arg = args.next() orelse return SudokuError.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            const value = args.next() orelse return SudokuError.MissingArgument;
            limit = try parseUsize(value);
        } else if (std.mem.eql(u8, arg, "--size")) {
            const value = args.next() orelse return SudokuError.MissingArgument;
            size_arg = try parseUsize(value);
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else {
            std.debug.print("Error: unknown argument: {s}\n\n", .{arg});
            printUsage();
            return SudokuError.InvalidArgument;
        }
    }

    if (puzzle_arg != null and csv_arg != null) {
        std.debug.print("Error: use either --puzzle or --csv, not both.\n\n", .{});
        printUsage();
        return SudokuError.InvalidArgument;
    }

    if (puzzle_arg) |puzzle| {
        try runSinglePuzzle(puzzle, compact, size_arg, allocator);
        return;
    }

    if (csv_arg) |csv_path| {
        const size = size_arg orelse 9;
        try runCsvMode(csv_path, limit, size, allocator);
        return;
    }

    printUsage();
}
