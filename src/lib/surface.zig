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

    pub fn draw(self: Self) void {
        _ = c.SDL_RenderCopy(self.renderer, self.tex, null, &self.getRect());
    }
};
