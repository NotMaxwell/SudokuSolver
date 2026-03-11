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
        \\  csv_runner --csv <path> [--limit <n>] [--size <n>]
        \\
        \\Options:
        \\  --csv     Path to the CSV file (required, format: puzzle,solution)
        \\  --limit   Max number of puzzles to run (default: 10)
        \\  --size    Board size (default: 9)
        \\
    , .{});
}

fn parseUsize(value: []const u8) RunnerError!usize {
    return std.fmt.parseUnsigned(usize, value, 10) catch RunnerError.InvalidArgument;
}

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trimRight(u8, line, "\r");
}

fn runCsvForSize(comptime size: usize, csv_path: []const u8, limit: usize, allocator: std.mem.Allocator) !void {
    const B = solver_mod.Board(size);
    const S = solver_mod.Solver(size);

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

    const start_ns = std.time.nanoTimestamp();

    while (attempted < limit) {
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

        attempted += 1;
        const row_start_ns = std.time.nanoTimestamp();

        const board = B.fromString(puzzle) catch {
            failed += 1;
            std.debug.print("[{d}] parse error: invalid puzzle\n", .{csv_line});
            continue;
        };

        var solver = S.init(board);
        if (!solver.solve()) {
            failed += 1;
            std.debug.print("[{d}] unsolved\n", .{csv_line});
            continue;
        }

        solved += 1;
        const got_solution = try solver.board.toDigitString(allocator);
        defer allocator.free(got_solution);

        const row_elapsed_ns: i128 = std.time.nanoTimestamp() - row_start_ns;
        const row_elapsed_us = @divTrunc(row_elapsed_ns, 1000);

        if (std.mem.eql(u8, got_solution, expected_solution)) {
            matched += 1;
            std.debug.print("[{d}] puzzle #{d} => MATCHED in {d}us\n", .{ csv_line, attempted, row_elapsed_us });
        } else {
            mismatches += 1;
            std.debug.print("[{d}] puzzle #{d} => MISMATCH in {d}us\n", .{ csv_line, attempted, row_elapsed_us });
        }
    }

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

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--csv")) {
            csv_arg = args.next() orelse return RunnerError.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            const val = args.next() orelse return RunnerError.MissingArgument;
            limit = try parseUsize(val);
        } else if (std.mem.eql(u8, arg, "--size")) {
            const val = args.next() orelse return RunnerError.MissingArgument;
            size = try parseUsize(val);
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
        4 => try runCsvForSize(4, csv_path, limit, allocator),
        9 => try runCsvForSize(9, csv_path, limit, allocator),
        16 => try runCsvForSize(16, csv_path, limit, allocator),
        25 => try runCsvForSize(25, csv_path, limit, allocator),
        36 => try runCsvForSize(36, csv_path, limit, allocator),
        49 => try runCsvForSize(49, csv_path, limit, allocator),
        64 => try runCsvForSize(64, csv_path, limit, allocator),
        81 => try runCsvForSize(81, csv_path, limit, allocator),
        100 => try runCsvForSize(100, csv_path, limit, allocator),
        else => return RunnerError.UnsupportedSize,
    }
}
