const std = @import("std");
const Surface = @import("surface.zig").Surface;
const Date = @import("datetime.zig").Date;
const TextRenderer = @import("text.zig").TextRenderer;

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
});
pub const IdRect = struct {
    id: i32,
    rect: c.SDL_FRect,
    pub fn isInside(self: IdRect, x: f32, y: f32) bool {
        return (self.rect.x <= x and self.rect.x + self.rect.w >= x and
            self.rect.y <= y and self.rect.y + self.rect.h >= y);
    }
};

pub const WeekView = struct {
    const Self = @This();
    sf: Surface,
    eventRects: std.ArrayList(IdRect),
    taskRects: std.ArrayList(IdRect),
    start: Date,
    pub fn init(allocator: std.mem.Allocator, renderer: TextRenderer, scrn_w: f32, scrn_h: f32) Self {
        return .{
            .sf = Surface.init(renderer, 64, 96, scrn_w - 64, scrn_h - 96),
            .eventRects = std.ArrayList(IdRect).init(allocator),
            .taskRects = std.ArrayList(IdRect).init(allocator),
            .start = Date.now().getWeekStart(),
        };
    }
    pub fn deinit(self: Self) void {
        self.eventRects.deinit();
        self.taskRects.deinit();
        self.sf.deinit();
    }
    pub fn clearIdRects(self: *Self) void {
        self.eventRects.clearRetainingCapacity();
        self.taskRects.clearRetainingCapacity();
    }

    pub fn getEventRectBelow(self: Self, x: i32, y: i32) ?IdRect {
        const xf: f32 = @as(f32, @floatFromInt(x)) - self.sf.x;
        const yf: f32 = @as(f32, @floatFromInt(y)) - self.sf.y;
        for (self.eventRects.items) |e| {
            if (e.isInside(xf, yf)) return e;
        }
        return null;
    }

    pub fn getTaskRectBelow(self: Self, x: i32, y: i32) ?IdRect {
        const xf: f32 = @as(f32, @floatFromInt(x)) - self.sf.x;
        const yf: f32 = @as(f32, @floatFromInt(y)) - self.sf.y;
        for (self.taskRects.items) |e| {
            if (e.isInside(xf, yf)) return e;
        }
        return null;
    }

    pub fn isHoveringEnd(self: Self, x: i32, y: i32, er: IdRect) bool {
        // TODO Some IdRects don't have ends (those that wrap around midnight)
        const xf: f32 = @as(f32, @floatFromInt(x)) - self.sf.x;
        const yf: f32 = @as(f32, @floatFromInt(y)) - self.sf.y;
        return er.isInside(xf, yf) and yf > er.rect.y + er.rect.h - 8;
    }

    pub fn getEnd(self: Self) Date {
        return self.start.after(.{ .weeks = 1 });
    }
};
