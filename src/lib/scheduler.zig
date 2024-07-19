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
const cmpByDueDate = task_lib.cmpByDueDate;

const print = std.debug.print;

pub fn trace(msg: []const u8, a: anytype) @TypeOf(a) {
    std.debug.print("{s}\n", .{msg});
    return a;
}

pub const Interval = struct {
    // A Interval is a semi-open interval from [start, end)
    const Self = @This();
    start: Date,
    end: ?Date,
    free: bool = true,

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
    return .{ .start = e.start, .end = e.getEnd(), .free = false };
}

const IntervalIterator = struct {
    const Self = @This();
    start: Date,
    splits: std.ArrayList(i32),
    free: std.ArrayList(bool), // free[i] is true when the interval from start
    // to splits[i] is free for tasks

    fn init(allocator: std.mem.Allocator, event_list: []Event, tasks: TaskList, start: Date) !Self {
        // TODO: Do most of this function in a lazy manner, i.e. when iterating over intervals
        const limit_seconds = (Time{ .weeks = 4 }).getSeconds(); // Seconds until limit
        const limit = start.after(.{ .seconds = limit_seconds });
        var events = try EventIterator.init(allocator, event_list, start);
        defer events.deinit();
        var self = Self{
            .start = start,
            .splits = std.ArrayList(i32).init(allocator),
            .free = std.ArrayList(bool).init(allocator),
        };

        try self.splits.append(0);
        try self.free.append(false);

        var split_count: usize = 0;
        for (tasks.tasks.items) |t| {
            if (t.repeat) |repeat| {
                const repeat_seconds = repeat.getSeconds();
                const task_start = t.start.?.timeSince(self.start).getSeconds();
                if (task_start < limit_seconds)
                    split_count += @intCast(@divFloor(limit_seconds - task_start + repeat_seconds, repeat_seconds));
                if (t.due != null) {
                    const task_due = t.start.?.timeSince(self.start).getSeconds();
                    if (task_due < limit_seconds)
                        split_count += @intCast(@divFloor(limit_seconds - task_due + repeat_seconds, repeat_seconds));
                }
            } else {
                if (t.start) |_| split_count += 1;
                if (t.due) |_| split_count += 1;
            }
        }
        try self.splits.ensureTotalCapacity(1 + split_count);
        try self.free.ensureTotalCapacity(1 + split_count);
        std.debug.assert(std.sort.isSorted(i32, self.splits.items, {}, std.sort.asc(i32)));

        // Split intervals at tasks starts
        const sorted_tasks = try tasks.tasks.clone();
        defer sorted_tasks.deinit();
        std.mem.sort(Task, sorted_tasks.items, {}, cmpByStartDate);
        for (sorted_tasks.items) |t| {
            if (t.repeat) |_| {
                const repeat = t.repeat.?.getSeconds();
                var task_start = t.start.?.timeSince(self.start).getSeconds();
                while (task_start < limit_seconds) {
                    self.split(task_start);
                    task_start += repeat;
                }
                if (t.due != null) {
                    var task_due = t.start.?.timeSince(self.start).getSeconds();
                    while (task_due < limit_seconds) {
                        self.split(task_due);
                        task_due += repeat;
                    }
                }
            } else {
                if (t.start) |s| self.split(s.timeSince(self.start).getSeconds());
                if (t.due) |d| self.split(d.timeSince(self.start).getSeconds());
            }
        }
        std.debug.assert(std.sort.isSorted(i32, self.splits.items, {}, std.sort.asc(i32)));
        for (0..self.splits.items.len - 1) |i|
            std.debug.assert(self.splits.items[i] != self.splits.items[i + 1]);

        // Remove event intervals from interval list
        while (events.next(limit)) |e| {
            if (limit.isBefore(getInterval(e).start)) break;
            try self.remove(getInterval(e));
        }
        std.debug.assert(std.sort.isSorted(i32, self.splits.items, {}, std.sort.asc(i32)));
        for (0..self.splits.items.len - 1) |i|
            std.debug.assert(self.splits.items[i] != self.splits.items[i + 1]);

        return self;
    }

    fn deinit(self: Self) void {
        self.splits.deinit();
        self.free.deinit();
    }

    pub fn getFirstInterval(self: Self) Interval {
        const start = self.splits.items[0];
        const end = self.splits.items[1];
        return .{
            .start = self.start.after(.{ .seconds = start }),
            .end = self.start.after(.{ .seconds = end }),
            .free = self.free.items[1],
        };
    }

    fn next(self: *Self, step: Time) !?Interval {
        std.debug.assert(std.sort.isSorted(i32, self.splits.items, {}, std.sort.asc(i32)));
        const first = self.getFirstInterval();
        if (step.getSeconds() > 0) {
            self.remove(Interval{
                .start = first.start,
                .end = first.start.after(step),
            }) catch unreachable;
            _ = self.splits.orderedRemove(0);
            _ = self.free.orderedRemove(0);
        }
        const cur = self.getFirstInterval();

        // Split at day transition
        const day_end = cur.start.after(.{ .days = 1 }).getDayStart();
        if (day_end.isBefore(cur.end)) {
            const day_end_seconds = day_end.timeSince(self.start).getSeconds();
            const free = self.free.items[0];
            try self.splits.insert(1, day_end_seconds);
            try self.free.insert(1, free);
            std.debug.assert(std.sort.isSorted(i32, self.splits.items, {}, std.sort.asc(i32)));
            return self.getFirstInterval();
        }

        return cur;
    }

    fn remove(self: *Self, toRemove: Interval) !void {
        const start = toRemove.start.timeSince(self.start).getSeconds();
        const end = toRemove.end.?.timeSince(self.start).getSeconds();
        std.debug.assert(start < end);
        if (end < self.splits.items[0]) return;
        if (start > self.splits.getLast()) {
            self.splits.items[self.splits.items.len - 1] = start;
            try self.splits.append(end);
            try self.free.append(false);
            for (0..self.splits.items.len - 1) |i|
                std.debug.assert(self.splits.items[i] != self.splits.items[i + 1]);
            return;
        }
        var start_i_opt: ?usize = null; // First i that should be removed (inside toRemove interval)
        var last_i: usize = 0; // Last i to be removed
        for (self.splits.items, 0..) |s, i| {
            if (start_i_opt == null and s >= start) start_i_opt = i;
            last_i = i;
            if (s > end) {
                std.debug.assert(start_i_opt != null);
                break;
            }
        } else {
            std.debug.assert(false);
        }
        const start_i = start_i_opt.?;

        const last_free = self.free.items[last_i];
        for (0..self.splits.items.len - 1) |i|
            std.debug.assert(self.splits.items[i] != self.splits.items[i + 1]);

        try self.splits.replaceRange(start_i, last_i - start_i, &[2]i32{ start, end });
        try self.free.replaceRange(start_i, last_i - start_i, &[2]bool{ last_free, false });

        for (0..self.splits.items.len - 1) |i|
            std.debug.assert(self.splits.items[i] != self.splits.items[i + 1]);
    }

    fn split(self: *Self, s: i32) void {
        if (self.splits.getLast() < s) {
            self.splits.appendAssumeCapacity(s);
            self.free.appendAssumeCapacity(true);
            return;
        }
        if (s < self.splits.items[0]) return;
        var min_i: usize = 0;
        var max_i: usize = self.splits.items.len - 1;
        var i: usize = @divFloor(min_i + max_i, 2);
        while (true) {
            const cur_s = self.splits.items[i];
            if (cur_s > s) {
                max_i = i;
            } else if (cur_s < s) {
                min_i = i;
            }
            i = @divFloor(min_i + max_i, 2);
            if (self.splits.items[min_i] == s or
                self.splits.items[max_i] == s or
                self.splits.items[i] == s) break;
            if (max_i <= min_i + 1) {
                std.debug.assert(self.splits.items[i] < s);
                std.debug.assert(i == self.splits.items.len - 1 or s < self.splits.items[i + 1]);
                self.splits.insertAssumeCapacity(i + 1, s);
                self.free.insertAssumeCapacity(i + 1, true);
                return;
            }
        }
    }
};

