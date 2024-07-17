const std = @import("std");
const datetime = @import("datetime.zig");
const Time = datetime.Time;
const Date = datetime.Date;
const RepeatInfo = datetime.RepeatInfo;
const event_lib = @import("event.zig");
const Event = event_lib.Event;
const Database = @import("database.zig").Database;
const Interval = @import("scheduler.zig").Interval;

pub fn cmpByDueDate(_: void, a: Task, b: Task) bool {
    if (a.due) |ad| {
        return ad.isBefore(b.due);
    } else if (b.due) |_| {
        return false;
    } else if (a.depth == b.depth) {
        if (a.gauge) |ag| {
            return if (b.gauge) |bg| ag < bg else false;
        } else {
            return b.gauge != null;
        }
    } else return a.depth < b.depth;
}

pub const Task = struct {
    const Self = @This();
    id: i32,
    parent: ?i32 = null,
    name: []const u8 = "",
    time: Time,
    start: ?Date = null,
    due: ?Date = null,
    repeat: ?Time = null,
    scheduled_start: ?Date = null,
    // TODO: Tasks should be able to be split, so we need scheduled_time
    deps: [32]?i32 = .{null} ** 32,
    earliest_due: ?Date = null,
    depth: i32 = -1,
    gauge: ?i32 = null,

    pub fn getEnd(self: Self) ?Date {
        return if (self.scheduled_start) |s| s.after(self.time) else self.due;
    }

    pub fn printInterval(self: Self) void {
        if (self.scheduled_start) |s| {
            std.debug.print("(scheduled) ", .{});
            s.print();
            std.debug.print(" ~ ", .{});
            self.getEnd().?.print();
            std.debug.print("\n", .{});
        } else {
            std.debug.print("No scheduled start; time = {any}\n", .{self.time});
        }
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
    var repeat: ?RepeatInfo = null;
    var gauge: ?i32 = null;
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
        } else if (std.mem.eql(u8, col, "repeat")) {
            if (val) |v|
                repeat = RepeatInfo.fromString(v) catch return -1;
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
        } else if (std.mem.eql(u8, col, "gauge")) {
            if (val) |v| {
                gauge = @as(i32, @intFromFloat(std.fmt.parseFloat(f32, v) catch return -1));
            }
        }
    }

    if (time == null) {
        time = .{ .seconds = 2 * 60 * 60 };
        if (start != null and due != null) {
            const max_time = due.?.timeSince(start.?);
            if (max_time.getSeconds() < time.?.getSeconds()) {
                time = max_time;
            }
        }
    }

    tasks.append(.{
        .id = id,
        .parent = parent,
        .name = allocator.dupe(u8, name_addr) catch unreachable,
        .time = time.?,
        .start = start,
        .due = due,
        .repeat = if (repeat) |r| r.period.time else null,
        .earliest_due = due,
        .scheduled_start = null,
        .deps = deps,
        .depth = if (parent == null) 0 else -1,
        .gauge = gauge,
    }) catch return -1;

    // Set correct depth of tasks
    while (true) {
        var changed = false;
        for (tasks.items) |*i| {
            if (i.depth != -1) continue;
            for (tasks.items) |j| {
                if (i.parent == j.id and j.depth != -1) {
                    i.depth = j.depth + 1;
                    changed = true;
                    break;
                }
            }
        }
        if (!changed) break;
    }
    return 0;
}

pub const DoneTask = struct {
    id: i32,
    time: Time,
    last_completed: ?Date,
};

