const std = @import("std");
const datetime = @import("datetime.zig");
const Time = datetime.Time;
const Date = datetime.Date;
const event_lib = @import("event.zig");
const Event = event_lib.Event;
const EventIterator = event_lib.EventIterator;
const task_lib = @import("task.zig");
const Task = task_lib.Task;
const TaskList = task_lib.TaskList;

const print = std.debug.print;

pub const Interval = struct {
    // A Interval is a semi-open interval from [start, end)
    const Self = @This();
    start: Date,
    end: ?Date,

    pub fn print(self: Self) void {
        self.start.print();
        std.debug.print(" ~ ", .{});
        if (self.end) |e| e.print() else std.debug.print("infinity", .{});
        std.debug.print("\n", .{});
    }

    pub fn isInside(self: Self, other: Self) bool {
        const starts_after = other.start.isBeforeEq(self.start);
        if (other.end == null) return starts_after;

        return if (self.end) |self_end|
            starts_after and self_end.isBeforeEq(other.end.?)
        else
            false;
    }

    pub fn subtract(self: *Self, other: Self) struct { changed: bool, extra: ?Self } {
        // Not defined if self is inside other
        std.debug.assert(!self.isInside(other));
        // We don't need to implement this yet
        std.debug.assert(other.end != null);

        if (self.end != null and self.end.?.isBeforeEq(other.end.?) and other.start.isBefore(self.end.?)) {
            // --- | Self     | -----------
            // ----------| Other | --------
            self.end = other.start;
            return .{ .changed = true, .extra = null };
        } else if (self.start.isBefore(other.end.?) and other.start.isBeforeEq(self.start)) {
            // --------- | Self     | ----
            // ------| Other | -----------
            self.start = other.end.?;
            return .{ .changed = true, .extra = null };
        } else if (other.isInside(self.*)) {
            // ----- |   Self       | -----
            // ---------| Other | ---------
            const old_end = self.end;
            self.end = other.start;
            const extra = Self{ .start = other.end.?, .end = old_end };
            return .{ .changed = true, .extra = extra };
        } // else: Doesn't intersect, do nothing
        return .{ .changed = false, .extra = null };
    }

    pub fn endsEarlierThan(self: Self, other: Self) bool {
        if (self.end) |se| {
            return if (other.end) |oe| se.isBeforeEq(oe) else true;
        } else return false;
    }
};

fn getInterval(e: Event) Interval {
    return .{ .start = e.start, .end = e.getEnd() };
}

