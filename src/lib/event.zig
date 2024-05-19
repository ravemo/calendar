const c = @cImport({
    @cInclude("time.h");
});

pub const TimeOffset = struct {
    minutes: ?i32 = null,
    hours: ?i32 = null,
    days: ?i32 = null,
    weeks: ?i32 = null,
};

pub const DateIter = struct {
    const Self = @This();
    cur: Date,
    start: Date,
    end: Date,

    pub fn init(start: Date, end: Date) Self {
        return .{ .cur = start, .start = start, .end = end };
    }

    pub fn nextDay(self: *Self) ?Date {
        const last = self.cur;
        self.cur = self.cur.after(.{ .days = 1 });
        if (self.end.isBefore(self.cur)) return null;
        return last;
    }
};

pub const Date = struct {
    const Self = @This();
    tm: c.tm,

    pub fn now() Date {
        const t: c.time_t = c.time(null);
        var tm: c.tm = undefined;
        _ = c.localtime_r(&t, &tm);
        return .{ .tm = tm };
    }

    pub fn todayAt(hours: i32, minutes: i32) Date {
        const t: c.time_t = c.time(null);
        var tm: c.tm = undefined;
        _ = c.localtime_r(&t, &tm);
        tm.tm_hour = hours;
        tm.tm_min = minutes;
        _ = c.mktime(&tm);
        return .{ .tm = tm };
    }

    pub fn getWeekStart(self: Self) Date {
        var new_tm = self.tm;
        new_tm.tm_mday = new_tm.tm_mday - new_tm.tm_wday;
        _ = c.mktime(&new_tm);
        return .{ .tm = new_tm };
    }

    pub fn getWeekday(self: Self) i32 {
        return self.tm.tm_wday;
    }
    pub fn getHourF(self: Self) f32 {
        return @as(f32, @floatFromInt(self.tm.tm_hour)) +
            @as(f32, @floatFromInt(self.tm.tm_min)) / 60;
    }
    pub fn hoursSinceF(self: Self, other: Self) f32 {
        var tm0 = self.tm;
        var tm1 = other.tm;
        const t0 = c.mktime(&tm0);
        const t1 = c.mktime(&tm1);
        return @floatCast(c.difftime(t0, t1) / (60 * 60));
    }

    pub fn isBefore(self: Self, other: Self) bool {
        var tm0 = self.tm;
        var tm1 = other.tm;
        const t0 = c.mktime(&tm0);
        const t1 = c.mktime(&tm1);
        return c.difftime(t0, t1) < 0;
    }

    pub fn after(self: Self, offset: TimeOffset) Self {
        var new_tm = self.tm;
        if (offset.minutes) |m|
            new_tm.tm_min = new_tm.tm_min + m;
        if (offset.hours) |h|
            new_tm.tm_hour = new_tm.tm_hour + h;
        if (offset.days) |d|
            new_tm.tm_mday = new_tm.tm_mday + d;
        if (offset.weeks) |w|
            new_tm.tm_mday = new_tm.tm_mday + w * 7;
        _ = c.mktime(&new_tm);
        return .{ .tm = new_tm };
    }
    // TODO
};
pub const Time = struct {
    // TODO
};
pub const Pattern = struct {
    // TODO
};
pub const RepeatInfo = struct {
    period: Time,
    pattern: ?Pattern = null,
    start: Date,
    end: ?Date = null,
};
pub const Event = struct {
    const Self = @This();
    name: []u8,
    start_time: ?Date,
    end_time: ?Date, // TODO Create enum class for this. The end time can be
    // either nothing, a date or the start_time offset by some duration.
    repeat: ?RepeatInfo,

    pub fn init(allocator: anytype, name: []const u8, start_time: ?Date, end_time: ?Date, repeat: ?RepeatInfo) !Self {
        return .{
            .name = try allocator.dupe(u8, name),
            .start_time = start_time,
            .end_time = end_time,
            .repeat = repeat,
        };
    }
};

pub const one_day: Time = .{};
