const std = @import("std");
const commands = @import("cli/commands.zig");
const Database = @import("lib/database.zig").Database;
const Linenoise = @import("linenoise").Linenoise;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var db = try Database.init(allocator, "calendar/calendar.db");
    defer db.deinit();

    try db.execute(
        \\CREATE TABLE IF NOT EXISTS Repeats (
        \\    Id INTEGER PRIMARY KEY,
        \\    Period TEXT NOT NULL,
        \\    Start TEXT,
        \\    End TEXT
        \\);
        \\CREATE TABLE IF NOT EXISTS Events (
        \\    Id INTEGER PRIMARY KEY,
        \\    Name TEXT NOT NULL,
        \\    Start TEXT NOT NULL,
        \\    End TEXT NOT NULL,
        \\    Repeat INTEGER,
        \\    FOREIGN KEY(Repeat) REFERENCES Repeats(Id)
        \\);
    );

    var ln = Linenoise.init(allocator);
    defer ln.deinit();
    while (try ln.linenoiseZ("> ")) |input| {
        defer allocator.free(input);
        if (input.len == 0) continue;

        const cmd_general = try commands.initCmd(allocator, input);
        defer cmd_general.deinit();
        switch (cmd_general) {
            .add => |cmd| try cmd.execute(allocator, &db, &ln),
            .repeat => |cmd| try cmd.execute(allocator, &db),
            inline else => |cmd| try cmd.execute(&db),
            .quit => break,
        }
    }
}
