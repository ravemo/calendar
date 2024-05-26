const std = @import("std");
const calendar = @import("event.zig");
const Time = calendar.Time;
const Date = calendar.Date;
const Event = calendar.Event;
const task_lib = @import("task.zig");
const Task = task_lib.Task;
const TaskList = task_lib.TaskList;

const Interval = struct {
    start: Date,
    end: ?Date,
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
    intervals: std.ArrayList(Interval),

    pub fn init(allocator: std.mem.Allocator, events: []Event) !Self {
        _ = events; // TODO Load intervals according to the events
        var intervals = std.ArrayList(Interval).init(allocator);
        try intervals.append(.{ .start = Date.now(), .end = null });
        return .{ .allocator = allocator, .intervals = intervals };
    }

    pub fn deinit(self: Self) void {
        self.intervals.deinit();
    }

    pub fn scheduleTasks(self: *Self, tl: TaskList) !TaskList {
        var scheduled = std.ArrayList(Task).init(self.allocator);
        var unscheduled = .{ .tasks = try tl.tasks.clone(), .allocator = tl.allocator };

        // TODO Split intervals based on start dates of tasks
        var interval = self.intervals.items[0];

        std.mem.sort(Task, unscheduled.tasks.items, {}, cmpByDueDate);
        while (unscheduled.tasks.items.len > 0) {
            const best_opt = getBestTask(interval, &unscheduled);
            if (best_opt) |best| {
                best.scheduled_start = interval.start;
                interval.start = interval.start.after(best.time);
                if (interval.end != null and interval.end.?.isBeforeEq(interval.start)) {
                    _ = self.intervals.orderedRemove(0);
                    interval = self.intervals.items[0];
                }

                try scheduled.append(best.*);

                var found = false;
                for (unscheduled.tasks.items, 0..) |*t, i| {
                    if (t == best) {
                        found = true;
                        _ = unscheduled.tasks.swapRemove(i);
                        break;
                    }
                }
                if (!found) unreachable;
            } else break;
        }

        // TODO Merge tasks that start right after another (artifact of spliting
        // intervals at start dates)

        return .{ .tasks = scheduled, .allocator = self.allocator };
    }
};
