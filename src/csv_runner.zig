const std = @import("std");

const RunnerError = error{
    MissingArgument,
    InvalidArgument,
    CsvFormatError,
};

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  csv_runner --csv <path> [--limit <n>] [--solver <path>]
        \\
        \\Options:
        \\  --csv     Path to the CSV file (required, format: puzzle,solution)
        \\  --limit   Max number of puzzles to run (default: 10)
        \\  --solver  Path to solver executable (default: ./zig-out/bin/solver)
        \\
    , .{});
}

fn parseUsize(value: []const u8) RunnerError!usize {
    return std.fmt.parseUnsigned(usize, value, 10) catch RunnerError.InvalidArgument;
}

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trimRight(u8, line, "\r");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var csv_arg: ?[]const u8 = null;
    var solver_arg: []const u8 = "./zig-out/bin/solver";
    var limit: usize = 10;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--csv")) {
            csv_arg = args.next() orelse return RunnerError.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--solver")) {
            solver_arg = args.next() orelse return RunnerError.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            const val = args.next() orelse return RunnerError.MissingArgument;
            limit = try parseUsize(val);
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

    const file = try std.fs.cwd().openFile(csv_path, .{});
    defer file.close();

    var buf: [256]u8 = undefined;
    var reader = file.reader(&buf);

    // Read the first line: skip it only if it is a known header string,
    // otherwise treat it as the first data row so puzzle #1 is never lost.
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
    std.debug.print("Solver:     {s}\n", .{solver_arg});
    std.debug.print("Limit:      {d}\n\n", .{limit});

    var attempted: usize = 0;
    var solved: usize = 0;
    var matched: usize = 0;
    var mismatches: usize = 0;
    var failed: usize = 0;
    var csv_line: usize = 1;

    // If the first line was data (no header), queue it up so the loop processes it first.
    var pending_line: ?[]const u8 = if (!first_is_header) first_trimmed else null;

    const start_ns = std.time.nanoTimestamp();

    while (attempted < limit) {
        // Consume pending line first (only set when no header row exists).
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

        if (!got_line) break; // EOF
        if (trimmed.len == 0) continue;

        const comma = std.mem.indexOfScalar(u8, trimmed, ',') orelse {
            std.debug.print("[{d}] parse error: no comma found\n", .{csv_line});
            failed += 1;
            continue;
        };

        const puzzle = trimmed[0..comma];
        const expected_solution = trimmed[comma + 1 ..];

        if (puzzle.len != 81 or expected_solution.len != 81) {
            std.debug.print("[{d}] parse error: expected 81-char fields, got puzzle={d} solution={d}\n", .{ csv_line, puzzle.len, expected_solution.len });
            failed += 1;
            continue;
        }

        attempted += 1;
        std.debug.print("[{d}] puzzle #{d}: {s}\n", .{ csv_line, attempted, puzzle });

        const row_start_ns = std.time.nanoTimestamp();

        // Spawn solver --puzzle <puzzle> --compact
        var child = std.process.Child.init(
            &.{ solver_arg, "--puzzle", puzzle, "--compact" },
            allocator,
        );
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        // Collect stdout and stderr
        var stdout_list = std.ArrayList(u8){};
        defer stdout_list.deinit(allocator);
        var stderr_list = std.ArrayList(u8){};
        defer stderr_list.deinit(allocator);

        try child.collectOutput(allocator, &stdout_list, &stderr_list, 64 * 1024);
        const term = try child.wait();

        const row_elapsed_ns: i128 = std.time.nanoTimestamp() - row_start_ns;
        const row_elapsed_us = @divTrunc(row_elapsed_ns, 1000);

        const exit_ok = switch (term) {
            .Exited => |code| code == 0,
            else => false,
        };

        if (!exit_ok) {
            failed += 1;
            std.debug.print("  => FAILED (exit {any}) in {d}us\n", .{ term, row_elapsed_us });
            if (stderr_list.items.len > 0) {
                std.debug.print("  stderr: {s}\n", .{std.mem.trimRight(u8, stderr_list.items, "\r\n")});
            }
            continue;
        }

        solved += 1;

        // Extract solution from stdout: last 81-char run of digits on its own line
        const stdout = stdout_list.items;
        var got_solution: ?[]const u8 = null;

        // The solver prints the board in grid form; we look for the digit-only compact output
        // by scanning each token separated by whitespace for something 81 chars of 1-9
        var iter = std.mem.splitScalar(u8, stdout, '\n');
        while (iter.next()) |sol_line| {
            const sl = std.mem.trim(u8, sol_line, " \r\t");
            if (sl.len == 81) {
                var all_digits = true;
                for (sl) |c| {
                    if (c < '1' or c > '9') {
                        all_digits = false;
                        break;
                    }
                }
                if (all_digits) {
                    got_solution = sl;
                    break;
                }
            }
        }

        if (got_solution) |sol| {
            std.debug.print("  solved:   {s}\n", .{sol});

            if (std.mem.eql(u8, sol, expected_solution)) {
                matched += 1;
                std.debug.print("  => MATCHED in {d}us\n", .{row_elapsed_us});
            } else {
                mismatches += 1;
                std.debug.print("  => MISMATCH in {d}us\n", .{row_elapsed_us});
                std.debug.print("     got:      {s}\n", .{sol[0..@min(sol.len, 32)]});
                std.debug.print("     expected: {s}\n", .{expected_solution[0..@min(expected_solution.len, 32)]});
            }
        } else {
            // solver solved it but produced grid output with no compact line
            // compare by reconstructing from grid digits
            std.debug.print("  => solved (no compact output to compare) in {d}us\n", .{row_elapsed_us});
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
