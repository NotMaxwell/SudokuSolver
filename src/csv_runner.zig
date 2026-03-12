const std = @import("std");
const solver_mod = @import("solver.zig");

const RunnerError = error{
    MissingArgument,
    InvalidArgument,
    CsvFormatError,
    UnsupportedSize,
};

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  csv_runner --csv <path> [--limit <n>] [--size <n>] [--threads <n>]
        \\
        \\Options:
        \\  --csv     Path to the CSV file (required, format: puzzle,solution)
        \\  --limit   Max number of puzzles to run (default: 10)
        \\  --size    Board size (default: 9)
        \\  --threads Worker threads for CSV rows (default: 1)
        \\            Branching threads are auto-sized per puzzle candidate count
        \\
    , .{});
}

fn parseUsize(value: []const u8) RunnerError!usize {
    return std.fmt.parseUnsigned(usize, value, 10) catch RunnerError.InvalidArgument;
}

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trimRight(u8, line, "\r");
}

fn solutionMatchesForSize(comptime size: usize, board: *const solver_mod.Board(size), solution: []const u8) bool {
    const CELL_COUNT = solver_mod.Board(size).CELL_COUNT;
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

fn runCsvForSize(comptime size: usize, csv_path: []const u8, limit: usize, csv_threads: usize, allocator: std.mem.Allocator) !void {
    const B = solver_mod.Board(size);
    const S = solver_mod.Solver(size);
    const Job = struct {
        puzzle: []u8,
        solution: []u8,
        csv_line: usize,
    };

    const file = try std.fs.cwd().openFile(csv_path, .{});
    defer file.close();

    var buf: [1024]u8 = undefined;
    var reader = file.reader(&buf);

    const first_line_opt = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => return RunnerError.CsvFormatError,
        else => return err,
    };
    const first_line = first_line_opt orelse {
        std.debug.print("CSV is empty.\n", .{});
        return;
    };
    const first_trimmed = trimLine(first_line);
    const first_is_header =
        std.mem.eql(u8, first_trimmed, "puzzle,solution") or
        std.mem.eql(u8, first_trimmed, "quizzes,solutions");
    if (first_is_header) {
        std.debug.print("CSV header: {s}\n", .{first_trimmed});
    } else {
        std.debug.print("CSV: no header row detected, processing all rows as data\n", .{});
    }

    std.debug.print("Mode:       in-process\n", .{});
    std.debug.print("Size:       {d}x{d}\n", .{ size, size });
    std.debug.print("Limit:      {d}\n\n", .{limit});

    var attempted: usize = 0;
    var solved: usize = 0;
    var matched: usize = 0;
    var mismatches: usize = 0;
    var failed: usize = 0;
    var csv_line: usize = 1;

    var pending_line: ?[]const u8 = if (!first_is_header) first_trimmed else null;

    var jobs = std.ArrayList(Job).empty;
    defer {
        for (jobs.items) |job| {
            allocator.free(job.puzzle);
            allocator.free(job.solution);
        }
        jobs.deinit(allocator);
    }

    while (jobs.items.len < limit) {
        var trimmed: []const u8 = "";
        var got_line = false;

        if (pending_line) |pl| {
            pending_line = null;
            trimmed = pl;
            got_line = true;
        } else {
            const line_opt = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    std.debug.print("[{d}] parse error: line too long\n", .{csv_line});
                    failed += 1;
                    csv_line += 1;
                    continue;
                },
                else => return err,
            };
            if (line_opt) |line| {
                csv_line += 1;
                trimmed = trimLine(line);
                got_line = true;
            }
        }

        if (!got_line) break;
        if (trimmed.len == 0) continue;

        const split_idx: usize = blk: {
            if (size <= 9) {
                break :blk std.mem.indexOfScalar(u8, trimmed, ',') orelse {
                    std.debug.print("[{d}] parse error: no comma found\n", .{csv_line});
                    failed += 1;
                    continue;
                };
            }

            var comma_count: usize = 0;
            var idx: usize = 0;
            while (idx < trimmed.len) : (idx += 1) {
                if (trimmed[idx] == ',') {
                    comma_count += 1;
                    if (comma_count == B.CELL_COUNT) break :blk idx;
                }
            }
            std.debug.print("[{d}] parse error: could not find puzzle/solution boundary\n", .{csv_line});
            failed += 1;
            continue;
        };

        const puzzle = trimmed[0..split_idx];
        const expected_solution = trimmed[split_idx + 1 ..];

        if (size <= 9 and (puzzle.len != B.CELL_COUNT or expected_solution.len != B.CELL_COUNT)) {
            std.debug.print(
                "[{d}] parse error: expected {d}-char fields, got puzzle={d} solution={d}\n",
                .{ csv_line, B.CELL_COUNT, puzzle.len, expected_solution.len },
            );
            failed += 1;
            continue;
        }

        const puzzle_copy = try allocator.dupe(u8, puzzle);
        errdefer allocator.free(puzzle_copy);
        const solution_copy = try allocator.dupe(u8, expected_solution);
        errdefer allocator.free(solution_copy);

        try jobs.append(allocator, .{
            .puzzle = puzzle_copy,
            .solution = solution_copy,
            .csv_line = csv_line,
        });
    }

    attempted = jobs.items.len;
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
                const solved_now = solver.solveParallel();
                if (!solved_now) {
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

    solved = ctx.solved;
    matched = ctx.matched;
    mismatches = ctx.mismatches;
    failed += ctx.parse_errors + ctx.unsolved;

    const elapsed_ns: i128 = std.time.nanoTimestamp() - start_ns;
    const elapsed_ms = @divTrunc(elapsed_ns, 1_000_000);

    std.debug.print(
        \\
        \\--- Summary ---
        \\attempted:  {d}
        \\solved:     {d}
        \\matched:    {d}
        \\mismatches: {d}
        \\failed:     {d}
        \\elapsed_ms: {d}
        \\
    , .{ attempted, solved, matched, mismatches, failed, elapsed_ms });

    if (attempted > 0) {
        const avg_us = @divTrunc(elapsed_ns, @as(i128, @intCast(attempted)) * 1_000);
        std.debug.print("avg_us/puzzle: {d}\n", .{avg_us});
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var csv_arg: ?[]const u8 = null;
    var limit: usize = 10;
    var size: usize = 9;
    var csv_threads: usize = 1;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--csv")) {
            csv_arg = args.next() orelse return RunnerError.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            const val = args.next() orelse return RunnerError.MissingArgument;
            limit = try parseUsize(val);
        } else if (std.mem.eql(u8, arg, "--size")) {
            const val = args.next() orelse return RunnerError.MissingArgument;
            size = try parseUsize(val);
        } else if (std.mem.eql(u8, arg, "--threads")) {
            const val = args.next() orelse return RunnerError.MissingArgument;
            csv_threads = try parseUsize(val);
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else {
            std.debug.print("Error: unknown argument: {s}\n\n", .{arg});
            printUsage();
            return RunnerError.InvalidArgument;
        }
    }

    const csv_path = csv_arg orelse {
        std.debug.print("Error: --csv is required.\n\n", .{});
        printUsage();
        return RunnerError.MissingArgument;
    };

    switch (size) {
        4 => try runCsvForSize(4, csv_path, limit, csv_threads, allocator),
        9 => try runCsvForSize(9, csv_path, limit, csv_threads, allocator),
        16 => try runCsvForSize(16, csv_path, limit, csv_threads, allocator),
        25 => try runCsvForSize(25, csv_path, limit, csv_threads, allocator),
        36 => try runCsvForSize(36, csv_path, limit, csv_threads, allocator),
        49 => try runCsvForSize(49, csv_path, limit, csv_threads, allocator),
        64 => try runCsvForSize(64, csv_path, limit, csv_threads, allocator),
        81 => try runCsvForSize(81, csv_path, limit, csv_threads, allocator),
        100 => try runCsvForSize(100, csv_path, limit, csv_threads, allocator),
        else => return RunnerError.UnsupportedSize,
    }
}
