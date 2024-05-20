const c = @cImport({
    @cInclude("time.h");
});

pub const Time = struct {
    minutes: ?i32 = null,
    hours: ?i32 = null,
    days: ?i32 = null,
    weeks: ?i32 = null,

    pub fn getHoursF(self: Time) f32 {
        var hours: f32 = 0;
        if (self.weeks) |w|
            hours += @floatFromInt(w * 7 * 24);
        if (self.days) |d|
            hours += @floatFromInt(d * 24);
        if (self.hours) |h|
            hours += @floatFromInt(h);
        if (self.minutes) |m|
            hours += @as(f32, @floatFromInt(m)) / 60;
        return hours;
    }
};

pub const DateIter = struct {
    const Self = @This();
    cur: Date,
    start: Date,
    end: Date,

    pub fn init(start: Date, end: Date) Self {
        return .{ .cur = start, .start = start, .end = end };
    }

    pub fn next(self: *Self, step: Time) ?Date {
        const last = self.cur;
        self.cur = self.cur.after(step);
        if (self.end.isBefore(self.cur)) return null;
        return last;
    }
};

pub const Weekday = enum(i32) {
    Sunday = 0,
    Monday,
    Tuesday,
    Wednesday,
    Thursday,
    Friday,
    Saturday,
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

    pub fn last(weekday: Weekday) Date {
        const t: c.time_t = c.time(null);
        var tm: c.tm = undefined;
        _ = c.localtime_r(&t, &tm);
        var new_tm = tm;
        if (tm.tm_wday >= @intFromEnum(weekday)) {
            new_tm.tm_mday -= tm.tm_wday - @intFromEnum(weekday);
        } else {
            new_tm.tm_mday -= tm.tm_wday - @intFromEnum(weekday) + 7;
        }
        _ = c.mktime(&new_tm);
        return .{ .tm = new_tm };
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

    pub fn atDate(day: i32, month: i32, year: i32) Date {
        const t: c.time_t = c.time(null);
        var tm: c.tm = undefined;
        _ = c.localtime_r(&t, &tm);
        tm.tm_mday = day;
        tm.tm_mon = month - 1;
        tm.tm_year = year - 1900;
        tm.tm_hour = 0;
        tm.tm_min = 0;
        tm.tm_sec = 0;
        _ = c.mktime(&tm);
        return .{ .tm = tm };
    }

    pub fn getWeekStart(self: Self) Date {
        var new_tm = self.tm;
        new_tm.tm_mday = new_tm.tm_mday - new_tm.tm_wday;
        new_tm.tm_hour = 0;
        new_tm.tm_min = 0;
        new_tm.tm_sec = 0;
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

    pub fn after(self: Self, offset: Time) Self {
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

    pub fn setDate(self: *Self, date: Date) void {
        self.tm.tm_mday = date.tm.tm_mday;
        self.tm.tm_mon = date.tm.tm_mon;
        self.tm.tm_year = date.tm.tm_year;
    }

    pub fn setWeekday(self: *Self, wday: Weekday) void {
        self.tm.tm_wday = @intFromEnum(wday);
    }
    // TODO
};
pub const Deadline = union(enum) {
    date: Date,
    time: Time,
};

pub const Pattern = struct {
    sun: bool = false,
    mon: bool = false,
    tue: bool = false,
    wed: bool = false,
    thu: bool = false,
    fri: bool = false,
    sat: bool = false,
};
pub const Period = union(enum) {
    time: Time,
    pattern: Pattern,
};
pub const RepeatInfo = struct {
    period: Period,
    start: Date,
    end: ?Date = null,
};
pub const Event = struct {
    const Self = @This();
    name: []const u8,
    start: Date,
    end: Deadline,
    // either nothing, a date or the start_time offset by some duration.
    repeat: ?RepeatInfo,

    pub fn init(allocator: anytype, name: []const u8, start: Date, end: Deadline, repeat: ?RepeatInfo) !Self {
        _ = allocator;
        return .{
            .name = name,
            .start = start,
            .end = end,
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
        return switch (self.end) {
            .time => |t| self.start.after(t),
            .date => |e| e,
        };
    }
};
