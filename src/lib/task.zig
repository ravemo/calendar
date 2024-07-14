const std = @import("std");
const datetime = @import("datetime.zig");
const Time = datetime.Time;
const Date = datetime.Date;
const event_lib = @import("event.zig");
const Event = event_lib.Event;
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
    deps: [32]?i32,
    is_due_dep: bool = false,

    pub fn getEnd(self: Self) ?Date {
        return if (self.scheduled_start) |s| s.after(self.time) else self.due;
    }
};

fn load_task_cb(tasks_ptr: ?*anyopaque, argc: c_int, argv: [*c][*c]u8, cols: [*c][*c]u8) callconv(.C) c_int {
    const tasks: *std.ArrayList(Task) = @alignCast(@ptrCast(tasks_ptr));
    const allocator = tasks.allocator;
    var id: i32 = undefined;
    var parent: ?i32 = null;
    var name_addr: []const u8 = undefined;
    var time: ?Time = null;
    var start: ?Date = null;
    var due: ?Date = null;
    var deps = [_]?i32{null} ** 32;

    for (0..@intCast(argc)) |i| {
        const col = std.mem.span(cols[i]);
        const val = if (argv[i]) |v| std.mem.span(v) else null;
        if (std.mem.eql(u8, col, "uuid")) {
            id = std.fmt.parseInt(i32, val.?, 10) catch return -1;
        } else if (std.mem.eql(u8, col, "parent")) {
            if (val) |v|
                parent = std.fmt.parseInt(i32, v, 10) catch return -1;
        } else if (std.mem.eql(u8, col, "desc")) {
            name_addr = val orelse return -1;
        } else if (std.mem.eql(u8, col, "start")) {
            if (val) |v|
                start = Date.fromString(v) catch return -1;
        } else if (std.mem.eql(u8, col, "due")) {
            if (val) |v|
                due = Date.fromString(v) catch return -1;
        } else if (std.mem.eql(u8, col, "time")) {
            if (val) |v| {
                time = .{ .seconds = std.fmt.parseInt(i32, v, 10) catch return -1 };
            }
        } else if (std.mem.eql(u8, col, "status")) {
            if (val != null) return 0; // We don't care about finished tasks for now
        } else if (std.mem.eql(u8, col, "depends")) {
            if (val) |v| {
                var it = std.mem.splitSequence(u8, v, " ");
                var idx: usize = 0;
                while (it.next()) |substr| {
                    if (std.mem.trim(u8, substr, " ").len == 0) continue;
                    deps[idx] = std.fmt.parseInt(i32, substr, 10) catch return -1;
                    idx += 1;
                    std.debug.assert(idx < 32);
                }
            }
        } else if (std.mem.eql(u8, col, "tags")) {
            if (val) |v| {
                var it = std.mem.splitSequence(u8, v, " ");
                while (it.next()) |substr| {
                    if (std.mem.eql(u8, substr, "_group"))
                        time = .{ .seconds = 0 };
                }
            }
        } else {
            if (false) std.debug.print("Unhandled column: {s}\n", .{col});
        }
    }

    tasks.append(.{
        .id = id,
        .parent = parent,
        .name = allocator.dupe(u8, name_addr) catch unreachable,
        .time = time orelse .{ .seconds = 2 * 60 * 60 },
        .start = start,
        .due = due,
        .scheduled_start = null,
        .deps = deps,
    }) catch return -1;
    return 0;
}

pub const TaskList = struct {
    const Self = @This();
    tasks: std.ArrayList(Task),
    task_names: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, db: Database) !Self {
        var tasks = std.ArrayList(Task).init(allocator);
        var task_names = std.ArrayList([]const u8).init(allocator);
        const query = try std.fmt.allocPrintZ(allocator,
            \\ SELECT * FROM tasks;
        , .{});
        defer allocator.free(query);

        try db.executeCB(query, load_task_cb, &tasks);
        for (tasks.items) |*t| {
            try task_names.append(t.name); // It is owned here now
        }
        std.debug.print("Loaded {} tasks.\n", .{tasks.items.len});
        return .{
            .tasks = tasks,
            .task_names = task_names,
            .allocator = allocator,
        };
    }

    pub fn initEmpty(allocator: std.mem.Allocator) Self {
        return .{
            .tasks = std.ArrayList(Task).init(allocator),
            .task_names = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: Self) void {
        for (self.task_names.items) |i|
            self.allocator.free(i);
        self.task_names.deinit();
        self.tasks.deinit();
    }

    pub fn clone(self: Self) !Self {
        const new_tasks = try self.tasks.clone();
        const new_names = try self.task_names.clone();
        for (new_names.items) |*i|
            i.* = try self.allocator.dupe(u8, i.*);
        return .{
            .tasks = new_tasks,
            .task_names = new_names,
            .allocator = self.allocator,
        };
    }

    pub fn getById(self: Self, id: i32) ?*Task {
        for (self.tasks.items) |*t| {
            if (t.id == id) return t;
        }
        return null;
    }

    pub fn getParent(self: Self, task: Task) !?*Task {
        return if (task.parent) |p|
            self.getById(p) orelse error.InvalidParent
        else
            null;
    }
    pub fn sanitize(self: *Self) !void {
        // Remove all dependencies that have been completed
        for (self.tasks.items) |*t| {
            for (&t.deps) |*d| {
                if (d.* == null) continue;
                // TODO: rather than just setting to null, swap with last non-null
                // first. This way we can always break on null rather than having
                // to continue and iterate over all 32 deps
                if (self.getById(d.*.?) == null) d.* = null;
            }
        }

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

    pub fn getFirstTask(self: Self, task: *Task, at_time: Date) ?*Task {
        // Return first task that needs to be completed for this task to be
        // completed as well.
        // Starts by dependencies first, and then by children

        for (task.deps) |d| {
            if (d == null) continue;
            if (self.getById(d.?)) |t| {
                if (t.start != null and at_time.isBeforeEq(t.start.?)) return null;
                return self.getFirstTask(t, at_time);
            }
        }

        var has_pending_children = false;
        for (self.tasks.items) |*t| {
            if (t.parent == task.id) {
                if (t.start != null and at_time.isBeforeEq(t.start.?)) {
                    has_pending_children = true;
                    continue;
                }
                return self.getFirstTask(t, at_time);
            }
        }
        return if (has_pending_children) null else task;
    }

    pub fn remove(self: *Self, to_remove: *Task) bool {
        for (self.tasks.items, 0..) |*t, i| {
            if (t == to_remove) {
                _ = self.tasks.swapRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn checkOverlap(self: Self) !void {
        var last_end = self.tasks.items[0].getEnd().?;
        for (self.tasks.items[1..]) |task| {
            const new_start = task.scheduled_start.?;
            const new_end = task.getEnd().?;
            std.debug.assert(last_end.isBeforeEq(new_start));
            std.debug.assert(new_start.isBeforeEq(new_end));
            last_end = new_end;
        }
    }
};
