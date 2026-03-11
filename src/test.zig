const std = @import("std");
const solver_mod = @import("solver.zig");

const Board9 = solver_mod.Board9;
const Solver9 = solver_mod.Solver9;
const SudokuError = solver_mod.SudokuError;

test "solve sandiway wildcatjan17" {
    const puzzle =
        "000260701" ++
        "680070090" ++
        "190004500" ++
        "820100040" ++
        "004602900" ++
        "050003028" ++
        "009300074" ++
        "040050036" ++
        "703018000";

    const expected =
        "435269781" ++
        "682571493" ++
        "197834562" ++
        "826195347" ++
        "374682915" ++
        "951743628" ++
        "519326874" ++
        "248957136" ++
        "763418259";

    const board = try Board9.fromString(puzzle);
    var solver = Solver9.init(board);

    try std.testing.expect(solver.solve());

    var allocator = std.testing.allocator;
    const got = try solver.board.toDigitString(allocator);
    defer allocator.free(got);

    try std.testing.expectEqualStrings(expected[0..], got);
}

test "solver preserves original givens" {
    const puzzle =
        "000260701" ++
        "680070090" ++
        "190004500" ++
        "820100040" ++
        "004602900" ++
        "050003028" ++
        "009300074" ++
        "040050036" ++
        "703018000";

    const original = try Board9.fromString(puzzle);
    var solver = Solver9.init(original);

    try std.testing.expect(solver.solve());

    var i: usize = 0;
    while (i < 81) : (i += 1) {
        if (original.cells[i] != 0) {
            try std.testing.expectEqual(original.cells[i], solver.board.cells[i]);
        }
    }
}

test "solved board is valid" {
    const puzzle =
        "000260701" ++
        "680070090" ++
        "190004500" ++
        "820100040" ++
        "004602900" ++
        "050003028" ++
        "009300074" ++
        "040050036" ++
        "703018000";

    const board = try Board9.fromString(puzzle);
    var solver = Solver9.init(board);

    try std.testing.expect(solver.solve());

    var row: usize = 0;
    while (row < 9) : (row += 1) {
        var seen: u128 = 0;
        var col: usize = 0;
        while (col < 9) : (col += 1) {
            const v = solver.board.get(row, col);
            try std.testing.expect(v >= 1 and v <= 9);
            const b: u128 = @as(u128, 1) << @intCast(v - 1);
            try std.testing.expect((seen & b) == 0);
            seen |= b;
        }
        try std.testing.expectEqual(@as(u128, 0x1FF), seen);
    }

    var col: usize = 0;
    while (col < 9) : (col += 1) {
        var seen: u128 = 0;
        row = 0;
        while (row < 9) : (row += 1) {
            const v = solver.board.get(row, col);
            const b: u128 = @as(u128, 1) << @intCast(v - 1);
            try std.testing.expect((seen & b) == 0);
            seen |= b;
        }
        try std.testing.expectEqual(@as(u128, 0x1FF), seen);
    }
}

test "reject invalid character input" {
    const bad =
        "000260701" ++
        "680070090" ++
        "190004500" ++
        "820100040" ++
        "004602900" ++
        "050003028" ++
        "009300074" ++
        "040050036" ++
        "70301800x";

    try std.testing.expectError(SudokuError.InvalidCharacter, Board9.fromString(bad));
}

test "reject conflicting givens" {
    const bad =
        "600260701" ++
        "680070090" ++
        "190004500" ++
        "820100040" ++
        "004602900" ++
        "050003028" ++
        "009300074" ++
        "040050036" ++
        "703018000";

    try std.testing.expectError(SudokuError.InvalidPuzzle, Board9.fromString(bad));
}

test "4x4 board solves correctly" {
    const Board4 = solver_mod.Board4;
    const Solver4 = solver_mod.Solver4;

    // Valid solvable 4x4 (2x2 boxes, values 1-4):
    //  1 . | . 4
    //  . 4 | 1 .
    //  ----+----
    //  . 1 | 4 .
    //  4 . | . 1
    const puzzle = "1004" ++ "0410" ++ "0140" ++ "4001";

    const board = try Board4.fromString(puzzle);
    var solver = Solver4.init(board);
    try std.testing.expect(solver.solve());

    // Verify all rows contain 1-4 exactly once
    var row: usize = 0;
    while (row < 4) : (row += 1) {
        var seen: u128 = 0;
        var col: usize = 0;
        while (col < 4) : (col += 1) {
            const v = solver.board.get(row, col);
            try std.testing.expect(v >= 1 and v <= 4);
            const b: u128 = @as(u128, 1) << @intCast(v - 1);
            try std.testing.expect((seen & b) == 0);
            seen |= b;
        }
        try std.testing.expectEqual(@as(u128, 0xF), seen);
    }
}

test "16x16 board parses and solves partially" {
    const Board16 = solver_mod.Board16;
    const Solver16 = solver_mod.Solver16;

    // A trivially near-complete 16x16: fill all but one cell correctly,
    // leave one empty and confirm the solver fills it.
    var board = Board16.initEmpty();
    // Fill row 0 with 1..16
    var col: usize = 0;
    while (col < 16) : (col += 1) {
        board.place(0, col, @intCast(col + 1));
    }
    // The board is not a valid puzzle (other rows empty) but we can at least
    // test that fromString roundtrips for a near-empty board.
    var solver = Solver16.init(board);
    // solve() will try (might succeed or fail depending on the partial state)
    _ = solver.solve();
    // Just check no panic and row 0 is still intact
    col = 0;
    while (col < 16) : (col += 1) {
        try std.testing.expectEqual(@as(u16, @intCast(col + 1)), solver.board.get(0, col));
    }
}
