const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});
const Event = @import("../lib/event.zig").Event;
const print = std.debug.print;

pub const QueryCallback = fn (?*anyopaque, c_int, [*c][*c]u8, [*c][*c]u8) callconv(.C) c_int;

pub const Database = struct {
    const Self = @This();
    db: ?*c.sqlite3,
    res: ?*c.sqlite3_stmt = undefined,

    pub fn init(path: [:0]const u8) !Self {
        var db: ?*c.sqlite3 = undefined;
        if (c.SQLITE_OK != c.sqlite3_open(path, &db)) {
            print("Can't open database: {s}\n", .{c.sqlite3_errmsg(db)});
            return error.InvalidPath;
        }
        return .{ .db = db };
    }

    pub fn deinit(self: Self) void {
        _ = c.sqlite3_close(self.db);
    }

    pub fn execute(self: Self, query: [:0]const u8) !void {
        return executeCB(self, query, null, null);
    }
    pub fn executeCB(self: Self, query: [:0]const u8, cb: ?*const QueryCallback, userdata: ?*anyopaque) !void {
        print("Running query: \"{s}\"\n", .{query});
        var errmsg: [*c]u8 = undefined;
        if (c.SQLITE_OK != c.sqlite3_exec(self.db, query, cb, userdata, &errmsg)) {
            defer c.sqlite3_free(errmsg);
            std.debug.print("Exec query failed: {s}\n", .{errmsg});
            return error.execError;
        }
        return;
    }

    pub fn fetch(self: *Self, query: [:0]const u8) !void {
        var tail: [*c]u8 = undefined;

        if (c.sqlite3_prepare_v2(self.db, query, @intCast(query.len), &self.res, &tail) != c.SQLITE_OK) {
            print("Can't retrieve data: {s}\n", .{c.sqlite3_errmsg(self.db)});
            return error.CantRetrieve;
        }

        while (c.sqlite3_step(self.res) != c.SQLITE_ROW) {
            return error.TODO;
        }
        c.sqlite3_reset(self.res);
    }
    pub fn finalizeFetch(self: Self) void {
        c.sqlite3_finalize(self.res);
    }

    pub fn getLastInsertedRowid(self: Self) i32 {
        return @intCast(c.sqlite3_last_insert_rowid(self.db));
    }

    pub fn updateEvent(self: *Self, allocator: std.mem.Allocator, e: Event) !void {
        var tail: [*c]u8 = undefined;
        const query = "UPDATE Events SET Start=?, End=? WHERE Id=?;";
        if (c.sqlite3_prepare_v2(self.db, query, @intCast(query.len), &self.res, &tail) != c.SQLITE_OK) {
            print("Can't retrieve data: {s}\n", .{c.sqlite3_errmsg(self.db)});
            return error.CantRetrieve;
        }

        const start_string = try e.start.toStringZ(allocator);
        const end_string = try e.getEnd().toStringZ(allocator);
        defer allocator.free(start_string);
        defer allocator.free(end_string);

        if (c.sqlite3_bind_text(self.res, 1, start_string, @intCast(start_string.len), c.SQLITE_STATIC) != c.SQLITE_OK) {
            std.debug.print("Couldn't bind variable 1\n", .{});
            return error.BindError;
        }
        if (c.sqlite3_bind_text(self.res, 2, end_string, @intCast(start_string.len), c.SQLITE_STATIC) != c.SQLITE_OK) {
            std.debug.print("Couldn't bind variable 2\n", .{});
            return error.BindError;
        }
        if (c.sqlite3_bind_int(self.res, 3, e.id) != c.SQLITE_OK) {
            std.debug.print("Couldn't bind variable 3\n", .{});
            return error.BindError;
        }

        if (c.sqlite3_step(self.res) != c.SQLITE_DONE) {
            std.debug.print("Couldn't execute query\n", .{});
            return error.StepError;
        }
        _ = c.sqlite3_reset(self.res);
        _ = c.sqlite3_clear_bindings(self.res);
    }
};
