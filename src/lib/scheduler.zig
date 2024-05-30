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

const Interval = struct {
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

    pub fn subtract(self: *Self, other: Self) ?Self {
        // Not defined if self is inside other
        std.debug.assert(!self.isInside(other));
        // We don't need to implement this yet
        std.debug.assert(other.end != null);

        if (self.end != null and self.end.?.isBeforeEq(other.end.?) and other.start.isBefore(self.end.?)) {
            // --- | Interval | -----------
            // ----------| Event | --------
            self.end = other.start;
        } else if (self.start.isBefore(other.end.?) and other.start.isBeforeEq(self.start)) {
            // --------- | Interval | ----
            // ------| Event | -----------
            self.start = other.end.?;
        } else if (other.isInside(self.*)) {
            // ----- |   Interval   | -----
            // ---------| Event | ---------
            const old_end = self.end;
            self.end = other.start;
            return .{ .start = other.end.?, .end = old_end };
        } // else: Doesn't intersect, do nothing
        return null;
    }
};

fn getInterval(e: Event) Interval {
    return .{ .start = e.start, .end = e.getEnd() };
}

const IntervalIterator = struct {
    const Self = @This();
    intervals: std.ArrayList(Interval),

    fn init(allocator: std.mem.Allocator, event_list: []Event, tasks: TaskList) !Self {
        var events = try EventIterator.init(allocator, event_list, Date.now());
        defer events.deinit();
        var intervals = std.ArrayList(Interval).init(allocator);
        try intervals.append(.{ .start = Date.now(), .end = null });
        const limit = Date.now().after(.{ .weeks = 1 }).getWeekStart();

        // Split intervals at tasks starts
        const sorted_tasks = try tasks.tasks.clone();
        defer sorted_tasks.deinit();
        std.mem.sort(Task, sorted_tasks.items, {}, cmpByStartDate);
        for (sorted_tasks.items) |t| {
            if (t.start) |s| {
                const i = &intervals.items[intervals.items.len - 1];
                if (s.isBeforeEq(i.start)) continue;
                i.end = s;
                std.debug.assert(i.start.isBefore(s));
                try intervals.append(.{ .start = s, .end = null });
            } else break; // since the list is sorted, there isn't any more starts
        }

        // Remove event intervals from interval list
        var i: usize = 0;
        // TODO: It doesn't seem like this really needs to be an optional
        var e_opt = events.next(limit);
        while (i < intervals.items.len) {
            if (e_opt) |e| {
                const interval = &intervals.items[i];
                if (limit.isBefore(interval.start)) break;

                if (interval.end != null and interval.end.?.isBefore(e_opt.?.start)) {
                    i += 1;
                    continue;
                }

                if (limit.isBefore(e.start)) continue;

                const e_int = getInterval(e);

                if (interval.isInside(e_int)) {
                    _ = intervals.orderedRemove(i);
                } else {
                    const old_interval: Interval = interval.*;
                    const extra_opt = interval.subtract(e_int);
                    if (extra_opt) |extra| {
                        i += 1;
                        try intervals.insert(i, extra);
                        e_opt = events.next(limit);
                        continue;
                    }

                    const changed_end = if (old_interval.end) |old_end|
                        interval.end != null and interval.end.?.isBefore(old_end)
                    else
                        interval.end != null;

                    if (old_interval.start.isBeforeEq(interval.start) and !changed_end) {
                        e_opt = events.next(limit);
                    }
                }
            } else break;
        }

        return .{
            .intervals = intervals,
        };
    }

    fn deinit(self: Self) void {
        self.intervals.deinit();
    }

    fn next(self: *Self, step: Time) ?Interval {
        var cur = &self.intervals.items[0];
        while (true) {
            if (cur.end) |e| {
                if (e.isBeforeEq(cur.start)) {
                    _ = self.intervals.orderedRemove(0);
                    if (self.intervals.items.len == 0) return null;
                } else {
                    break;
                }
            } else break;
        }

        // Generate interval to return
        var ret = cur.*;
        ret.end = ret.start.after(step);
        if (cur.end != null and cur.end.?.isBefore(ret.end.?))
            ret.end = cur.end;

        // Split at day transition
        const day_end = ret.start.after(.{ .days = 1 }).getDayStart();
        if (day_end.isBefore(ret.end.?))
            ret.end = day_end;

        cur.start = ret.end.?;

        return ret;
    }
};

pub fn cmpByDueDate(_: void, a: Task, b: Task) bool {
    if (b.due) |bd| {
        return if (a.due) |ad| return ad.isBefore(bd) else false;
    } else if (a.due) |_| {
        return true;
    } else return a.id < b.id;
}
pub fn cmpByStartDate(_: void, a: Task, b: Task) bool {
    if (b.start) |bs| {
        return if (a.start) |as| return as.isBefore(bs) else false;
    } else if (a.start) |_| {
        return true;
    } else return a.id < b.id;
}

fn getBestTask(interval: Interval, tasks: *TaskList) ?*Task {
    if (Date.now().after(.{ .weeks = 1 }).isBefore(interval.start)) {
        std.debug.print("TODO REMOVE ME: Quitting early\n", .{});
        return null;
    }
    for (tasks.tasks.items) |*t| {
        if (t.start != null and interval.start.isBefore(t.start.?)) continue;
        if (tasks.getFirstTask(t, interval.start)) |ret|
            return ret;
    }

    return null;
}

pub const Scheduler = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    intervals: IntervalIterator,

    pub fn init(allocator: std.mem.Allocator, events: []Event, tl: TaskList) !Self {
        return .{
            .allocator = allocator,
            .intervals = try IntervalIterator.init(allocator, events, tl),
        };
    }

    pub fn deinit(self: Self) void {
        self.intervals.deinit();
    }

    pub fn reset(self: *Self, event_list: []Event, tasks: TaskList) !void {
        self.intervals.deinit();
        self.intervals = try IntervalIterator.init(self.allocator, event_list, tasks);
    }

    pub fn scheduleTasks(self: *Self, tl: TaskList) !TaskList {
        var scheduled = TaskList{ .tasks = std.ArrayList(Task).init(self.allocator), .allocator = self.allocator };
        var unscheduled = TaskList{ .tasks = try tl.tasks.clone(), .allocator = tl.allocator };

        // TODO Split intervals based on start dates of tasks
        var interval = self.intervals.intervals.items[0];

        while (unscheduled.tasks.items.len > 0) {
            std.mem.sort(Task, unscheduled.tasks.items, {}, cmpByDueDate);
            const best = getBestTask(interval, &unscheduled) orelse break;
            interval = self.intervals.next(best.time) orelse return scheduled;
            best.scheduled_start = interval.start;
            if (interval.end) |e| {
                if (e.isBefore(best.getEnd().?)) {
                    var copy = best.*;
                    copy.time = e.timeSince(interval.start);
                    best.time = best.time.sub(copy.time);

                    try scheduled.tasks.append(copy);
                } else {
                    try scheduled.tasks.append(best.*);
                    if (!unscheduled.remove(best)) unreachable;
                }
            } else {
                try scheduled.tasks.append(best.*);
                if (!unscheduled.remove(best)) unreachable;
            }
        }

        // TODO Merge tasks that start right after another (artifact of spliting
        // intervals at start dates)

        return scheduled;
    }
};
