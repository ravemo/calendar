const std = @import("std");
const datetime = @import("datetime.zig");
const Time = datetime.Time;
const Date = datetime.Date;
const RepeatInfo = datetime.RepeatInfo;
const Weekday = datetime.Weekday;

const print = std.debug.print;

pub const Event = struct {
    const Self = @This();
    id: i32,
    name: []const u8,
    start: Date,
    duration: Time,
    // either nothing, a date or the start_time offset by some duration.
    repeat: ?RepeatInfo,

    pub fn init(allocator: anytype, id: i32, name: []const u8, start: Date, duration: Time, repeat: ?RepeatInfo) !Self {
        _ = allocator;
        return .{
            .id = id,
            .name = name,
            .start = start,
            .duration = duration,
            .repeat = repeat,
        };
    }

    pub fn atDay(self: Self, day: Date) Self {
        var new = self;
        new.start.setDate(day);
        return new;
    }
    pub fn atWeekday(self: Self, wday: Weekday) Self {
        var new = self;
        new.start.setWeekday(wday);
        return new;
    }

    pub fn getEnd(self: Self) Date {
        return self.start.after(self.duration);
    }
};

pub fn cmpByStartDate(_: void, a: Event, b: Event) bool {
    return a.start.isBefore(b.start);
}

pub fn appendSorted(events: *std.ArrayList(Event), to_add: Event) !void {
    for (events.items, 0..) |e, i| {
        if (cmpByStartDate({}, to_add, e)) {
            std.debug.print("Inserting at {}\n", .{i});
            try events.insert(i, to_add);
            return;
        }
    }
    try events.append(to_add);
}

pub const EventIterator = struct {
    const Self = @This();
    events: std.ArrayList(Event),
    time: Date,

    pub fn init(events: std.ArrayList(Event), start: Date) !Self {
        const new_events = try events.clone();
        std.mem.sort(Event, new_events.items, {}, cmpByStartDate);
        return .{ .events = new_events, .time = start };
    }

    pub fn finishEvent(self: *Self, event: Event) void {
        if (event.repeat) |repeat| {
            // TODO Handle repeat_start and repeat_end
            var new_event: Event = event;
            new_event.start = new_event.start.after(repeat.period.time);
            _ = self.events.orderedRemove(0);
            appendSorted(&self.events, new_event) catch unreachable;
        } else {
            _ = self.events.orderedRemove(0);
        }
    }
    pub fn next(self: *Self, end: Date) ?Event {
        var cur_event = self.events.items[0];
        while (cur_event.getEnd().isBefore(self.time)) {
            self.finishEvent(cur_event);
            cur_event = self.events.items[0];
        }
        self.finishEvent(cur_event);

        if (end.isBeforeEq(cur_event.start)) return null;

        return cur_event;
    }
};
