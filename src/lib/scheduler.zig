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
    start: Date,
    end: ?Date,

    pub fn print(self: Interval) void {
        self.start.print();
        std.debug.print(" ~ ", .{});
        if (self.end) |e| e.print() else std.debug.print("infinity", .{});
    }
};

const IntervalIterator = struct {
    const Self = @This();
    intervals: std.ArrayList(Interval),

    fn init(allocator: std.mem.Allocator, event_list: []Event, tasks: TaskList) !Self {
        _ = tasks; // TODO: Break intervals at start dates
        var events = try EventIterator.init(allocator, event_list, Date.now());
        defer events.deinit();
        var intervals = std.ArrayList(Interval).init(allocator);
        try intervals.append(.{ .start = Date.now(), .end = null });
        var i: usize = 0;
        const limit = Date.now().after(.{ .weeks = 1 });
        var e_opt = events.next(limit);
        while (i < intervals.items.len) {
            if (e_opt == null) break;
            const interval = &intervals.items[i];
            var start = interval.start;
            if (limit.isBefore(start)) break;

            if (interval.end) |end| {
                while (e_opt) |e| {
                    if (limit.isBefore(e.start)) break;
                    if (end.isBefore(e.start)) break; // Nothing to do
                    const e_end = e.getEnd();

                    if (e.start.isBeforeEq(start) and end.isBeforeEq(e_end)) {
                        // --------- | Interval | -----------
                        // ------ |     Event      | --------
                        _ = intervals.orderedRemove(i);
                    } else if (end.isBeforeEq(e_end) and e.start.isBeforeEq(end)) {
                        // --- | Interval | -----------
                        // ----------| Event | --------
                        interval.end = e.start;
                        i += 1;
                    } else if (start.isBeforeEq(e_end) and e.start.isBeforeEq(start)) {
                        // --------- | Interval | ----
                        // ------| Event | -----------
                        interval.start = e_end;
                        i += 1;
                    } else if (start.isBeforeEq(e.start) and e_end.isBeforeEq(end)) {
                        // ----- |   Interval   | -----
                        // ---------| Event | ---------
                        var copy = interval.*;
                        interval.end = e.start;
                        copy.start = e_end;
                        try intervals.insert(i + 1, copy);
                        i += 1;
                        break;
                    } else {
                        // Interval is after event; iterate over events to catch up
                        e_opt = events.next(limit);
                        if (e_opt == null) break;
                    }
                }
            } else {
                while (e_opt) |e| {
                    std.debug.assert(i == intervals.items.len - 1);
                    if (limit.isBefore(e.start)) break;
                    const e_end = e.getEnd();

                    if (start.isBeforeEq(e.start)) {
                        // --- | Interval                   -->
                        // ----------| Event | --------
                        var copy = interval.*;
                        interval.end = e.start;
                        copy.start = e_end;
                        try intervals.append(copy);
                        i += 1;
                        break;
                    } else if (e.start.isBeforeEq(start) and start.isBefore(e_end)) {
                        // --------- | Interval                  -->
                        // ------ |     Event      | --------
                        interval.start = e_end;
                        start = interval.start;
                    } else {
                        // Interval is after event; iterate over events to catch up
                        e_opt = events.next(limit);
                        if (e_opt == null) break;
                    }
                }
            }
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

pub fn cmpByDueDate(context: void, a: Task, b: Task) bool {
    _ = context;
    if (b.due) |bd| {
        return if (a.due) |ad| return ad.isBefore(bd) else false;
    } else if (a.due) |_| {
        return true;
    } else return a.id < b.id;
}

fn getBestTask(interval: Interval, tasks: *TaskList) ?*Task {
    if (Date.now().after(.{ .weeks = 1 }).isBefore(interval.start)) {
        std.debug.print("TODO REMOVE ME: Quitting early\n", .{});
        return null;
    }
    for (tasks.tasks.items) |*t| {
        if (t.start) |s| {
            if (interval.start.isBefore(s)) continue;
        }
        return tasks.getFirstTask(t, interval.start);
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

        std.mem.sort(Task, unscheduled.tasks.items, {}, cmpByDueDate);
        while (unscheduled.tasks.items.len > 0) {
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
