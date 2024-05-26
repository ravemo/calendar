const std = @import("std");
const calendar = @import("event.zig");
const Time = calendar.Time;
const Date = calendar.Date;
const Event = calendar.Event;
const Database = @import("database.zig").Database;

pub const Task = struct {
    const Self = @This();
    id: i32,
    parent: ?i32,
    name: []const u8,
    time: Time,
    start: ?Date,
    due: ?Date,
    // TODO: repeat info
    scheduled_start: ?Date,
    // TODO: Tasks should be able to be split, so we need scheduled_time

    pub fn getEnd(self: Self) ?Date {
        return if (self.scheduled_start) |s| s.after(self.time) else self.due;
    }
};

fn load_task_cb(tasks_ptr: ?*anyopaque, argc: c_int, argv: [*c][*c]u8, cols: [*c][*c]u8) callconv(.C) c_int {
    const tasks: *std.ArrayList(Task) = @alignCast(@ptrCast(tasks_ptr));
    const allocator = tasks.allocator;
    var id: i32 = undefined;
    var parent: ?i32 = null;
    var name: []const u8 = undefined;
    var time: Time = undefined;
    var start: ?Date = null;
    var due: ?Date = null;

    for (0..@intCast(argc)) |i| {
        const col = std.mem.span(cols[i]);
        const val = if (argv[i]) |v| std.mem.span(v) else null;
        if (std.mem.eql(u8, col, "uuid")) {
            id = std.fmt.parseInt(i32, val.?, 10) catch return -1;
        } else if (std.mem.eql(u8, col, "parent")) {
            if (val) |v|
                parent = std.fmt.parseInt(i32, v, 10) catch return -1;
        } else if (std.mem.eql(u8, col, "desc")) {
            name = allocator.dupe(u8, val.?) catch return -1;
        } else if (std.mem.eql(u8, col, "start")) {
            if (val) |v|
                start = Date.fromString(v) catch return -1;
        } else if (std.mem.eql(u8, col, "due")) {
            if (val) |v|
                due = calendar.Date.fromString(v) catch return -1;
        } else if (std.mem.eql(u8, col, "time")) {
            time = .{ .seconds = if (val) |v| std.fmt.parseInt(i32, v, 10) catch return -1 else 2 * 60 * 60 };
        } else if (std.mem.eql(u8, col, "status")) {
            if (val != null) return 0; // We don't care about finished tasks for now
        } else {
            if (false) std.debug.print("Unhandled column: {s}\n", .{col});
        }
    }

    tasks.append(.{
        .id = id,
        .parent = parent,
        .name = name,
        .time = time,
        .start = start,
        .due = due,
        .scheduled_start = null,
    }) catch return -1;
    return 0;
}

pub const TaskList = struct {
    const Self = @This();
    tasks: std.ArrayList(Task),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, db: Database) !Self {
        var tasks = std.ArrayList(Task).init(allocator);
        const query = try std.fmt.allocPrintZ(allocator,
            \\ SELECT * FROM tasks;
        , .{});
        defer allocator.free(query);

        try db.executeCB(query, load_task_cb, &tasks);
        std.debug.print("Loaded {} tasks.\n", .{tasks.items.len});
        return .{ .tasks = tasks, .allocator = allocator };
    }

    pub fn getParent(self: Self, task: Task) !?*Task {
        if (task.parent == null) return null;
        for (self.tasks.items) |*t| {
            if (t.id == task.parent) return t;
        }
        return error.InvalidParent;
    }
    pub fn sanitize(self: *Self) !void {
        // Remove all subtasks that haven't been completed but whose parents have
        var changed = true;
        while (changed) {
            changed = false;
            for (self.tasks.items, 0..) |*t, i| {
                _ = self.getParent(t.*) catch {
                    changed = true;
                    _ = self.tasks.swapRemove(i);
                    break;
                };
            }
        }

        // Make all subtasks due dates and start dates consistent
        changed = true;
        while (changed) {
            changed = false;
            for (self.tasks.items) |*t| {
                const parent = try self.getParent(t.*);
                if (parent) |p| {
                    if (p.start) |s| {
                        if (t.start == null or t.start.?.isBefore(s)) {
                            t.start = p.start;
                            changed = true;
                        }
                    }
                }
            }
        }
    }

    pub fn getNextFree(self: Self, now: Date) Date {
        var free = now;
        var changed = true;
        while (changed) {
            changed = false;
            for (self.tasks) |t| {
                if (t.scheduled_start) |s| {
                    if (s.isBeforeEq(free) and free.isBefore(t.getEnd())) {
                        changed = true;
                        free = t.getEnd();
                    }
                }
            }
        }
        return free;
    }

    pub fn getFirstTask(self: Self, task: *Task) *Task {
        // Return first task that needs to be completed for this task to be
        // completed as well.
        // Starts by dependencies first, and then by children

        // TODO: Handle dependencies
        for (self.tasks.items) |*t| {
            if (t.parent == task.id) {
                return self.getFirstTask(t);
            }
        }
        return task;
    }
};
