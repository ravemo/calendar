const std = @import("std");
const datetime = @import("datetime.zig");
const Time = datetime.Time;
const Date = datetime.Date;
const event_lib = @import("event.zig");
const Event = event_lib.Event;
const task_lib = @import("task.zig");
const Task = task_lib.Task;
const TaskList = task_lib.TaskList;

const Interval = struct {
    start: Date,
    end: ?Date,
};

const IntervalIterator = struct {
    const Self = @This();
    cur: Interval,

    fn init(allocator: std.mem.Allocator, events: []Event, tasks: TaskList) Self {
        _ = allocator; // TODO: store multiple intervals rather than a single one
        _ = events; // TODO: Break intervals based on events
        _ = tasks; // TODO: Break intervals at start dates
        return .{
            .cur = .{ .start = Date.now(), .end = null },
        };
    }

    fn next(self: *Self, step: Time) ?Interval {
        if (self.cur.end) |e|
            if (e.isBeforeEq(self.cur.start)) return null;

        var ret = self.cur;
        ret.end = ret.start.after(step);
        const day_end = self.cur.start.after(.{ .days = 1 }).getDayStart();
        if (self.cur.end) |e| {
            if (day_end.isBefore(e))
                ret.end = day_end;
        } else if (day_end.isBefore(ret.end.?)) ret.end = day_end;

        self.cur.start = ret.end.?;
        return ret;
    }
};

pub fn cmpByStartDate(context: void, a: *Task, b: *Task) bool {
    _ = context;
    if (b.start) |bd| {
        if (a.start) |ad| {
            return ad.isBefore(bd);
        } else false;
    } else false;
}

pub fn cmpByDueDate(context: void, a: Task, b: Task) bool {
    _ = context;
    if (b.due) |bd| {
        if (a.due) |ad| {
            return ad.isBefore(bd);
        } else return false;
    } else return false;
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
        return .{ .allocator = allocator, .intervals = IntervalIterator.init(allocator, events, tl) };
    }

    pub fn deinit(self: Self) void {
        self.intervals.deinit();
    }

    pub fn scheduleTasks(self: *Self, tl: TaskList) !TaskList {
        var scheduled = TaskList{ .tasks = std.ArrayList(Task).init(self.allocator), .allocator = self.allocator };
        var unscheduled = TaskList{ .tasks = try tl.tasks.clone(), .allocator = tl.allocator };

        // TODO Split intervals based on start dates of tasks
        var interval = self.intervals.cur;

        std.mem.sort(Task, unscheduled.tasks.items, {}, cmpByDueDate);
        while (unscheduled.tasks.items.len > 0) {
            const best_opt = getBestTask(interval, &unscheduled);
            if (best_opt) |best| {
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
            } else break;
        }

        // TODO Merge tasks that start right after another (artifact of spliting
        // intervals at start dates)

        return scheduled;
    }
};
