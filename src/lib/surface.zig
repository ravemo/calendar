const std = @import("std");
const event_lib = @import("event.zig");
const Event = event_lib.Event;
const calendar = @import("datetime.zig");
const Date = calendar.Date;
const TextRenderer = @import("text.zig").TextRenderer;
const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
});

pub const Surface = struct {
    const Self = @This();
    text_renderer: TextRenderer,
    tex: ?*c.SDL_Texture,
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    sx: f32,
    sy: f32,
    zoom: f32,

    pub fn init(text_renderer: TextRenderer, x: f32, y: f32, w: f32, h: f32) Self {
        return .{
            .text_renderer = text_renderer,
            .tex = c.SDL_CreateTexture(
                @ptrCast(text_renderer.renderer),
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
        _ = c.SDL_RenderCopy(
            @ptrCast(self.text_renderer.renderer),
            self.tex,
            null,
            &self.getRect(),
        );
    }

    pub fn xFromDate(self: Self, date: Date) ?f32 {
        return self.w * @as(f32, @floatFromInt(date.getWeekday())) / 7 + self.sx;
    }
    pub fn xFromWeekday(self: Self, wd: i32) f32 {
        return @as(f32, @floatFromInt(wd)) * self.w / 7 + self.sx;
    }
    pub fn weekdayFromX(self: Self, x: f32) i32 {
        return @intFromFloat(@round(7 * (x - self.sx) / self.w));
    }
    pub fn yFromHour(self: Self, hour: f32) f32 {
        return self.h * hour / (24 * self.getScale()) + self.sy;
    }
    pub fn hourFromY(self: Self, y: f32) f32 {
        return (24 * self.getScale()) * (y - self.sy) / self.h;
    }
};
