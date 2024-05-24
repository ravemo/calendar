const std = @import("std");
const calendar = @import("event.zig");
const Event = calendar.Event;
const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
});
pub const Renderer = ?*c.SDL_Renderer;

pub const EventRect = struct {
    evid: i32,
    rect: c.SDL_FRect,
    pub fn isInside(self: EventRect, x: f32, y: f32) bool {
        return (self.rect.x <= x and self.rect.x + self.rect.w >= x and
            self.rect.y <= y and self.rect.y + self.rect.h >= y);
    }
};

pub const Surface = struct {
    const Self = @This();
    renderer: Renderer,
    tex: ?*c.SDL_Texture,
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    eventRects: std.ArrayList(EventRect),

    pub fn init(allocator: std.mem.Allocator, renderer: Renderer, x: f32, y: f32, w: f32, h: f32) Self {
        return .{
            .renderer = renderer,
            .tex = c.SDL_CreateTexture(
                renderer,
                c.SDL_PIXELFORMAT_RGBA8888,
                c.SDL_TEXTUREACCESS_TARGET,
                @intFromFloat(w),
                @intFromFloat(h),
            ),
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .eventRects = std.ArrayList(EventRect).init(allocator),
        };
    }

    pub fn deinit(self: Self) void {
        self.eventRects.deinit();
    }

    pub fn clearEventRects(self: *Self) void {
        self.eventRects.clearRetainingCapacity();
    }

    pub fn getEventRectBelow(self: Self, x: i32, y: i32) ?EventRect {
        const xf: f32 = @as(f32, @floatFromInt(x)) - self.x;
        const yf: f32 = @as(f32, @floatFromInt(y)) - self.y;
        for (self.eventRects.items) |e| {
            if (e.isInside(xf, yf)) return e;
        }
        return null;
    }

    pub fn getRect(self: Self) c.SDL_Rect {
        return .{
            .x = @intFromFloat(self.x),
            .y = @intFromFloat(self.y),
            .w = @intFromFloat(self.w),
            .h = @intFromFloat(self.h),
        };
    }

    pub fn draw(self: Self) void {
        _ = c.SDL_RenderCopy(self.renderer, self.tex, null, &self.getRect());
    }
};
