const std = @import("std");
const regexImport = @import("../lib/regex.zig");
const Regex = regexImport.Regex;
const Captures = regexImport.Captures;
const Linenoise = @import("linenoise").Linenoise;

const Database = @import("../lib/database.zig").Database;

const datetime = @import("../lib/datetime.zig");
const StringError = datetime.StringError;
const RepeatInfo = datetime.RepeatInfo;
const Date = datetime.Date;

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
    fn init(cap: *Captures) !Self {
        const id = try std.fmt.parseInt(i32, cap.sliceAt(1).?, 10);
        return .{ .id = id };
    }
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
    pub fn execute(_: Self, allocator: std.mem.Allocator, db: Database) !void {
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
};

const RenameCmd = struct {
    const Self = @This();
    const pattern = "rename (-?\\d+) (.*)";
    id: i32,
    new_name: []u8,
    allocator: std.mem.Allocator,
    fn init(cap: *Captures, allocator: std.mem.Allocator) !Self {
        const id = try std.fmt.parseInt(i32, cap.sliceAt(1).?, 10);
        const new_name = try allocator.dupe(u8, cap.sliceAt(2).?);
        return .{ .id = id, .new_name = new_name, .allocator = allocator };
    }
    pub fn deinit(self: Self) void {
        self.allocator.free(self.new_name);
    }
    pub fn execute(self: Self, allocator: std.mem.Allocator, db: Database) !void {
        const query = try std.fmt.allocPrintZ(
            allocator,
            "UPDATE Events SET Name = '{s}' WHERE Id = {};",
            .{ self.new_name, self.id },
        );
        defer allocator.free(query);
        try db.execute(query);
    }
};

const RepeatCmd = struct {
    const Self = @This();
    const pattern = "repeat (-?\\d+) (.*)";
    id: i32,
    repeat_info: RepeatInfo,
    fn init(cap: *Captures) !Self {
        const id = try std.fmt.parseInt(i32, cap.sliceAt(1).?, 10);
        const repeat_info = try RepeatInfo.fromString(cap.sliceAt(2).?);
        return .{ .id = id, .repeat_info = repeat_info };
    }
    pub fn execute(self: Self, allocator: std.mem.Allocator, db: Database) !void {
        const period = try self.repeat_info.period.toString(allocator);
        defer allocator.free(period);
        const end_def = if (self.repeat_info.end) |e| try e.toString(allocator) else null;
        defer if (end_def) |s| allocator.free(s);

        // TODO use parametrized query instead of having this spaghetti
        const end = if (end_def) |s|
            try std.fmt.allocPrintZ(allocator, "'{s}'", .{s})
        else
            "NULL";
        defer if (!std.mem.eql(u8, end, "NULL"))
            allocator.free(end);

        const create_repeat_query = try std.fmt.allocPrintZ(
            allocator,
            "INSERT INTO Repeats(Period, End) VALUES('{s}', {s})",
            .{ period, end },
        );
        defer allocator.free(create_repeat_query);
        try db.execute(create_repeat_query);

        const set_repeat_query = try std.fmt.allocPrintZ(
            allocator,
            "UPDATE Events SET Repeat = {} WHERE Id = {};",
            .{ db.getLastInsertedRowid(), self.id },
        );
        defer allocator.free(set_repeat_query);

        try db.execute(set_repeat_query);
    }
};

const DupeCmd = struct {
    const Self = @This();
    const pattern = "dupe (-?\\d+)";
    id: i32,
    fn init(cap: *Captures) !Self {
        return .{ .id = try std.fmt.parseInt(i32, cap.sliceAt(1).?, 10) };
    }
    pub fn execute(self: Self, allocator: std.mem.Allocator, db: Database) !void {
        const query = try std.fmt.allocPrintZ(allocator,
            \\ CREATE TEMPORARY TABLE tmp AS SELECT * FROM Events WHERE Id == {};
            \\ UPDATE tmp SET Id = NULL;
            \\ INSERT INTO Events SELECT * FROM tmp;
            \\ DROP TABLE tmp;
        , .{self.id});
        defer allocator.free(query);
        try db.execute(query);
    }
};

const Cmd = union(enum) {
    add: AddCmd,
    rm: RmCmd,
    view: ViewCmd,
    quit: QuitCmd,
    rename: RenameCmd,
    repeat: RepeatCmd,
    dupe: DupeCmd,

    pub fn init(allocator: std.mem.Allocator, field: std.builtin.Type.UnionField, cap: *Captures) !Cmd {
        const T = field.type;
        return switch (T) {
            QuitCmd, ViewCmd => @unionInit(Cmd, field.name, .{}),
            DupeCmd, RmCmd, RepeatCmd => @unionInit(Cmd, field.name, try T.init(cap)),
            inline else => |_| @unionInit(Cmd, field.name, try T.init(cap, allocator)),
        };
    }

    pub fn deinit(self: Cmd) void {
        switch (self) {
            .rm, .quit, .view, .repeat, .dupe => {},
            inline else => |cmd| cmd.deinit(),
        }
    }
};

pub fn initCmd(allocator: std.mem.Allocator, str: [:0]const u8) !Cmd {
    inline for (std.meta.fields(Cmd)) |field| {
        const T = field.type;
        var regex = try Regex.compile(T.pattern);
        defer regex.deinit();
        var cap_opt = regex.captures(str) catch |e| switch (e) {
            StringError.NoMatches => null,
            else => return e,
        };
        if (cap_opt) |*cap| {
            return try Cmd.init(allocator, field, cap);
        }
    }
    return error.NoMatch;
}
