const std = @import("std");
const Surface = @import("surface.zig").Surface;
const Date = @import("event.zig").Date;

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
});
pub const Renderer = ?*c.SDL_Renderer;
pub const EventRect = struct {
    evid: i32,
    rect: c.SDL_FRect,
    pub fn isInside(self: EventRect, x: f32, y: f32) bool {
        //std.debug.print("{}: ({}, {}), {} x {}\n", .{ self.evid, self.rect.x, self.rect.y, self.rect.w, self.rect.h });
        return (self.rect.x <= x and self.rect.x + self.rect.w >= x and
            self.rect.y <= y and self.rect.y + self.rect.h >= y);
    }
};

pub const WeekView = struct {
    const Self = @This();
    sf: Surface,
    eventRects: std.ArrayList(EventRect),
    start: Date,
    pub fn init(allocator: std.mem.Allocator, renderer: Renderer, scrn_w: f32, scrn_h: f32) Self {
        return .{
            .sf = Surface.init(renderer, 64, 96, scrn_w - 64, scrn_h - 96),
            .eventRects = std.ArrayList(EventRect).init(allocator),
            .start = Date.now().getWeekStart(),
        };
    }
    pub fn deinit(self: Self) void {
        self.eventRects.deinit();
        self.sf.deinit();
    }
    pub fn clearEventRects(self: *Self) void {
        self.eventRects.clearRetainingCapacity();
    }

    pub fn getEventRectBelow(self: Self, x: i32, y: i32) ?EventRect {
        const xf: f32 = @as(f32, @floatFromInt(x)) - self.sf.x;
        const yf: f32 = @as(f32, @floatFromInt(y)) - self.sf.y;
        for (self.eventRects.items) |e| {
            //std.debug.print("??? Id: {}\n", .{e.evid});
            if (e.isInside(xf, yf)) return e;
        }
        return null;
    }

    pub fn isHoveringEnd(self: Self, x: i32, y: i32, er: EventRect) bool {
        // TODO Some EventRects don't have ends (those that wrap around midnight)
        const xf: f32 = @as(f32, @floatFromInt(x)) - self.sf.x;
        const yf: f32 = @as(f32, @floatFromInt(y)) - self.sf.y;
        return er.isInside(xf, yf) and yf > er.rect.y + er.rect.h - 16;
    }

    pub fn getEnd(self: Self) Date {
        return self.start.after(.{ .weeks = 1 });
    }
};
