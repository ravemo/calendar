const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
    @cInclude("pcre.h");
});
const regex = @import("regex.zig");
const Regex = regex.Regex;
const Captures = regex.Captures;

const print = std.debug.print;

pub const StringError = error{
    ConversionError,
    RegexError,
    NoMatches,
};
pub const Time = struct {
    const Self = @This();
    seconds: i32 = 0,
    minutes: i32 = 0,
    hours: i32 = 0,
    days: i32 = 0,
    weeks: i32 = 0,

    pub fn initS(seconds: i32) Self {
        const t = Time{ .seconds = seconds };
        return t.toReadable();
    }
    pub fn initM(hours: i32) Self {
        return Time.initS(hours * 60).toReadable();
    }
    pub fn initH(hours: i32) Self {
        return Time.initS(hours * 60 * 60).toReadable();
    }
    pub fn initHF(hoursF: f32) Self {
        return Time.initS(@intFromFloat(@round(hoursF * 60 * 60))).toReadable();
    }

    pub fn fromString(str: [:0]const u8) StringError!Self {
        const patterns: [5][:0]const u8 = .{
            "(?'weeks'\\d+)? ?week",
            "(?'days'\\d+)? ?d(?:ay)?",
            "(?'hours'\\d+)? ?h(?:our)?",
            "(?'minutes'\\d+)? ?m(?:inute)?",
            "(((?'seconds'\\d+) ?)|(^))s(?:econd)?",
        };

        var regexes: [5]Regex = undefined;
        var caps: [5]?Captures = undefined;
        for (&regexes, &caps, patterns) |*re, *cap, pattern| {
            re.* = try Regex.compile(pattern);
            cap.* = re.captures(str) catch |e| switch (e) {
                StringError.NoMatches => null,
                else => return e,
            };
        }
        defer for (&regexes) |*re|
            re.deinit();

        const TimePart = enum {
            Weeks,
            Days,
            Hours,
            Minutes,
            Seconds,
        };
        const parts = [_]struct { name: [:0]const u8, val: TimePart }{
            .{ .name = "weeks", .val = .Weeks },
            .{ .name = "days", .val = .Days },
            .{ .name = "hours", .val = .Hours },
            .{ .name = "minutes", .val = .Minutes },
            .{ .name = "seconds", .val = .Seconds },
        };
        var time = Time{};
        for (parts, &caps) |part, *cap_opt| {
            if (cap_opt.* == null) continue;
            var cap = cap_opt.*.?;
            const v = part.val;
            const substring = cap.getNamedMatch(part.name);
            defer cap.deinitMatch(substring);
            const int_val = if (substring) |substr|
                std.fmt.parseInt(i32, substr, 10) catch {
                    return StringError.ConversionError;
                }
            else
                1;
            switch (v) {
                .Weeks => time.weeks = int_val,
                .Days => time.days = int_val,
                .Hours => time.hours = int_val,
                .Minutes => time.minutes = int_val,
                .Seconds => time.seconds = int_val,
            }
        }
        return time;
    }
    pub fn toString(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{} weeks, {} days, {} hours, {} minutes, {} seconds", .{
            self.weeks, self.days, self.hours, self.minutes, self.seconds,
        });
    }

    pub fn getHoursF(self: Self) f32 {
        var hours: f32 = 0;
        hours += @floatFromInt(self.weeks * 7 * 24);
        hours += @floatFromInt(self.days * 24);
        hours += @floatFromInt(self.hours);
        hours += @as(f32, @floatFromInt(self.minutes)) / 60;
        hours += @as(f32, @floatFromInt(self.seconds)) / (60 * 60);
        return hours;
    }

    pub fn getSeconds(self: Self) i32 {
        var seconds: i32 = 0;
        seconds += self.weeks * 60 * 60 * 24 * 7;
        seconds += self.days * 60 * 60 * 24;
        seconds += self.hours * 60 * 60;
        seconds += self.minutes * 60;
        seconds += self.seconds;
        return seconds;
    }

    pub fn toReadable(self: Self) Self {
        var t = Time{ .seconds = self.getSeconds() };
        if (@abs(t.seconds) >= 7 * 24 * 60 * 60) {
            t.weeks = @divFloor(t.seconds, 7 * 24 * 60 * 60);
            t.seconds -= t.weeks * 7 * 24 * 60 * 60;
        }
        if (@abs(t.seconds) >= 24 * 60 * 60) {
            t.days = @divFloor(t.seconds, 24 * 60 * 60);
            t.seconds -= t.days * 24 * 60 * 60;
        }
        if (@abs(t.seconds) >= 60 * 60) {
            t.hours = @divFloor(t.seconds, 60 * 60);
            t.seconds -= t.hours * 60 * 60;
        }
        if (@abs(t.seconds) >= 60) {
            t.minutes = @divFloor(t.seconds, 60);
            t.seconds -= t.minutes * 60;
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
    pub fn shorterThan(self: Self, other: Self) bool {
        const self_seconds = self.getSeconds();
        const other_seconds = other.getSeconds();
        return self_seconds < other_seconds;
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
        const pattern_ymd = "^(?:(?'year'\\d{4})(?:-(?'month'\\d{2})(?:-(?'day'\\d{2}))?)?)?(?: ?(?'hours'\\d{2}):?(?:(?'minutes'\\d{2})(?::(?'seconds'\\d{2}))?)?)?$";
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
            Seconds,
        };
        const parts = [_]struct { str: [:0]const u8, val: DatePart }{
            .{ .str = "year", .val = .Year },
            .{ .str = "month", .val = .Month },
            .{ .str = "day", .val = .Day },
            .{ .str = "hours", .val = .Hours },
            .{ .str = "minutes", .val = .Minutes },
            .{ .str = "seconds", .val = .Seconds },
        };
        var date = Date.default();
        for (parts) |part| {
            const name = part.str;
            const v = part.val;
            const substring = cap.getNamedMatch(name);
            if (substring) |substr| {
                switch (v) {
                    .Year => date.setYear(std.fmt.parseInt(i32, substr, 10) catch return StringError.ConversionError),
                    .Month => date.setMonth(std.fmt.parseInt(i32, substr, 10) catch return StringError.ConversionError),
                    .Day => date.setDay(std.fmt.parseInt(i32, substr, 10) catch return StringError.ConversionError),
                    .Hours => date.setHours(std.fmt.parseInt(i32, substr, 10) catch return StringError.ConversionError),
                    .Minutes => date.setMinutes(std.fmt.parseInt(i32, substr, 10) catch return StringError.ConversionError),
                    .Seconds => date.setSeconds(std.fmt.parseInt(i32, substr, 10) catch return StringError.ConversionError),
                }
                date.update();
                cap.deinitMatch(substr);
            }
        }
        return date;
    }

    pub fn toStringZ(self: Self, allocator: std.mem.Allocator) ![:0]const u8 {
        return std.fmt.allocPrintZ(allocator, "{:0>4}-{:0>2}-{:0>2} {:0>2}:{:0>2}", .{
            @as(u32, @intCast(self.tm.tm_year + 1900)),
            @as(u32, @intCast(self.tm.tm_mon + 1)),
            @as(u32, @intCast(self.tm.tm_mday)),
            @as(u32, @intCast(self.tm.tm_hour)),
            @as(u32, @intCast(self.tm.tm_min)),
        });
    }
    pub fn toString(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{:0>4}-{:0>2}-{:0>2} {:0>2}:{:0>2}", .{
            @as(u32, @intCast(self.tm.tm_year + 1900)),
            @as(u32, @intCast(self.tm.tm_mon + 1)),
            @as(u32, @intCast(self.tm.tm_mday)),
            @as(u32, @intCast(self.tm.tm_hour)),
            @as(u32, @intCast(self.tm.tm_min)),
        });
    }

    pub fn earliest(a: ?Date, b: ?Date) ?Date {
        return if (Date.isBefore(a, b)) a else b;
    }
    pub fn latest(a: ?Date, b: ?Date) ?Date {
        return if (Date.isBefore(a, b)) b else a;
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

    pub fn isBefore(self: ?Self, other_opt: ?Self) bool {
        if (self == null) return false;
        if (other_opt) |other| {
            var tm0 = self.?.tm;
            var tm1 = other.tm;
            const t0 = c.mktime(&tm0);
            const t1 = c.mktime(&tm1);
            return c.difftime(t0, t1) < 0;
        } else return true;
    }
    pub fn isBeforeEq(self: ?Self, other_opt: ?Self) bool {
        if (self == null) return false;
        if (other_opt) |other| {
            var tm0 = self.?.tm;
            var tm1 = other.tm;
            const t0 = c.mktime(&tm0);
            const t1 = c.mktime(&tm1);
            return c.difftime(t0, t1) <= 0;
        } else return true;
    }
    pub fn eql(self: ?Self, other: ?Self) bool {
        if (other == null) return (self == null);
        if (self == null) return false;
        var tm0 = self.?.tm;
        var tm1 = other.?.tm;
        const t0 = c.mktime(&tm0);
        const t1 = c.mktime(&tm1);
        return c.difftime(t0, t1) == 0;
    }

    pub fn after(self: Self, offset: Time) Self {
        var new_tm = self.tm;
        new_tm.tm_sec += offset.seconds;
        new_tm.tm_min += offset.minutes;
        new_tm.tm_hour += offset.hours;
        new_tm.tm_mday += offset.days;
        new_tm.tm_mday += offset.weeks * 7;
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
        self.update();
        self.tm.tm_mday += @as(i32, @intFromEnum(wday)) - self.tm.tm_wday;
        self.update();
    }
    pub fn setHours(self: *Self, hour: i32) void {
        self.tm.tm_hour = hour;
    }
    pub fn setHourF(self: *Self, hour: f32) void {
        self.tm.tm_hour = @intFromFloat(@floor(hour));
        self.tm.tm_min = @intFromFloat(@mod(hour, 1.0) * 60);
        _ = c.mktime(&self.tm);
    }
    pub fn setMinutes(self: *Self, minute: i32) void {
        self.tm.tm_min = minute;
    }
    pub fn setSeconds(self: *Self, seconds: i32) void {
        self.tm.tm_sec = seconds;
    }

    pub fn update(self: *Self) void {
        _ = c.mktime(&self.tm);
    }

    pub fn print(self: Self) void {
        std.debug.print("{:0>4}-{:0>2}-{:0>2} {:0>2}:{:0>2}.{:0>2}", .{
            @as(u32, @intCast(self.tm.tm_year + 1900)),
            @as(u32, @intCast(self.tm.tm_mon + 1)),
            @as(u32, @intCast(self.tm.tm_mday)),
            @as(u32, @intCast(self.tm.tm_hour)),
            @as(u32, @intCast(self.tm.tm_min)),
            @as(u32, @intCast(self.tm.tm_sec)),
        });
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

    pub fn fromString(str: [:0]const u8) StringError!Pattern {
        const pattern = "(\\d)(\\d)(\\d)(\\d)(\\d)(\\d)(\\d)";

        const re = try Regex.compile(pattern);
        defer re.deinit();

        var cap = try re.captures(str);

        var p = Pattern{};
        for (1..8) |i| {
            const substr = cap.sliceAt(i).?;
            defer cap.deinitMatch(substr);
            const v = std.fmt.parseInt(i1, substr, 10) catch return StringError.ConversionError;
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
                StringError.NoMatches => return .{ .time = try Time.fromString(str) },
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
    pub fn toStringZ(self: Period, allocator: std.mem.Allocator) ![:0]const u8 {
        const normal = try self.toString(allocator);
        defer allocator.free(normal);
        return allocator.dupeZ(u8, normal);
    }
};
pub const RepeatInfo = struct {
    const Self = @This();
    period: Period,
    end: ?Date = null,
    pub fn fromString(str: [:0]const u8) StringError!RepeatInfo {
        const pattern = "every (?'period'.*),?(?: until (?'end'.*))?";

        const re = try Regex.compile(pattern);
        defer re.deinit();

        var cap = try re.captures(str);

        const RepeatPart = enum {
            Period,
            End,
        };
        const parts = [_]struct { str: [:0]const u8, val: RepeatPart }{
            .{ .str = "period", .val = .Period },
            .{ .str = "end", .val = .End },
        };
        var info = RepeatInfo{ .period = undefined };
        for (parts) |part| {
            const name = part.str;
            const v = part.val;
            const substring = cap.getNamedMatch(name);
            defer cap.deinitMatch(substring);
            switch (v) {
                .Period => info.period = try Period.fromString(substring.?),
                .End => info.end = if (substring) |substr| try Date.fromString(substr) else null,
            }
        }
        return info;
    }
    pub fn toString(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        const period_str = self.period.toString(allocator);
        const end_str = if (self.end) |e| e.toString(allocator) else null;
        defer allocator.free(period_str);
        defer allocator.free(end_str);
        return std.fmt.allocPrint(allocator, "{s}\n{?s}", .{
            period_str,
            end_str,
        });
    }
};

test "string to RepeatInfo" {
    var repeat_info: RepeatInfo = undefined;
    repeat_info = try RepeatInfo.fromString("every 1 week");
    try std.testing.expectEqual(7 * 24 * 60 * 60, repeat_info.period.time.getSeconds());
    repeat_info = try RepeatInfo.fromString("every 2 weeks");
    try std.testing.expectEqual(2 * 7 * 24 * 60 * 60, repeat_info.period.time.getSeconds());
    repeat_info = try RepeatInfo.fromString("every week");
    try std.testing.expectEqual(7 * 24 * 60 * 60, repeat_info.period.time.getSeconds());
}