const IntervalIterator = struct {
    const Self = @This();
    intervals: std.ArrayList(Interval),

    fn init(allocator: std.mem.Allocator, event_list: []Event, tasks: TaskList, start: Date) !Self {
        var events = try EventIterator.init(allocator, event_list, start);
        defer events.deinit();
        var self = Self{
            .intervals = std.ArrayList(Interval).init(allocator),
        };
        try self.intervals.append(.{ .start = start, .end = null });

        // Split intervals at tasks starts
        const sorted_tasks = try tasks.tasks.clone();
        defer sorted_tasks.deinit();
        std.mem.sort(Task, sorted_tasks.items, {}, cmpByStartDate);
        for (sorted_tasks.items) |t| {
            if (t.start) |s| {
                const i = &self.intervals.items[self.intervals.items.len - 1];
                if (s.isBeforeEq(i.start)) continue;
                i.end = s;
                std.debug.assert(i.start.isBefore(s));
                try self.intervals.append(.{ .start = s, .end = null });
            } else break; // since the list is sorted, there isn't any more starts
        }

        // Test for holes
        {
            var last_end = self.intervals.items[0].end;
            for (self.intervals.items[1..], 1..) |int, i| {
                if (i < self.intervals.items.len - 1) std.debug.assert(int.end != null);
                std.debug.assert(int.start.eql(last_end.?));
                last_end = int.end;
            }
            std.debug.assert(last_end == null);
        }

        // Remove event intervals from interval list
        // TODO: Do this in a lazy manner, i.e. when iterating over intervals
        const limit = start.after(.{ .weeks = 4 });
        while (events.next(limit)) |e| {
            if (limit.isBefore(getInterval(e).start)) break;
            try self.remove(getInterval(e), limit);
        }

        try self.checkOverlaps();

        return self;
    }

    fn deinit(self: Self) void {
        self.intervals.deinit();
    }

    fn next(self: *Self, step: Time) !?Interval {
        const first = self.intervals.items[0];
        if (step.getSeconds() > 0) {
            self.remove(Interval{
                .start = first.start,
                .end = first.start.after(step),
            }, null) catch unreachable;
        }
        const cur = &self.intervals.items[0];

        // Split at day transition
        const day_end = cur.start.after(.{ .days = 1 }).getDayStart();
        if (day_end.isBefore(cur.end)) {
            const ret = Interval{ .start = cur.start, .end = day_end };
            cur.start = day_end;
            try self.intervals.insert(0, ret);
            return ret;
        }

        return cur.*;
    }

    fn remove(self: *Self, toRemove: Interval, limit: ?Date) !void {
        var i: usize = 0;
        while (i < self.intervals.items.len) {
            const interval = &self.intervals.items[i];
            if (limit != null and limit.?.isBefore(interval.start)) break;

            if (interval.end != null and interval.end.?.isBefore(toRemove.start)) {
                i += 1;
                continue;
            }

            if (interval.isInside(toRemove)) {
                _ = self.intervals.orderedRemove(i);
            } else {
                const subtract_info = interval.subtract(toRemove);
                if (subtract_info.extra) |extra| {
                    i += 1;
                    try self.intervals.insert(i, extra);
                } else if (!subtract_info.changed) {
                    if (!toRemove.endsEarlierThan(interval.*)) {
                        i += 1;
                    } else {
                        break;
                    }
                }
            }
        }
    }

    fn checkOverlaps(self: Self) !void {
        var last_end = self.intervals.items[0].end;
        for (self.intervals.items[1..], 1..) |int, i| {
            std.debug.assert(last_end != null);
            if (i < self.intervals.items.len - 1) std.debug.assert(int.end != null);
            std.debug.assert(int.start.isBefore(int.end));
            std.debug.assert(last_end.?.isBeforeEq(int.start));
            last_end = int.end;
        }
        std.debug.assert(last_end == null);
    }
};

pub fn cmpByDueDate(_: void, a: Task, b: Task) bool {
    if (b.due) |bd| {
        return if (a.due) |ad| return ad.isBefore(bd) else false;
    } else if (a.due) |_| {
        return true;
    } else return false;
}
pub fn cmpByStartDate(_: void, a: Task, b: Task) bool {
    if (b.start) |bs| {
        return if (a.start) |as| return as.isBefore(bs) else false;
    } else if (a.start) |_| {
        return true;
    } else return false;
}

fn getBestTask(interval: Interval, tasks: *TaskList) ?*Task {
    for (tasks.tasks.items) |*t| {
        if (interval.start.isBefore(t.start)) continue;
        if (tasks.getFirstTask(t, interval.start)) |ret| {
            ret.is_due_dep = (t.due != null);
            return ret;
        }
    }

    return null;
}

