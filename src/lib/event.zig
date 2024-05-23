const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
    @cInclude("pcre.h");
});

const print = std.debug.print;

pub const Time = struct {
    const Self = @This();
    seconds: ?i32 = null,
    minutes: ?i32 = null,
    hours: ?i32 = null,
    days: ?i32 = null,
    weeks: ?i32 = null,

    pub fn toString(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{?} weeks, {?} days, {?} hours, {?} minutes, {?} seconds", .{
            @as(i32, @intFromBool(self.weeks)),
            @as(i32, @intFromBool(self.days)),
            @as(i32, @intFromBool(self.hours)),
            @as(i32, @intFromBool(self.minutes)),
            @as(i32, @intFromBool(self.seconds)),
        });
    }

    pub fn getHoursF(self: Self) f32 {
        var hours: f32 = 0;
        if (self.weeks) |w|
            hours += @floatFromInt(w * 7 * 24);
        if (self.days) |d|
            hours += @floatFromInt(d * 24);
        if (self.hours) |h|
            hours += @floatFromInt(h);
        if (self.minutes) |m|
            hours += @as(f32, @floatFromInt(m)) / 60;
        if (self.seconds) |s|
            hours += @as(f32, @floatFromInt(s)) / (60 * 60);
        return hours;
    }

    pub fn getSeconds(self: Self) i32 {
        var seconds: i32 = 0;
        if (self.weeks) |w|
            seconds += w * 60 * 60 * 24 * 7;
        if (self.days) |d|
            seconds += d * 60 * 60 * 24;
        if (self.hours) |h|
            seconds += h * 60 * 60;
        if (self.minutes) |m|
            seconds += m * 60;
        if (self.seconds) |s|
            seconds += s;
        return seconds;
    }

    pub fn toReadable(self: Self) Self {
        var t = Time{ .seconds = self.getSeconds() };
        if (@abs(t.seconds.?) >= 7 * 24 * 60 * 60) {
            t.weeks = @divFloor(t.seconds.?, 7 * 24 * 60 * 60);
            t.seconds.? -= t.weeks.? * 7 * 24 * 60 * 60;
        }
        if (@abs(t.seconds.?) >= 24 * 60 * 60) {
            t.days = @divFloor(t.seconds.?, 24 * 60 * 60);
            t.seconds.? -= t.days.? * 24 * 60 * 60;
        }
        if (@abs(t.seconds.?) >= 60 * 60) {
            t.hours = @divFloor(t.seconds.?, 60 * 60);
            t.seconds.? -= t.hours.? * 60 * 60;
        }
        if (@abs(t.seconds.?) >= 60) {
            t.minutes = @divFloor(t.seconds.?, 60);
            t.seconds.? -= t.minutes.? * 60;
        }
        return t;
    }

    pub fn add(self: Self, other: Self) Self {
        const self_seconds = self.getSeconds();
        const other_seconds = other.getSeconds();
        return (Time{ .seconds = self_seconds + other_seconds }).toReadable();
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

const DatePart = enum {
    Year,
    Month,
    Day,
    Hours,
    Minutes,
};

pub const Date = struct {
    const Self = @This();
    tm: c.tm,

    pub fn default() Date {
        const t: c.time_t = c.time(null);
        var tm: c.tm = undefined;
        _ = c.localtime_r(&t, &tm);
        tm.tm_hour = 0;
        tm.tm_min = 0;
        tm.tm_sec = 0;
        return .{ .tm = tm };
    }

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

    pub fn fromString(str: [:0]const u8) !Date {
        const pattern_ymd = "^(?:(?'year'\\d{4})(?:-(?'month'\\d{2})(?:-(?'day'\\d{2}))?)?)?(?: ?(?'hours'\\d{2}):?(?'minutes'\\d{2}))?$";
        const pattern_md = "^(?:(\\d{2})-(\\d{2}))(?: (\\d{2}):?(\\d{2}))?$";
        _ = pattern_md; // TODO

        var err: [*c]u8 = undefined;
        var erroffset: c_int = undefined;
        var ovector: [30]c_int = undefined;

        const re = c.pcre_compile(pattern_ymd, 0, (&err), &erroffset, null).?;
        defer c.pcre_free.?(re);

        const rc = c.pcre_exec(re, null, str, @intCast(str.len), 0, 0, &ovector, 30);

        if (rc == c.PCRE_ERROR_NOMATCH) {
            return error.InvalidFormat;
        } else if (rc < -1) {
            print("error {d} from regex\n", .{rc});
            return error.RegexError;
        } else {
            const parts = [_]struct { str: [:0]const u8, val: DatePart }{
                .{ .str = "year", .val = .Year },
                .{ .str = "month", .val = .Month },
                .{ .str = "day", .val = .Day },
                .{ .str = "hours", .val = .Hours },
                .{ .str = "minutes", .val = .Minutes },
            };
            var date = Date.default();
            // loop through matches and return them
            for (parts) |part| {
                const name = part.str;
                const v = part.val;
                var substring: [*c]const u8 = null;
                _ = c.pcre_get_named_substring(re, str, @ptrCast(&ovector), rc, name, &substring);
                if (substring != null) {
                    print("{s}: {s}\n", .{ name, substring });
                    switch (v) {
                        .Year => date.setYear(try std.fmt.parseInt(i32, std.mem.span(substring), 10)),
                        .Month => date.setMonth(try std.fmt.parseInt(i32, std.mem.span(substring), 10)),
                        .Day => date.setDay(try std.fmt.parseInt(i32, std.mem.span(substring), 10)),
                        .Hours => date.setHours(try std.fmt.parseInt(i32, std.mem.span(substring), 10)),
                        .Minutes => date.setMinutes(try std.fmt.parseInt(i32, std.mem.span(substring), 10)),
                    }
                    c.pcre_free_substring(substring);
                }
            }
            return date;
        }
    }

    pub fn toString(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{:0>4}-{:0>2}-{:0>2} {:0>2}:{:0>2}", .{
            @as(u32, @intCast(self.tm.tm_year + 1900)),
            @as(u32, @intCast(self.tm.tm_mon + 1)),
            @as(u32, @intCast(self.tm.tm_mday + 1)),
            @as(u32, @intCast(self.tm.tm_hour)),
            @as(u32, @intCast(self.tm.tm_min)),
        });
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
    pub fn getDayStart(self: Self) Date {
        var new_tm = self.tm;
        new_tm.tm_hour = 0;
        new_tm.tm_min = 0;
        new_tm.tm_sec = 0;
        _ = c.mktime(&new_tm);
        return .{ .tm = new_tm };
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
    pub fn secondsSince(self: Self, other: Self) i32 {
        var tm0 = self.tm;
        var tm1 = other.tm;
        const t0 = c.mktime(&tm0);
        const t1 = c.mktime(&tm1);
        return @intFromFloat(c.difftime(t0, t1));
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
        if (offset.seconds) |s|
            new_tm.tm_min = new_tm.tm_sec + s;
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

    pub fn setYear(self: *Self, year: i32) void {
        self.tm.tm_year = year - 1900;
    }
    pub fn setMonth(self: *Self, month: i32) void {
        self.tm.tm_mon = month;
    }
    pub fn setDay(self: *Self, mday: i32) void {
        self.tm.tm_mday = mday;
    }
    pub fn setWeekday(self: *Self, wday: Weekday) void {
        self.tm.tm_wday = @intFromEnum(wday);
    }
    pub fn setHours(self: *Self, hour: i32) void {
        self.tm.tm_hour = hour;
    }
    pub fn setMinutes(self: *Self, minute: i32) void {
        self.tm.tm_min = minute;
    }

    // TODO
};
pub const Deadline = union(enum) {
    date: Date,
    time: Time,

    pub fn toString(self: Deadline, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            inline else => |x| x.toString(allocator),
        };
    }
};

pub const Pattern = struct {
    sun: bool = false,
    mon: bool = false,
    tue: bool = false,
    wed: bool = false,
    thu: bool = false,
    fri: bool = false,
    sat: bool = false,

    pub fn toString(self: Pattern, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{}{}{}{}{}{}{}", .{
            @as(u1, @intFromBool(self.sun)),
            @as(u1, @intFromBool(self.mon)),
            @as(u1, @intFromBool(self.tue)),
            @as(u1, @intFromBool(self.wed)),
            @as(u1, @intFromBool(self.thu)),
            @as(u1, @intFromBool(self.fri)),
            @as(u1, @intFromBool(self.sat)),
        });
    }
};
pub const Period = union(enum) {
    time: Time,
    pattern: Pattern,
    pub fn toString(self: Deadline, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            inline else => |x| x.toString(allocator),
        };
    }
};
pub const RepeatInfo = struct {
    period: Period,
    start: Date,
    end: ?Date = null,
    pub fn toString(self: Deadline, allocator: std.mem.Allocator) ![]const u8 {
        const period_str = self.period.toString(allocator);
        const start_str = self.start.toString(allocator);
        const end_str = if (self.end) |e| e.toString(allocator) else null;
        defer allocator.free(period_str);
        defer allocator.free(start_str);
        defer allocator.free(end_str);
        return std.fmt.allocPrint(allocator, "{s}\n{s}\n{?s}", .{
            period_str,
            start_str,
            end_str,
        });
    }
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
