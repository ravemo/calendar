const c = @cImport({
    @cInclude("time.h");
});

pub const Date = struct {
    const Self = @This();
    tm: c.tm,

    pub fn now() Date {
        const t: c.time_t = c.time(null);
        var tm: c.tm = undefined;
        _ = c.localtime_r(&t, &tm);
        return .{ .tm = tm };
    }

    pub fn getWeekStart(self: Self) Date {
        var new_tm = self.tm;
        new_tm.tm_mday = new_tm.tm_mday - new_tm.tm_wday;
        _ = c.mktime(&new_tm);
        return .{ .tm = new_tm };
    }
    // TODO
};
pub const Time = struct {
    // TODO
};
pub const RepeatInfo = struct {
    period: Time,
    pattern: []Time,
    end_time: Date,
};
pub const Event = struct {
    name: []u8,
    start_time: Date,
    duration: ?Time,
    repeat: ?RepeatInfo,
};
