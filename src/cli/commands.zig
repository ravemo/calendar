const std = @import("std");
const regexImport = @import("../lib/regex.zig");
const Regex = regexImport.Regex;
const Captures = regexImport.Captures;
const Linenoise = @import("linenoise").Linenoise;

const Database = @import("database.zig").Database;

const calendar = @import("../lib/event.zig");
const StringError = calendar.StringError;
const Date = calendar.Date;

const AddCmd = struct {
    const Self = @This();
    const pattern = "add (.*)";
    name: []const u8,
    allocator: std.mem.Allocator,

    fn init(cap: *Captures, allocator: std.mem.Allocator) !Self {
        return .{ .name = try allocator.dupe(u8, cap.sliceAt(1).?), .allocator = allocator };
    }

    pub fn deinit(self: Self) void {
        self.allocator.free(self.name);
    }

    pub fn execute(self: Self, allocator: std.mem.Allocator, db: Database, ln: *Linenoise) !void {
        const start_input = (try ln.linenoiseZ("Start date: ")).?;
        defer ln.allocator.free(start_input);
        const end_input = (try ln.linenoiseZ("End date: ")).?;
        defer ln.allocator.free(end_input);

        const start_date = try Date.fromString(start_input);
        const end_date = try Date.fromString(end_input);

        const start_string = try start_date.toString(allocator);
        const end_string = try end_date.toString(allocator);
        defer allocator.free(start_string);
        defer allocator.free(end_string);

        // TODO: Use parametrized queries
        const query = try std.fmt.allocPrintZ(
            allocator,
            "INSERT INTO Events(Name, Start, End) VALUES('{s}', '{s}', '{s}')",
            .{ self.name, start_string, end_string },
        );
        defer allocator.free(query);
        try db.execute(query);
    }
};
const RmCmd = struct {
    const Self = @This();
    const pattern = "rm (.*)";
    id: i32,
    fn init(cap: *Captures, _: std.mem.Allocator) !Self {
        const id = std.fmt.parseInt(i32, cap.sliceAt(1).?, 10) catch |e| {
            std.debug.print("Couldn't parse \"{s}\"\n", .{cap.sliceAt(1).?});
            return e;
        };
        return .{ .id = id };
    }
    pub fn deinit(_: Self) void {}

    pub fn execute(self: Self, allocator: std.mem.Allocator, db: Database) !void {
        const query = try std.fmt.allocPrintZ(
            allocator,
            "DELETE FROM Events WHERE rowid == {d};",
            .{self.id},
        );
        defer allocator.free(query);
        try db.execute(query);
    }
};
const ViewCmd = struct {
    const Self = @This();
    const pattern = "list";
    fn init(_: *Captures, _: std.mem.Allocator) !Self {
        return .{};
    }
    pub fn deinit(_: Self) void {}
    fn callback(_: ?*anyopaque, argc: c_int, argv: [*c][*c]u8, cols: [*c][*c]u8) callconv(.C) c_int {
        for (0..@intCast(argc)) |i| {
            if (argv[i] == null) {
                std.debug.print("{s}: null\n", .{cols[i]});
            } else {
                std.debug.print("{s}: {s}\n", .{ cols[i], argv[i] });
            }
        }
        std.debug.print("---\n", .{});
        return 0;
    }
    pub fn execute(_: Self, allocator: std.mem.Allocator, db: *Database) !void {
        const query = try std.fmt.allocPrintZ(
            allocator,
            "SELECT * FROM Events;",
            .{},
        );
        defer allocator.free(query);

        try db.executeCB(query, callback, null);
    }
};
const QuitCmd = struct {
    const Self = @This();
    const pattern = "quit";
    fn init(_: *Captures, _: std.mem.Allocator) !Self {
        return .{};
    }
    pub fn deinit(_: Self) void {}
};
const Cmd = union(enum) {
    add: AddCmd,
    rm: RmCmd,
    view: ViewCmd,
    quit: QuitCmd,
};

pub fn getCmd(allocator: std.mem.Allocator, str: [:0]const u8) !Cmd {
    inline for (std.meta.fields(Cmd)) |field| {
        const T = field.type;
        var regex = try Regex.compile(T.pattern);
        defer regex.deinit();
        var cap_opt = regex.captures(str) catch |e| switch (e) {
            StringError.NoMatches => null,
            else => return e,
        };
        if (cap_opt) |*cap|
            return @unionInit(Cmd, field.name, try T.init(cap, allocator));
    }
    return error.NoMatch;
}
