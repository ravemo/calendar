const calendar = @import("event.zig");
const Time = calendar.Time;
const Date = calendar.Date;

pub const Task = struct {
    const Self = @This();
    id: i32,
    name: []const u8,
    time: Time,
    start: ?Date,
    due: ?Date,
    // TODO: repeat info
    scheduled_start: Date,
    // TODO: Tasks should be able to be split, so we need scheduled_time

    pub fn getEnd(self: Self) Date {
        return self.scheduled_start.after(self.time);
    }
};
