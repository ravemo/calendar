const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
    @cInclude("pcre.h");
});
const regex = @import("regex.zig");
const Regex = regex.Regex;

const print = std.debug.print;

pub const StringError = error{
    InvalidFormat,
    RegexError,
    NoMatches,
};
pub const Time = struct {
    const Self = @This();
    seconds: ?i32 = null,
    minutes: ?i32 = null,
    hours: ?i32 = null,
    days: ?i32 = null,
    weeks: ?i32 = null,

    pub fn initS(seconds: i32) Self {
        const t = Time{ .seconds = seconds };
        return t.toReadable();
    }
    pub fn initH(hours: i32) Self {
        return Time.initS(hours * 60 * 60).toReadable();
    }
    pub fn initHF(hoursF: f32) Self {
        return Time.initS(@intFromFloat(@round(hoursF * 60 * 60))).toReadable();
    }

    pub fn fromString(str: [:0]const u8) StringError!Self {
        const pattern = "(?'weeks'\\d) weeks, (?'days'\\d) days, (?'hours'\\d) hours, (?'minutes'\\d) minutes, (?'seconds'\\d) seconds";

        const re = try Regex.compile(pattern);
        defer re.deinit();

        var cap = try re.captures(str);

        const TimePart = enum {
            Weeks,
            Days,
            Hours,
            Minutes,
            Seconds,
        };
        const parts = [_]struct { str: [:0]const u8, val: TimePart }{
            .{ .str = "weeks", .val = .Weeks },
            .{ .str = "days", .val = .Days },
            .{ .str = "hours", .val = .Hours },
            .{ .str = "minutes", .val = .Minutes },
            .{ .str = "seconds", .val = .Seconds },
        };
        var time = Time{};
        for (parts) |part| {
            const name = part.str;
            const v = part.val;
            const substring = try cap.getNamedMatch(name);
            defer cap.deinitMatch(substring);
            switch (v) {
                .Weeks => time.weeks = if (substring) |substr| std.fmt.parseInt(i32, substr, 10) catch return StringError.InvalidFormat else null,
                .Days => time.days = if (substring) |substr| std.fmt.parseInt(i32, substr, 10) catch return StringError.InvalidFormat else null,
                .Hours => time.hours = if (substring) |substr| std.fmt.parseInt(i32, substr, 10) catch return StringError.InvalidFormat else null,
                .Minutes => time.minutes = if (substring) |substr| std.fmt.parseInt(i32, substr, 10) catch return StringError.InvalidFormat else null,
                .Seconds => time.seconds = if (substring) |substr| std.fmt.parseInt(i32, substr, 10) catch return StringError.InvalidFormat else null,
            }
        }
        return time;
    }
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

    pub fn sub(self: Self, other: Self) Self {
        const self_seconds = self.getSeconds();
        const other_seconds = other.getSeconds();
        return (Time{ .seconds = self_seconds - other_seconds }).toReadable();
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

    pub fn fromString(str: [:0]const u8) StringError!Date {
        const pattern_ymd = "^(?:(?'year'\\d{4})(?:-(?'month'\\d{2})(?:-(?'day'\\d{2}))?)?)?(?: ?(?'hours'\\d{2}):?(?'minutes'\\d{2}))?$";
        const pattern_md = "^(?:(\\d{2})-(\\d{2}))(?: (\\d{2}):?(\\d{2}))?$";
        _ = pattern_md; // TODO

        const re = try Regex.compile(pattern_ymd);
        defer re.deinit();

        var cap = try re.captures(str);

        const DatePart = enum {
            Year,
            Month,
            Day,
            Hours,
            Minutes,
        };
        const parts = [_]struct { str: [:0]const u8, val: DatePart }{
            .{ .str = "year", .val = .Year },
            .{ .str = "month", .val = .Month },
            .{ .str = "day", .val = .Day },
            .{ .str = "hours", .val = .Hours },
            .{ .str = "minutes", .val = .Minutes },
        };
        var date = Date.default();
        for (parts) |part| {
            const name = part.str;
            const v = part.val;
            const substring = try cap.getNamedMatch(name);
            if (substring) |substr| {
                print("{s}: {s}\n", .{ name, substr });
                switch (v) {
                    .Year => date.setYear(std.fmt.parseInt(i32, substr, 10) catch return StringError.InvalidFormat),
                    .Month => date.setMonth(std.fmt.parseInt(i32, substr, 10) catch return StringError.InvalidFormat),
                    .Day => date.setDay(std.fmt.parseInt(i32, substr, 10) catch return StringError.InvalidFormat),
                    .Hours => date.setHours(std.fmt.parseInt(i32, substr, 10) catch return StringError.InvalidFormat),
                    .Minutes => date.setMinutes(std.fmt.parseInt(i32, substr, 10) catch return StringError.InvalidFormat),
                }
                date.update();
                cap.deinitMatch(substr);
            }
        }
        return date;
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
    pub fn getDay(self: Self) i32 {
        return self.tm.tm_mday;
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
    pub fn timeSince(self: Self, other: Self) Time {
        return Time.initS(self.secondsSince(other));
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
        self.tm.tm_mon = month - 1;
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
    pub fn setHourF(self: *Self, hour: f32) void {
        self.tm.tm_hour = @intFromFloat(@floor(hour));
        self.tm.tm_min = @intFromFloat(@mod(hour, 1));
        _ = c.mktime(&self.tm);
    }
    pub fn setMinutes(self: *Self, minute: i32) void {
        self.tm.tm_min = minute;
    }

    pub fn update(self: *Self) void {
        _ = c.mktime(&self.tm);
    }

    // TODO
};

pub const Pattern = struct {
    sun: bool = false,
    mon: bool = false,
    tue: bool = false,
    wed: bool = false,
    thu: bool = false,
    fri: bool = false,
    sat: bool = false,

    pub fn fromString(str: [:0]const u8) StringError!Pattern {
        const pattern = "(\\d)(\\d)(\\d)(\\d)(\\d)(\\d)(\\d)";

        const re = try Regex.compile(pattern);
        defer re.deinit();

        var cap = try re.captures(str);

        var p = Pattern{};
        for (1..8) |i| {
            const substr = cap.sliceAt(i).?;
            defer cap.deinitMatch(substr);
            const v = std.fmt.parseInt(i1, substr, 10) catch return StringError.InvalidFormat;
            switch (i) {
                1 => p.sun = (v == 1),
                2 => p.mon = (v == 1),
                3 => p.tue = (v == 1),
                4 => p.wed = (v == 1),
                5 => p.thu = (v == 1),
                6 => p.fri = (v == 1),
                7 => p.sat = (v == 1),
                else => unreachable,
            }
        }
        return p;
    }

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
    pub fn fromString(str: [:0]const u8) StringError!Period {
        const v = Pattern.fromString(str) catch |e| {
            switch (e) {
                StringError.InvalidFormat => return .{ .time = try Time.fromString(str) },
                else => return e,
            }
        };
        return .{ .pattern = v };
    }
    pub fn toString(self: Period, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            inline else => |x| x.toString(allocator),
        };
    }
};
pub const RepeatInfo = struct {
    const Self = @This();
    period: Period,
    start: Date,
    end: ?Date = null,
    pub fn fromString(str: [:0]const u8) StringError!RepeatInfo {
        const pattern = "(?'period_str'.*)\n(?'start_str'.*)\n(?'end_str'.*)";

        const re = try Regex.compile(pattern);
        defer re.deinit();

        var cap = try re.captures(str);

        const RepeatPart = enum {
            Period,
            Start,
            End,
        };
        const parts = [_]struct { str: [:0]const u8, val: RepeatPart }{
            .{ .str = "period", .val = .Period },
            .{ .str = "start", .val = .Start },
            .{ .str = "end", .val = .End },
        };
        var info = RepeatInfo{ .period = undefined, .start = undefined };
        for (parts) |part| {
            const name = part.str;
            const v = part.val;
            const substring = try cap.getNamedMatch(name);
            defer cap.deinitMatch(substring);
            switch (v) {
                .Period => info.period = try Period.fromString(substring.?),
                .Start => info.start = try Date.fromString(substring.?),
                .End => info.end = if (substring) |substr| try Date.fromString(substr) else null,
            }
        }
        return info;
    }
    pub fn toString(self: Self, allocator: std.mem.Allocator) ![]const u8 {
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
