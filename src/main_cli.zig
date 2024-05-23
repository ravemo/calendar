const std = @import("std");
const commands = @import("cli/commands.zig");
const Database = @import("cli/database.zig").Database;
const Linenoise = @import("linenoise").Linenoise;

pub fn main() !void {
    var db = Database.init("calendar.db");
    defer db.deinit();

    try db.execute(
        \\CREATE TABLE IF NOT EXISTS Repeats (
        \\    Id INTEGER PRIMARY KEY,
        \\    Period TEXT NOT NULL,
        \\    Start TEXT NOT NULL,
        \\    End TEXT,
        \\    Data BLOB
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

    const allocator = std.heap.page_allocator;
    var ln = Linenoise.init(allocator);
    defer ln.deinit();
    while (try ln.linenoise("> ")) |input| {
        defer allocator.free(input);

        const cmd_general = try commands.getCmd(allocator, input);
        switch (cmd_general) {
            .add => |cmd| {
                try cmd.execute(allocator, db, &ln);
            },
            .rm => |cmd| {
                try cmd.execute(allocator, db);
            },
            .view => |cmd| {
                try cmd.execute(allocator, &db);
            },
            .quit => break,
        }
    }
}
