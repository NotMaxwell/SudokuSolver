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
        const CELL_COUNT = B.CELL_COUNT;
        board: B,
        candidate_mask: [CELL_COUNT]u128,
        candidate_count: [CELL_COUNT]u8,

        const Placement = struct {
            row: usize,
            col: usize,
            value: u16,
        };

        const UnitSingle = struct {
            index: usize,
            value: u16,
        };

        pub fn init(board: B) Self {
            var self = Self{
                .board = board,
                .candidate_mask = [_]u128{0} ** CELL_COUNT,
                .candidate_count = [_]u8{0} ** CELL_COUNT,
            };
            self.recomputeAllCandidates();
            return self;
        }

        pub fn solve(self: *Self) bool {
            return self.search();
        }

        pub fn solveParallel(self: *Self) bool {
            var root = self.*;

            var placements: [CELL_COUNT]Placement = undefined;
            var placement_count: usize = 0;
            if (!root.propagateConstraints(&placements, &placement_count)) {
                return false;
            }

            const next = root.findBestCell() orelse {
                self.* = root;
                return true;
            };
            if (next.mask == 0) return false;

            var ordered_values: [B.SIZE]u16 = [_]u16{0} ** B.SIZE;
            const candidate_len = root.orderCandidatesLCV(next.row, next.col, next.mask, &ordered_values);
            if (candidate_len <= 1) {
                if (root.search()) {
                    self.* = root;
                    return true;
                }
                return false;
            }

            const ParallelSolveContext = struct {
                root: Self,
                row: usize,
                col: usize,
                found: bool = false,
                solution_board: B = B.initEmpty(),
                mutex: std.Thread.Mutex = .{},

                fn worker(ctx: *@This(), value: u16) void {
                    ctx.mutex.lock();
                    if (ctx.found) {
                        ctx.mutex.unlock();
                        return;
                    }
                    ctx.mutex.unlock();

                    var local = ctx.root;
                    local.board.place(ctx.row, ctx.col, value);
                    local.refreshAffected(ctx.row, ctx.col);

                    if (local.search()) {
                        ctx.mutex.lock();
                        if (!ctx.found) {
                            ctx.found = true;
                            ctx.solution_board = local.board;
                        }
                        ctx.mutex.unlock();
                    }
                }
            };

            var ctx = ParallelSolveContext{
                .root = root,
                .row = next.row,
                .col = next.col,
            };

            var threads: [B.SIZE]std.Thread = undefined;
            var spawned: usize = 0;
            var t: usize = 0;
            while (t < candidate_len) : (t += 1) {
                const value = ordered_values[t];
                const th = std.Thread.spawn(.{}, ParallelSolveContext.worker, .{ &ctx, value }) catch {
                    ParallelSolveContext.worker(&ctx, value);
                    continue;
                };
                threads[spawned] = th;
                spawned += 1;
            }

            t = 0;
            while (t < spawned) : (t += 1) {
                threads[t].join();
            }

            if (ctx.found) {
                self.board = ctx.solution_board;
                self.recomputeAllCandidates();
                return true;
            }

            return false;
        }

        const BestCell = struct {
            row: usize,
            col: usize,
            mask: u128,
        };

        inline fn rowOfIndex(index: usize) usize {
            return index / B.SIZE;
        }

        inline fn colOfIndex(index: usize) usize {
            return index % B.SIZE;
        }

        inline fn boxOfIndex(index: usize) usize {
            const row = rowOfIndex(index);
            const col = colOfIndex(index);
            return (row / B.BOX_SIZE) * B.BOX_SIZE + (col / B.BOX_SIZE);
        }

        fn recomputeAllCandidates(self: *Self) void {
            var idx: usize = 0;
            while (idx < CELL_COUNT) : (idx += 1) {
                self.refreshCandidateAt(idx);
            }
        }

        fn refreshCandidateAt(self: *Self, idx: usize) void {
            const row = rowOfIndex(idx);
            const col = colOfIndex(idx);
            if (self.board.get(row, col) != 0) {
                self.candidate_mask[idx] = 0;
                self.candidate_count[idx] = 0;
                return;
            }

            const mask = self.board.candidatesMask(row, col);
            self.candidate_mask[idx] = mask;
            self.candidate_count[idx] = @intCast(@popCount(mask));
        }

        fn refreshAffected(self: *Self, row: usize, col: usize) void {
            var c: usize = 0;
            while (c < B.SIZE) : (c += 1) {
                self.refreshCandidateAt(B.cellIndex(row, c));
            }

            var r: usize = 0;
            while (r < B.SIZE) : (r += 1) {
                if (r == row) continue;
                self.refreshCandidateAt(B.cellIndex(r, col));
            }

            const box_row_start = (row / B.BOX_SIZE) * B.BOX_SIZE;
            const box_col_start = (col / B.BOX_SIZE) * B.BOX_SIZE;
            r = box_row_start;
            while (r < box_row_start + B.BOX_SIZE) : (r += 1) {
                c = box_col_start;
                while (c < box_col_start + B.BOX_SIZE) : (c += 1) {
                    if (r == row or c == col) continue;
                    self.refreshCandidateAt(B.cellIndex(r, c));
                }
            }

            self.refreshCandidateAt(B.cellIndex(row, col));
        }

        fn applyPlacement(self: *Self, row: usize, col: usize, value: u16, placements: *[CELL_COUNT]Placement, placement_count: *usize) void {
            self.board.place(row, col, value);
            placements[placement_count.*] = .{ .row = row, .col = col, .value = value };
            placement_count.* += 1;
            self.refreshAffected(row, col);
        }

        fn revertPlacements(self: *Self, placements: *const [CELL_COUNT]Placement, start: usize, end: usize) void {
            var i = end;
            while (i > start) {
                i -= 1;
                const p = placements[i];
                self.board.remove(p.row, p.col, p.value);
                self.refreshAffected(p.row, p.col);
            }
        }

        fn findForcedNakedSingle(self: *const Self) ?UnitSingle {
            var idx: usize = 0;
            while (idx < CELL_COUNT) : (idx += 1) {
                if (self.candidate_count[idx] == 1) {
                    const value_idx = @as(usize, @intCast(@ctz(self.candidate_mask[idx])));
                    if (value_idx >= B.SIZE) continue;
                    const value: u16 = @intCast(value_idx + 1);
                    return .{ .index = idx, .value = value };
                }
            }
            return null;
        }

        fn findHiddenSingleInRow(self: *const Self, row: usize) ?UnitSingle {
            var counts: [B.SIZE]u8 = [_]u8{0} ** B.SIZE;
            var last_idx: [B.SIZE]usize = [_]usize{0} ** B.SIZE;

            var col: usize = 0;
            while (col < B.SIZE) : (col += 1) {
                const idx = B.cellIndex(row, col);
                const mask = self.candidate_mask[idx];
                if (mask == 0) continue;

                var bits = mask;
                while (bits != 0) {
                    const low_bit = bits & (~bits +% 1);
                    const value_idx = @as(usize, @intCast(@ctz(low_bit)));
                    if (value_idx < B.SIZE) {
                        counts[value_idx] +%= 1;
                        last_idx[value_idx] = idx;
                    }
                    bits &= bits - 1;
                }
            }

            var value_idx: usize = 0;
            while (value_idx < B.SIZE) : (value_idx += 1) {
                if (counts[value_idx] == 1) {
                    return .{ .index = last_idx[value_idx], .value = @intCast(value_idx + 1) };
                }
            }
            return null;
        }

        fn findHiddenSingleInCol(self: *const Self, col: usize) ?UnitSingle {
            var counts: [B.SIZE]u8 = [_]u8{0} ** B.SIZE;
            var last_idx: [B.SIZE]usize = [_]usize{0} ** B.SIZE;

            var row: usize = 0;
            while (row < B.SIZE) : (row += 1) {
                const idx = B.cellIndex(row, col);
                const mask = self.candidate_mask[idx];
                if (mask == 0) continue;

                var bits = mask;
                while (bits != 0) {
                    const low_bit = bits & (~bits +% 1);
                    const value_idx = @as(usize, @intCast(@ctz(low_bit)));
                    if (value_idx < B.SIZE) {
                        counts[value_idx] +%= 1;
                        last_idx[value_idx] = idx;
                    }
                    bits &= bits - 1;
                }
            }

            var value_idx: usize = 0;
            while (value_idx < B.SIZE) : (value_idx += 1) {
                if (counts[value_idx] == 1) {
                    return .{ .index = last_idx[value_idx], .value = @intCast(value_idx + 1) };
                }
            }
            return null;
        }

        fn findHiddenSingleInBox(self: *const Self, box: usize) ?UnitSingle {
            var counts: [B.SIZE]u8 = [_]u8{0} ** B.SIZE;
            var last_idx: [B.SIZE]usize = [_]usize{0} ** B.SIZE;

            const box_row = (box / B.BOX_SIZE) * B.BOX_SIZE;
            const box_col = (box % B.BOX_SIZE) * B.BOX_SIZE;

            var row: usize = box_row;
            while (row < box_row + B.BOX_SIZE) : (row += 1) {
                var col: usize = box_col;
                while (col < box_col + B.BOX_SIZE) : (col += 1) {
                    const idx = B.cellIndex(row, col);
                    const mask = self.candidate_mask[idx];
                    if (mask == 0) continue;

                    var bits = mask;
                    while (bits != 0) {
                        const low_bit = bits & (~bits +% 1);
                        const value_idx = @as(usize, @intCast(@ctz(low_bit)));
                        if (value_idx < B.SIZE) {
                            counts[value_idx] +%= 1;
                            last_idx[value_idx] = idx;
                        }
                        bits &= bits - 1;
                    }
                }
            }

            var value_idx: usize = 0;
            while (value_idx < B.SIZE) : (value_idx += 1) {
                if (counts[value_idx] == 1) {
                    return .{ .index = last_idx[value_idx], .value = @intCast(value_idx + 1) };
                }
            }
            return null;
        }

        fn findForcedHiddenSingle(self: *const Self) ?UnitSingle {
            var row: usize = 0;
            while (row < B.SIZE) : (row += 1) {
                if (self.findHiddenSingleInRow(row)) |single| return single;
            }

            var col: usize = 0;
            while (col < B.SIZE) : (col += 1) {
                if (self.findHiddenSingleInCol(col)) |single| return single;
            }

            var box: usize = 0;
            while (box < B.SIZE) : (box += 1) {
                if (self.findHiddenSingleInBox(box)) |single| return single;
            }

            return null;
        }

        fn hasContradiction(self: *const Self) bool {
            var idx: usize = 0;
            while (idx < CELL_COUNT) : (idx += 1) {
                const row = rowOfIndex(idx);
                const col = colOfIndex(idx);
                if (self.board.get(row, col) == 0 and self.candidate_count[idx] == 0) {
                    return true;
                }
            }
            return false;
        }

        fn propagateConstraints(self: *Self, placements: *[CELL_COUNT]Placement, placement_count: *usize) bool {
            while (true) {
                if (self.hasContradiction()) return false;

                if (self.findForcedNakedSingle()) |single| {
                    const row = rowOfIndex(single.index);
                    const col = colOfIndex(single.index);
                    self.applyPlacement(row, col, single.value, placements, placement_count);
                    continue;
                }

                if (self.findForcedHiddenSingle()) |single| {
                    const row = rowOfIndex(single.index);
                    const col = colOfIndex(single.index);
                    self.applyPlacement(row, col, single.value, placements, placement_count);
                    continue;
                }

                break;
            }

            return true;
        }

        fn scoreCandidateLCV(self: *const Self, row: usize, col: usize, value: u16) usize {
            const target_idx = B.cellIndex(row, col);
            const target_box = boxOfIndex(target_idx);
            const bit = @as(u128, 1) << @intCast(value - 1);

            var score: usize = 0;
            var idx: usize = 0;
            while (idx < CELL_COUNT) : (idx += 1) {
                if (idx == target_idx) continue;
                const r = rowOfIndex(idx);
                const c = colOfIndex(idx);
                if (self.board.get(r, c) != 0) continue;
                if (r == row or c == col or boxOfIndex(idx) == target_box) {
                    if ((self.candidate_mask[idx] & bit) != 0) score += 1;
                }
            }
            return score;
        }

        fn orderCandidatesLCV(self: *const Self, row: usize, col: usize, mask: u128, out_values: *[B.SIZE]u16) usize {
            var values: [B.SIZE]u16 = [_]u16{0} ** B.SIZE;
            var scores: [B.SIZE]usize = [_]usize{0} ** B.SIZE;
            var count: usize = 0;

            var bits = mask;
            while (bits != 0) {
                const low_bit = bits & (~bits +% 1);
                const value_idx = @as(usize, @intCast(@ctz(low_bit)));
                if (value_idx < B.SIZE and count < B.SIZE) {
                    const value: u16 = @intCast(value_idx + 1);
                    values[count] = value;
                    scores[count] = self.scoreCandidateLCV(row, col, value);
                    count += 1;
                }
                bits &= bits - 1;
            }

            var i: usize = 1;
            while (i < count) : (i += 1) {
                const value = values[i];
                const score = scores[i];
                var j = i;
                while (j > 0 and scores[j - 1] > score) : (j -= 1) {
                    values[j] = values[j - 1];
                    scores[j] = scores[j - 1];
                }
                values[j] = value;
                scores[j] = score;
            }

            var k: usize = 0;
            while (k < count) : (k += 1) {
                out_values[k] = values[k];
            }
            return count;
        }

        fn search(self: *Self) bool {
            // Allocate on the heap to avoid stack overflow on large puzzles
            // (for size=100, [CELL_COUNT]Placement = 10000 * 24 bytes = ~240KB per frame).
            const placements = std.heap.page_allocator.create([CELL_COUNT]Placement) catch return false;
            defer std.heap.page_allocator.destroy(placements);
            var placement_count: usize = 0;

            if (!self.propagateConstraints(placements, &placement_count)) {
                self.revertPlacements(placements, 0, placement_count);
                return false;
            }

            const next = self.findBestCell() orelse return true;
            if (next.mask == 0) {
                self.revertPlacements(placements, 0, placement_count);
                return false;
            }

            var ordered_values: [B.SIZE]u16 = [_]u16{0} ** B.SIZE;
            const candidate_len = self.orderCandidatesLCV(next.row, next.col, next.mask, &ordered_values);

            var i: usize = 0;
            while (i < candidate_len) : (i += 1) {
                const value = ordered_values[i];
                self.board.place(next.row, next.col, value);
                self.refreshAffected(next.row, next.col);

                if (self.search()) return true;

                self.board.remove(next.row, next.col, value);
                self.refreshAffected(next.row, next.col);
            }

            self.revertPlacements(placements, 0, placement_count);
            return false;
        }

        fn findBestCell(self: *const Self) ?BestCell {
            var found = false;
            var best_row: usize = 0;
            var best_col: usize = 0;
            var best_mask: u128 = 0;
            var best_count: u32 = B.SIZE + 1;

            var idx: usize = 0;
            while (idx < CELL_COUNT) : (idx += 1) {
                const row = rowOfIndex(idx);
                const col = colOfIndex(idx);
                if (self.board.get(row, col) != 0) continue;

                const count: u32 = self.candidate_count[idx];
                const mask = self.candidate_mask[idx];

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
        \\  solver --csv <path> [--limit <n>] [--size <n>] [--threads <n>]
        \\
        \\Options:
        \\  --puzzle   Solve a single puzzle
        \\  --compact  Output only the compact solution string (no grid)
        \\  --csv      Solve puzzles from a CSV file (puzzle,solution columns)
        \\  --limit    Max puzzles from CSV (default: 100)
        \\  --threads  Worker threads for CSV rows (default: 1)
        \\            Branching threads are auto-sized per puzzle candidate count
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

fn solutionMatchesForSize(comptime size: usize, board: *const Board(size), solution: []const u8) bool {
    const CELL_COUNT = Board(size).CELL_COUNT;
    if (size <= 9) {
        if (solution.len != CELL_COUNT) return false;
        var idx: usize = 0;
        while (idx < CELL_COUNT) : (idx += 1) {
            const expected = solution[idx];
            if (expected < '1' or expected > '0' + size) return false;
            const row = idx / size;
            const col = idx % size;
            if (board.get(row, col) != expected - '0') return false;
        }
        return true;
    }

    var cell: usize = 0;
    var i: usize = 0;
    while (i < solution.len and cell < CELL_COUNT) {
        while (i < solution.len and (solution[i] == ',' or solution[i] == ' ' or solution[i] == '\n' or solution[i] == '\r' or solution[i] == '\t')) : (i += 1) {}
        if (i >= solution.len) break;

        const start = i;
        while (i < solution.len and solution[i] >= '0' and solution[i] <= '9') : (i += 1) {}
        if (i == start) return false;

        const token = solution[start..i];
        const expected = std.fmt.parseUnsigned(u16, token, 10) catch return false;

        const row = cell / size;
        const col = cell % size;
        if (board.get(row, col) != expected) return false;
        cell += 1;
    }

    while (i < solution.len and (solution[i] == ',' or solution[i] == ' ' or solution[i] == '\n' or solution[i] == '\r' or solution[i] == '\t')) : (i += 1) {}
    return cell == CELL_COUNT and i == solution.len;
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

    const solved = solver.solveParallel();
    if (solved) {
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

fn runCsvModeForSize(comptime size: usize, csv_path: []const u8, limit: usize, csv_threads: usize, allocator: std.mem.Allocator) !void {
    const B = Board(size);
    const S = Solver(size);

    const Job = struct {
        puzzle: []u8,
        solution: []u8,
        csv_line: usize,
    };

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
    var jobs = std.ArrayList(Job).empty;
    defer {
        for (jobs.items) |job| {
            allocator.free(job.puzzle);
            allocator.free(job.solution);
        }
        jobs.deinit(allocator);
    }

    var csv_line_number: usize = 1;

    while (jobs.items.len < limit) {
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

        const puzzle_copy = try allocator.dupe(u8, puzzle_str);
        errdefer allocator.free(puzzle_copy);
        const solution_copy = try allocator.dupe(u8, solution_str);
        errdefer allocator.free(solution_copy);

        try jobs.append(allocator, .{
            .puzzle = puzzle_copy,
            .solution = solution_copy,
            .csv_line = csv_line_number,
        });
    }

    stats.attempted = jobs.items.len;
    const start_ns = std.time.nanoTimestamp();

    const worker_count = @max(@as(usize, 1), @min(csv_threads, @max(@as(usize, 1), jobs.items.len)));

    const CsvContext = struct {
        jobs: []const Job,
        next_index: usize = 0,
        solved: usize = 0,
        matched: usize = 0,
        unsolved: usize = 0,
        parse_errors: usize = 0,
        mismatches: usize = 0,
        mutex: std.Thread.Mutex = .{},

        fn worker(ctx: *@This()) void {
            var local_solved: usize = 0;
            var local_matched: usize = 0;
            var local_unsolved: usize = 0;
            var local_parse_errors: usize = 0;
            var local_mismatches: usize = 0;

            while (true) {
                var maybe_idx: ?usize = null;
                ctx.mutex.lock();
                if (ctx.next_index < ctx.jobs.len) {
                    maybe_idx = ctx.next_index;
                    ctx.next_index += 1;
                }
                ctx.mutex.unlock();

                const idx = maybe_idx orelse break;
                const job = ctx.jobs[idx];
                _ = job.csv_line;

                const board = B.fromString(job.puzzle) catch {
                    local_parse_errors += 1;
                    continue;
                };

                var solver = S.init(board);
                const solved = solver.solveParallel();
                if (!solved) {
                    local_unsolved += 1;
                    continue;
                }

                local_solved += 1;

                if (solutionMatchesForSize(size, &solver.board, job.solution)) {
                    local_matched += 1;
                } else {
                    local_mismatches += 1;
                }
            }

            ctx.mutex.lock();
            ctx.solved += local_solved;
            ctx.matched += local_matched;
            ctx.unsolved += local_unsolved;
            ctx.parse_errors += local_parse_errors;
            ctx.mismatches += local_mismatches;
            ctx.mutex.unlock();
        }
    };

    var ctx = CsvContext{
        .jobs = jobs.items,
    };

    var threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);

    var spawned: usize = 0;
    var t: usize = 0;
    while (t < worker_count) : (t += 1) {
        const th = std.Thread.spawn(.{}, CsvContext.worker, .{&ctx}) catch break;
        threads[spawned] = th;
        spawned += 1;
    }

    if (spawned < worker_count) {
        CsvContext.worker(&ctx);
    }

    t = 0;
    while (t < spawned) : (t += 1) {
        threads[t].join();
    }

    stats.solved = ctx.solved;
    stats.matched = ctx.matched;
    stats.unsolved = ctx.unsolved;
    stats.parse_errors += ctx.parse_errors;
    stats.mismatches = ctx.mismatches;

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

fn runCsvMode(csv_path: []const u8, limit: usize, size: usize, csv_threads: usize, allocator: std.mem.Allocator) !void {
    switch (size) {
        4 => try runCsvModeForSize(4, csv_path, limit, csv_threads, allocator),
        9 => try runCsvModeForSize(9, csv_path, limit, csv_threads, allocator),
        16 => try runCsvModeForSize(16, csv_path, limit, csv_threads, allocator),
        25 => try runCsvModeForSize(25, csv_path, limit, csv_threads, allocator),
        36 => try runCsvModeForSize(36, csv_path, limit, csv_threads, allocator),
        49 => try runCsvModeForSize(49, csv_path, limit, csv_threads, allocator),
        64 => try runCsvModeForSize(64, csv_path, limit, csv_threads, allocator),
        81 => try runCsvModeForSize(81, csv_path, limit, csv_threads, allocator),
        100 => try runCsvModeForSize(100, csv_path, limit, csv_threads, allocator),
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
    var csv_threads: usize = 1;

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
        } else if (std.mem.eql(u8, arg, "--threads")) {
            const value = args.next() orelse return SudokuError.MissingArgument;
            csv_threads = try parseUsize(value);
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
        try runCsvMode(csv_path, limit, size, csv_threads, allocator);
        return;
    }

    printUsage();
}