pub fn cmpByStartDate(_: void, a: Task, b: Task) bool {
    if (a.start) |as| {
        return as.isBefore(b.start);
    } else if (b.start) |_| {
        return false;
    } else return false;
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

    pub fn reset(self: *Self, event_list: []Event, tasks: TaskList, start: Date) !void {
        self.start = start;
        self.intervals.deinit();
        self.intervals = try IntervalIterator.init(self.allocator, event_list, tasks, self.start);
    }

    pub fn scheduleTasks(self: *Self, tl: *TaskList, limit: Date) !TaskList {
        var scheduled = TaskList.initEmpty(self.allocator);

        var interval = self.intervals.getFirstInterval();

        tl.reset();
        while (interval.start.isBefore(limit)) {
            if (!interval.free) {
                interval = try self.intervals.next(interval.end.?.timeSince(interval.start)) orelse break;
                continue;
            }
            const pair = try tl.next(interval) orelse break;

            try scheduled.tasks.append(pair.task);
            try scheduled.checkOverlap();
            if (pair.interval) |new_interval| {
                self.intervals.splits.items[0] = new_interval.start.timeSince(self.intervals.start).getSeconds();
                interval = new_interval;
            } else {
                interval = try self.intervals.next(pair.task.time) orelse break;
            }
        }

        // Merge tasks
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

    const tl = TaskList.initEmpty(alloc);
    defer tl.deinit();

    const events = [0]Event{};

    const intervals = try IntervalIterator.init(alloc, &events, tl, now);
    defer intervals.deinit();
    try std.testing.expectEqual(1, intervals.splits.items.len);
    try std.testing.expectEqual(0, intervals.splits.items[0]);
}
