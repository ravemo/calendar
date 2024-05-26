const std = @import("std");
const calendar = @import("event.zig");
const Time = calendar.Time;
const Date = calendar.Date;
const Event = calendar.Event;

pub const Task = struct {
    const Self = @This();
    id: i32,
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

pub fn conflicts(task: Task, tasks: []Task) bool {
    if (task.scheduled_start) |ts| {
        for (tasks) |t| {
            if (t.scheduled_start) |s| {
                if (s.isBefore(ts) and task.getEnd().isBefore(t.getEnd()))
                    return true;
            }
        }
    }
    return false;
}
pub fn getNextFree(now: Date, tasks: []Task) Date {
    var free = now;
    var changed = true;
    while (changed) {
        changed = false;
        for (tasks) |t| {
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

pub fn cmpByDueDate(context: void, a: *Task, b: *Task) bool {
    _ = context;
    if (b.due) |bd| {
        if (a.due) |ad| {
            return ad.isBefore(bd);
        } else unreachable;
    } else unreachable;
}
pub fn cmpByStartDate(context: void, a: *Task, b: *Task) bool {
    _ = context;
    if (b.start) |bd| {
        if (a.start) |ad| {
            return ad.isBefore(bd);
        } else unreachable;
    } else unreachable;
}

pub fn scheduleTasks(allocator: std.mem.Allocator, tasks: []Task, events: []const Event) !void {
    _ = events; // TODO make events block tasks
    // First pass: schedule everything with a due date
    // TODO: Sort tasks by due date
    var due_tasks = std.ArrayList(*Task).init(allocator);
    for (tasks) |*t| {
        if (t.due == null) continue;
        try due_tasks.append(t);
    }
    std.mem.sort(*Task, due_tasks.items, {}, cmpByDueDate);

    var start_tasks = std.ArrayList(*Task).init(allocator);
    for (tasks) |*t| {
        if (t.start == null) continue;
        try start_tasks.append(t);
    }
    std.mem.sort(*Task, start_tasks.items, {}, cmpByStartDate);

    var cur_start = Date.now();
    var has_changed = true;
    while (has_changed) {
        has_changed = false;
        for (tasks) |*t| {
            if (t.scheduled_start != null) continue;
            if (t.start != null and cur_start.isBefore(t.start.?)) continue;

            t.scheduled_start = cur_start;
            cur_start = cur_start.after(t.time);
            has_changed = true;
        }

        if (has_changed) continue;
        for (start_tasks.items) |t| {
            if (t.scheduled_start != null) continue;
            cur_start = t.start.?;
            t.scheduled_start = cur_start;
            cur_start = cur_start.after(t.time);
            has_changed = true;
        }
    }

    // Sanity check
    for (due_tasks.items) |t| {
        if (t.scheduled_start == null) return error.IncompleteScheduling;
    }

    if (true) return; // TODO Implement second pass properly

    // Second pass: schedule everything else
    has_changed = true;
    while (has_changed) {
        has_changed = false;
        for (tasks) |*t| {
            if (t.scheduled_start != null) continue;
            if (t.start != null and cur_start.isBefore(t.start.?)) continue;

            t.scheduled_start = cur_start;
            cur_start = cur_start.after(t.time);
            has_changed = true;
        }
    }
}
