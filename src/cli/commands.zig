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

    pub fn execute(self: Self, allocator: std.mem.Allocator, db: *Database, ln: *Linenoise) !void {
        const start_input = (try ln.linenoiseZ("Start date: ")).?;
        defer ln.allocator.free(start_input);
        const end_input = (try ln.linenoiseZ("End date: ")).?;
        defer ln.allocator.free(end_input);

        const start_date = try Date.fromString(start_input);
        const end_date = try Date.fromString(end_input);

        const start_string = try start_date.toStringZ(allocator);
        const end_string = try end_date.toStringZ(allocator);
        defer allocator.free(start_string);
        defer allocator.free(end_string);

        const nameZ = try allocator.dupeZ(u8, self.name);
        defer allocator.free(nameZ);

        try db.prepare("INSERT INTO Events(Name, Start, End) VALUES(?, ?, ?)");
        try db.bindText(1, nameZ);
        try db.bindText(2, start_string);
        try db.bindText(3, end_string);
        try db.executeAndFinish();
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
    pub fn execute(self: Self, db: *Database) !void {
        try db.prepare("DELETE FROM Events WHERE rowid == ?;");
        try db.bindInt(1, self.id);
        try db.executeAndFinish();
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
    pub fn execute(_: Self, db: *Database) !void {
        try db.executeCB("SELECT * FROM Events;", callback, null);
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
    pub fn execute(self: Self, db: *Database) !void {
        try db.prepare("UPDATE Events SET Name = ? WHERE Id = ?;");
        try db.bindText(1, self.new_name);
        try db.bindInt(2, self.id);
        try db.executeAndFinish();
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
    pub fn execute(self: Self, allocator: std.mem.Allocator, db: *Database) !void {
        const period = try self.repeat_info.period.toString(allocator);
        defer allocator.free(period);
        const end = if (self.repeat_info.end) |e| try e.toString(allocator) else null;
        defer if (end) |s| allocator.free(s);

        try db.prepare("INSERT INTO Repeats(Period, End) VALUES(?, ?)");
        try db.bindText(1, period);
        if (end) |e| try db.bindText(2, e) else try db.bindNull(2);
        try db.executeAndFinish();

        try db.prepare("UPDATE Events SET Repeat = ? WHERE Id = ?;");
        try db.bindInt(1, db.getLastInsertedRowid());
        try db.bindInt(2, self.id);
        try db.executeAndFinish();
    }
};

const DupeCmd = struct {
    const Self = @This();
    const pattern = "dupe (-?\\d+)";
    id: i32,
    fn init(cap: *Captures) !Self {
        return .{ .id = try std.fmt.parseInt(i32, cap.sliceAt(1).?, 10) };
    }
    pub fn execute(self: Self, db: *Database) !void {
        try db.prepare("CREATE TEMPORARY TABLE tmp AS SELECT * FROM Events WHERE Id == ?;");
        try db.bindInt(1, self.id);
        try db.executeAndFinish();
        try db.execute(
            \\ UPDATE tmp SET Id = NULL;
            \\ INSERT INTO Events SELECT * FROM tmp;
            \\ DROP TABLE tmp;
        );
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
