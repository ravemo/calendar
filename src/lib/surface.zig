const std = @import("std");
const calendar = @import("event.zig");
const Event = calendar.Event;
const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
});
pub const Renderer = ?*c.SDL_Renderer;

pub const Surface = struct {
    const Self = @This();
    renderer: Renderer,
    tex: ?*c.SDL_Texture,
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    sx: f32,
    sy: f32,
    zoom: f32,

    pub fn init(renderer: Renderer, x: f32, y: f32, w: f32, h: f32) Self {
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
            .sx = 0,
            .sy = 0,
            .zoom = 1,
        };
    }

    pub fn deinit(self: Self) void {
        c.SDL_DestroyTexture(self.tex);
    }

    pub fn getRect(self: Self) c.SDL_Rect {
        return .{
            .x = @intFromFloat(self.x),
            .y = @intFromFloat(self.y),
            .w = @intFromFloat(self.w),
            .h = @intFromFloat(self.h),
        };
    }

    pub fn zoomIn(self: *Self, zoom_amount: f32) void {
        const old_z = self.getScale();
        self.zoom += zoom_amount;
        if (self.zoom < 0) self.zoom = 0;
        const z = self.getScale();
        self.sy = (self.sy - self.h / 2) * (old_z / z) + self.h / 2;
        self.scroll(0); // update sy if it gets out of bounds
    }
    pub fn scroll(self: *Self, scroll_amount: f32) void {
        const z = 1 / self.getScale();
        self.sy = @max(@min(self.sy + scroll_amount, 0), -self.h * (z - 1));
    }
    pub fn getScale(self: Self) f32 {
        return @exp(-self.zoom / 50.0);
    }

    pub fn draw(self: Self) void {
        _ = c.SDL_RenderCopy(self.renderer, self.tex, null, &self.getRect());
    }
};
