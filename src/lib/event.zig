const datetime = @import("datetime.zig");
const Time = datetime.Time;
const Date = datetime.Date;
const RepeatInfo = datetime.RepeatInfo;
const Weekday = datetime.Weekday;

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