pub const Scheduler = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    intervals: IntervalIterator,
    start: Date,

    pub fn init(allocator: std.mem.Allocator, events: []Event, tl: TaskList, start: Date) !Self {
        const intervals = try IntervalIterator.init(allocator, events, tl, start);
        return .{
            .allocator = allocator,
            .intervals = intervals,
            .start = start,
        };
    }

    pub fn deinit(self: Self) void {
        self.intervals.deinit();
    }

    pub fn reset(self: *Self, event_list: []Event, tasks: TaskList) !void {
        self.intervals.deinit();
        self.intervals = try IntervalIterator.init(self.allocator, event_list, tasks, self.start);
    }

    pub fn scheduleTasks(self: *Self, tl: TaskList) !TaskList {
        var scheduled = TaskList.initEmpty(self.allocator);
        var unscheduled = try tl.clone();
        defer unscheduled.deinit();

        var interval = self.intervals.intervals.items[0];

        while (unscheduled.tasks.items.len > 0) {
            std.mem.sort(Task, unscheduled.tasks.items, {}, cmpByDueDate);
            const best: *Task = getBestTask(interval, &unscheduled) orelse break;
            best.scheduled_start = interval.start;
            var step = best.time;
            // NOTE: The appends from now on will invalidate `best`
            if (interval.end) |e| {
                if (e.isBefore(best.getEnd())) {
                    var copy = best.*;
                    best.time = e.timeSince(interval.start);
                    copy.scheduled_start = null;
                    step = best.time;
                    copy.time = copy.time.sub(best.time);

                    try unscheduled.tasks.append(copy);
                }
            }
            try scheduled.tasks.append(best.*);
            if (!best.getEnd().?.eql(best.getEnd().?.getDayStart()))
                std.debug.assert(best.scheduled_start.?.getDay() == best.getEnd().?.getDay());
            if (!unscheduled.remove(best)) unreachable;
            interval = try self.intervals.next(step) orelse return scheduled;
        }

        // Merge intervals
        var i: usize = 0;
        while (i < scheduled.tasks.items.len - 1) { // Yes, we ignore the last element
            const cur = &scheduled.tasks.items[i];
            const next = scheduled.tasks.items[i + 1];
            i += 1;
            if (cur.id != next.id) continue; // Don't merge different tasks
            const cur_end = cur.getEnd().?;
            // Don't merge tasks that cross midnight
            if (cur_end.eql(cur_end.getDayStart())) continue;

            if (next.scheduled_start.?.eql(cur_end)) {
                cur.time = cur.time.add(next.time);
                _ = scheduled.tasks.orderedRemove(i);
                i -= 1;
            }
        }

        try scheduled.checkOverlap();

        return scheduled;
    }
};

test "Interval check" {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .enable_memory_limit = true,
    }){ .requested_memory_limit = 1024 * 1024 * 10 };
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();

    const now = Date.now();

    const tl = TaskList{
        .tasks = std.ArrayList(Task).init(alloc),
        .task_names = std.ArrayList([]const u8).init(alloc),
        .allocator = alloc,
    };
    defer tl.deinit();

    const events = [0]Event{};

    const intervals = try IntervalIterator.init(alloc, &events, tl, now);
    defer intervals.deinit();
    try std.testing.expectEqual(1, intervals.intervals.items.len);
    try std.testing.expectEqual(now, intervals.intervals.items[0].start);
    try std.testing.expectEqual(null, intervals.intervals.items[0].end);
}

test "Start cut" {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .enable_memory_limit = true,
    }){ .requested_memory_limit = 1024 * 1024 * 10 };
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();

    const now = Date.now();
    const task1 = .{ .id = 0, .time = Time.initH(2), .start = now };
    const task2 = .{ .id = 1, .time = Time.initH(1), .start = now.after(Time.initH(1)) };
    var tasks = std.ArrayList(Task).init(alloc);
    try tasks.append(task1);
    try tasks.append(task2);

    const tl = TaskList{
        .tasks = tasks,
        .task_names = std.ArrayList([]const u8).init(alloc),
        .allocator = alloc,
    };
    defer tl.deinit();
    const events = [0]Event{};

    var scheduler = try Scheduler.init(alloc, &events, tl, now);
    try std.testing.expectEqual(2, scheduler.intervals.intervals.items.len);
    defer scheduler.deinit();

    const new_tl = try scheduler.scheduleTasks(tl);
    defer new_tl.deinit();

    try std.testing.expectEqual(3, new_tl.tasks.items.len);

    try std.testing.expectEqual(0, new_tl.tasks.items[0].id);
    try std.testing.expectEqual(1, new_tl.tasks.items[1].id);
    try std.testing.expectEqual(0, new_tl.tasks.items[2].id);

    try std.testing.expectEqual(60 * 60, new_tl.tasks.items[0].time.getSeconds());
    try std.testing.expectEqual(60 * 60, new_tl.tasks.items[1].time.getSeconds());
    try std.testing.expectEqual(60 * 60, new_tl.tasks.items[2].time.getSeconds());
}
