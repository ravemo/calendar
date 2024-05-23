const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});
const print = std.debug.print;

pub const QueryCallback = fn (?*anyopaque, c_int, [*c][*c]u8, [*c][*c]u8) callconv(.C) c_int;

pub const Database = struct {
    const Self = @This();
    db: ?*c.sqlite3,
    res: ?*c.sqlite3_stmt = undefined,

    pub fn init(path: [:0]const u8) Self {
        var db: ?*c.sqlite3 = undefined;
        if (c.SQLITE_OK != c.sqlite3_open(path, &db)) {
            print("Can't open database: {s}\n", .{c.sqlite3_errmsg(db)});
        }
        return .{ .db = db };
    }

    pub fn deinit(self: Self) void {
        _ = c.sqlite3_close(self.db);
    }

    pub fn execute(self: Self, query: [:0]const u8) !void {
        print("Running query: \"{s}\"\n", .{query});
        var errmsg: [*c]u8 = undefined;
        if (c.SQLITE_OK != c.sqlite3_exec(self.db, query, null, null, &errmsg)) {
            defer c.sqlite3_free(errmsg);
            std.debug.print("Exec query failed: {s}\n", .{errmsg});
            return error.execError;
        }
        return;
    }
    pub fn executeCB(self: Self, query: [:0]const u8, cb: QueryCallback, userdata: ?*anyopaque) !void {
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
            print("Can't retrieve data: {}\n", .{c.sqlite3_errmsg(self.db)});
            return error.CantRetrieve;
        }

        while (c.sqlite3_step(self.res) != c.SQLITE_ROW) {
            return error.TODO;
        }
    }
    pub fn finalizeFetch(self: Self) void {
        c.sqlite3_finalize(self.res);
    }
};
