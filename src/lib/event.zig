const std = @import("std");
const datetime = @import("datetime.zig");
const Time = datetime.Time;
const Date = datetime.Date;
const RepeatInfo = datetime.RepeatInfo;
const Weekday = datetime.Weekday;
const Database = @import("database.zig").Database;

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

pub const EventList = struct {
    const Self = @This();
    events: std.ArrayList(Event),
    event_names: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, db: Database) !Self {
        const events = try loadEvents(allocator, db);
        var event_names = std.ArrayList([]const u8).init(allocator);

        for (events.items) |*t| {
            try event_names.append(t.name); // It is owned here now
        }
        std.debug.print("Loaded {} events.\n", .{events.items.len});
        return .{
            .events = events,
            .event_names = event_names,
            .allocator = allocator,
        };
    }

    pub fn initEmpty(allocator: std.mem.Allocator) Self {
        return .{
            .events = std.ArrayList(Event).init(allocator),
            .event_names = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: Self) void {
        for (self.event_names.items) |i|
            self.allocator.free(i);
        self.event_names.deinit();
        self.events.deinit();
    }

    pub fn clone(self: Self) !Self {
        const new_events = try self.events.clone();
        const new_names = try self.event_names.clone();
        for (new_names.items) |*i|
            i.* = try self.allocator.dupe(u8, i.*);
        return .{
            .events = new_events,
            .event_names = new_names,
            .allocator = self.allocator,
        };
    }
};

pub fn cmpByStartDate(_: void, a: Event, b: Event) bool {
    return a.start.isBefore(b.start);
}

pub fn appendSorted(events: *std.ArrayList(Event), to_add: Event) !void {
    for (events.items, 0..) |e, i| {
        if (cmpByStartDate({}, to_add, e)) {
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
    i: usize = 0,

    pub fn init(allocator: std.mem.Allocator, events: []Event, start: Date) !Self {
        var new_events = std.ArrayList(Event).init(allocator);
        try new_events.appendSlice(events);
        std.mem.sort(Event, new_events.items, {}, cmpByStartDate);
        return .{ .events = new_events, .time = start };
    }

    pub fn deinit(self: Self) void {
        self.events.deinit();
    }

    pub fn reset(self: *Self, start: Date) void {
        self.time = start;
        self.i = 0;
    }

    pub fn next(self: *Self, end: Date) ?Event {
        if (self.events.items.len == 0) return null;
        var cur_event = self.events.items[self.i];
        while (cur_event.getEnd().isBefore(self.time)) {
            self.time = cur_event.getEnd();
            self.i += 1;
            cur_event = self.events.items[self.i];
        }
        self.time = cur_event.getEnd();
        self.i += 1;

        if (end.isBeforeEq(cur_event.start)) return null;

        return cur_event;
    }
};

fn load_event_cb(events_ptr: ?*anyopaque, argc: c_int, argv: [*c][*c]u8, cols: [*c][*c]u8) callconv(.C) c_int {
    const events: *std.ArrayList(Event) = @alignCast(@ptrCast(events_ptr));
    const allocator = events.allocator;
    var id: i32 = undefined;
    var name: []const u8 = undefined;
    var start: Date = undefined;
    var end: Date = undefined;
    var has_repeat = false;
    var r_end: ?Date = null;
    var repeat: ?datetime.RepeatInfo = null;
    repeat = repeat;

    for (0..@intCast(argc)) |i| {
        const col = std.mem.span(cols[i]);
        const val = if (argv[i]) |v| std.mem.span(v) else null;
        if (std.mem.eql(u8, col, "E_Id")) {
            id = std.fmt.parseInt(i32, val.?, 10) catch return -1;
        } else if (std.mem.eql(u8, col, "Name")) {
            name = allocator.dupe(u8, val.?) catch return -1;
        } else if (std.mem.eql(u8, col, "Start")) {
            start = Date.fromString(val.?) catch return -1;
        } else if (std.mem.eql(u8, col, "E_End")) {
            end = datetime.Date.fromString(val.?) catch return -1;
        } else if (std.mem.eql(u8, col, "Repeat")) {
            if (val != null) has_repeat = true;
        } else if (std.mem.eql(u8, col, "R_End")) {
            if (val) |v|
                r_end = Date.fromString(v) catch return -1;
        } else if (std.mem.eql(u8, col, "Period")) {
            if (val) |v|
                repeat = .{ .period = datetime.Period.fromString(v) catch return -1 };
        }
    }

    if (has_repeat) {
        std.debug.assert(repeat != null);
        if (repeat.?.period.time.getSeconds() < 60) {
            std.debug.print("{}: {s}\n{any}\n", .{ id, name, repeat.? });
            std.debug.assert(false);
        }
    }
    if (repeat) |*r| r.end = r_end;

    if (end.isBefore(start)) {
        std.debug.print("Warning: Ignoring event ID {} with negative duration\n", .{id});
        return 0;
    }

    events.append(Event.init(allocator, id, name, start, end.timeSince(start), repeat) catch return -1) catch return -1;
    return 0;
}

pub fn loadEvents(allocator: std.mem.Allocator, db: Database) !std.ArrayList(Event) {
    var events = std.ArrayList(Event).init(allocator);
    const query = try std.fmt.allocPrintZ(allocator,
        \\ SELECT Events.Id as E_Id, Repeats.Id as R_Id,
        \\        Events.End as E_End, Repeats.End as R_End, *
        \\ FROM Events LEFT JOIN Repeats ON Events.Repeat = Repeats.Id;
    , .{});
    defer allocator.free(query);

    try db.executeCB(query, load_event_cb, &events);
    std.debug.print("Loaded {} events.\n", .{events.items.len});
    return events;
}
