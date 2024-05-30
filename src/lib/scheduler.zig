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

    pub fn subtract(self: *Self, other: Self) struct { changed: bool, extra: ?Self } {
        // Not defined if self is inside other
        std.debug.assert(!self.isInside(other));
        // We don't need to implement this yet
        std.debug.assert(other.end != null);

        if (self.end != null and self.end.?.isBeforeEq(other.end.?) and other.start.isBefore(self.end.?)) {
            // --- | Interval | -----------
            // ----------| Event | --------
            self.end = other.start;
            return .{ .changed = true, .extra = null };
        } else if (self.start.isBefore(other.end.?) and other.start.isBeforeEq(self.start)) {
            // --------- | Interval | ----
            // ------| Event | -----------
            self.start = other.end.?;
            return .{ .changed = true, .extra = null };
        } else if (other.isInside(self.*)) {
            // ----- |   Interval   | -----
            // ---------| Event | ---------
            const old_end = self.end;
            self.end = other.start;
            return .{ .changed = true, .extra = .{ .start = other.end.?, .end = old_end } };
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
                    const subtract_info = interval.subtract(e_int);
                    if (subtract_info.extra) |extra| {
                        i += 1;
                        try intervals.insert(i, extra);
                        e_opt = events.next(limit);
                        continue;
                    }

                    if (!subtract_info.changed) {
                        if (e_int.endsEarlierThan(interval.*)) {
                            e_opt = events.next(limit);
                        } else {
                            i += 1;
                        }
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
        var sub_time = step;
        while (true) {
            cur = &self.intervals.items[0];
            const next_start = cur.start.after(sub_time);
            if (cur.end) |e| {
                if (e.isBeforeEq(next_start)) {
                    sub_time = sub_time.sub(e.timeSince(cur.start));
                    _ = self.intervals.orderedRemove(0);
                    if (self.intervals.items.len == 0) return null;
                    continue;
                }
            }
            cur.start = next_start;
            break;
        }

        // Split at day transition
        const day_end = cur.start.after(.{ .days = 1 }).getDayStart();
        if (day_end.isBefore(cur.end.?))
            cur.end = day_end;

        return cur.*;
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
    if (Date.now().after(.{ .weeks = 1 }).getWeekStart().isBefore(interval.start)) {
        std.debug.print("TODO REMOVE ME: Quitting early\n", .{});
        return null;
    }
    for (tasks.tasks.items) |*t| {
        if (t.start != null and interval.start.isBefore(t.start.?)) continue;
        if (tasks.getFirstTask(t, interval.start)) |ret| return ret;
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

        var interval = self.intervals.intervals.items[0];

        while (unscheduled.tasks.items.len > 0) {
            std.mem.sort(Task, unscheduled.tasks.items, {}, cmpByDueDate);
            const best: *Task = getBestTask(interval, &unscheduled) orelse break;
            best.scheduled_start = interval.start;
            var step = best.time;
            // NOTE: The appends from now on will invalidate `best`
            if (interval.end) |e| {
                if (e.isBefore(best.getEnd().?)) {
                    var copy = best.*;
                    best.time = e.timeSince(interval.start);
                    step = best.time;
                    copy.time = copy.time.sub(best.time);

                    try unscheduled.tasks.append(copy);
                }
            }
            try scheduled.tasks.append(best.*);
            if (!unscheduled.remove(best)) unreachable;
            interval = self.intervals.next(step) orelse return scheduled;
        }

        var i: usize = 0;
        while (i < scheduled.tasks.items.len - 1) { // Yes, we ignore the last element
            const cur = &scheduled.tasks.items[i];
            const next = scheduled.tasks.items[i + 1];
            i += 1;
            if (cur.id != next.id) continue;

            if (next.scheduled_start.?.isBeforeEq(cur.getEnd().?)) {
                cur.time = cur.time.add(next.time);
                _ = scheduled.tasks.orderedRemove(i);
                i -= 1;
            }
        }

        return scheduled;
    }
};