pub const TaskList = struct {
    const Self = @This();
    tasks: std.ArrayList(Task),
    task_names: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    done: std.ArrayList(DoneTask),

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
            .done = std.ArrayList(DoneTask).init(allocator),
        };
    }

    pub fn initEmpty(allocator: std.mem.Allocator) Self {
        return .{
            .tasks = std.ArrayList(Task).init(allocator),
            .task_names = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
            .done = std.ArrayList(DoneTask).init(allocator),
        };
    }

    pub fn deinit(self: Self) void {
        for (self.task_names.items) |i|
            self.allocator.free(i);
        self.task_names.deinit();
        self.tasks.deinit();
        self.done.deinit();
    }

    pub fn clone(self: Self) !Self {
        const new_tasks = try self.tasks.clone();
        const new_names = try self.task_names.clone();
        for (new_names.items) |*i|
            i.* = try self.allocator.dupe(u8, i.*);
        return .{
            .tasks = new_tasks,
            .task_names = new_names,
            .done = try self.done.clone(),
            .allocator = self.allocator,
        };
    }

    pub fn getById(self: Self, id: i32) ?*Task {
        return for (self.tasks.items) |*t| {
            if (t.id == id) break t;
        } else null;
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

    pub fn reset(self: *Self) void {
        std.mem.sort(Task, self.tasks.items, {}, cmpByDueDate);
        self.done.clearRetainingCapacity();
    }

    pub fn next(self: *Self, interval: Interval) !?struct { task: Task, interval: ?Interval } {
        var best = try self.getBestTask(interval) orelse return null;
        best.scheduled_start = interval.start;

        var did_cut = false;
        const earliest_limit = Date.earliest(best.earliest_due, interval.end);

        if (earliest_limit != null and earliest_limit.?.isBefore(best.getEnd())) {
            best.time = earliest_limit.?.timeSince(interval.start);
            std.debug.assert(best.time.getSeconds() > 0);
            did_cut = true;
        }
        if (!best.getEnd().?.eql(best.getEnd().?.getDayStart()))
            std.debug.assert(best.scheduled_start.?.getDay() == best.getEnd().?.getDay());
        std.debug.assert(best.getEnd().?.isBeforeEq(interval.end));

        const completed = !did_cut or best.getEnd().?.eql(interval.end);
        try self.pushPartial(best, if (completed) best.getEnd().? else null);
        const ret_interval = Interval{ .start = best.getEnd().?, .end = interval.end };

        if (!completed) {
            return .{ .task = best, .interval = ret_interval };
        } else {
            return .{ .task = best, .interval = null };
        }
    }

    fn pushPartial(self: *TaskList, task: Task, last_completed: ?Date) !void {
        for (self.done.items) |*done| {
            if (task.id != done.id) continue;
            if (last_completed) |completed| {
                done.last_completed = completed;
                if (task.repeat != null)
                    done.time = .{ .seconds = 0 };
            } else {
                done.time = done.time.add(task.time);
            }
            return;
        }

        // If nothing was found
        if (task.repeat != null and last_completed != null) {
            try self.done.append(.{ .id = task.id, .time = .{ .seconds = 0 }, .last_completed = last_completed });
        } else {
            try self.done.append(.{ .id = task.id, .time = task.time, .last_completed = last_completed });
        }
    }

    fn getPartial(self: TaskList, task: Task, start: Date) ?Task {
        const partial = for (self.done.items) |j| {
            if (task.id == j.id) break j;
        } else null;

        if (partial) |p| {
            var new_t = task;
            if (p.last_completed) |last_completed| {
                if (task.repeat) |repeat| {
                    // If repeats, add the repeat period until the task start is
                    // after the current interval start

                    new_t.scheduled_start = last_completed;
                    while (Date.isBefore(new_t.due.?, start)) {
                        new_t.start = new_t.start.?.after(repeat);
                        new_t.due = new_t.due.?.after(repeat);
                        new_t.earliest_due = new_t.earliest_due.?.after(repeat);
                    }
                    // If the most recent, not-done repeated task starts after
                    // the last time it was completed, then we are too early
                    // to return it.
                    if (Date.isBefore(new_t.start, last_completed)) return null;
                } else return null;
            }
            if (new_t.time.getSeconds() > 0) {
                new_t.time = new_t.time.sub(p.time);
                if (new_t.time.getSeconds() <= 0) return null;
            }
            return new_t;
        } else {
            return task;
        }
    }

    pub fn getFirstTask(self: Self, task: Task, at_time: Date) ?Task {
        // Return first task that needs to be completed for this task to be
        // completed as well.
        // Starts by dependencies first, and then by children

        // But before that, we check if we are a repeating task that just ended
        if (task.repeat) |_| {
            if (task.earliest_due) |ed| {
                if (ed.eql(at_time)) {
                    return task;
                }
            }
        }

        for (task.deps) |d| {
            if (d == null) continue;
            if (self.getById(d.?)) |t_original| {
                const t = self.getPartial(t_original.*, at_time) orelse continue;
                if (t.start != null and at_time.isBefore(t.start.?)) return null;
                return self.getFirstTask(t, at_time);
            }
        }

        var has_pending_children = false;
        for (self.tasks.items) |t_original| {
            if (t_original.parent != task.id) continue;
            const t = self.getPartial(t_original, at_time) orelse continue;
            if (t.start != null and at_time.isBefore(t.start.?)) {
                has_pending_children = true;
                continue;
            }
            return self.getFirstTask(t, at_time);
        }
        if (has_pending_children) {
            return null;
        } else {
            return self.getPartial(task, at_time);
        }
    }

    fn getBestTask(self: *TaskList, interval: Interval) !?Task {
        var it_count: usize = 0;
        while (true) {
            it_count += 1;
            if (it_count > 10) {
                @panic("Something is wrong, too many iterations");
            }
            for (self.tasks.items) |original_t| {
                const t = self.getPartial(original_t, interval.start) orelse continue;

                if (interval.start.isBefore(t.start)) continue;
                if (Date.isBefore(t.earliest_due, interval.start)) continue;
                if (Date.eql(t.earliest_due, interval.start) and
                    original_t.time.getSeconds() != 0) continue;
                const first_task_opt = self.getFirstTask(t, interval.start);
                if (first_task_opt) |ret| {
                    var cloned = ret;
                    // TODO: Set this when loading the tasks, not on iteration
                    cloned.earliest_due = Date.earliest(cloned.earliest_due, t.earliest_due);
                    if (cloned.time.getSeconds() == 0) {
                        // We reached a task with zero seconds, so we just mark it as done
                        // and try again
                        const done_time = interval.end; // TODO: Improve this
                        try self.pushPartial(cloned, done_time);
                        break;
                    }
                    std.debug.assert(cloned.time.getSeconds() > 0);
                    return cloned;
                }
            } else {
                break;
            }
        }

        return null;
    }

    pub fn remove(self: *Self, to_remove: *Task) bool {
        for (self.tasks.items, 0..) |*t, i| {
            if (t.id == to_remove.id) {
                _ = self.tasks.orderedRemove(i);
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
