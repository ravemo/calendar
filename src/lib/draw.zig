const std = @import("std");
const calendar = @import("event.zig");
const Event = calendar.Event;
const Date = calendar.Date;
const Time = calendar.Time;

const text = @import("text.zig");
const arc = @import("arc.zig");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
});

pub const Renderer = ?*c.SDL_Renderer;
const text_color = arc.colorFromHex(0x000000ff);
const grid_color = arc.colorFromHex(0xeeeeeeff);
const divider_color = arc.colorFromHex(0xaaaaaaff);

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

pub fn drawGrid(sf: Surface) void {
    _ = sf;
    //const renderer = sf.renderer;
    //const grid_size: f32 = 32;
    //const grid_count_w: usize = @intFromFloat(@ceil(sf.w / grid_size));
    //const grid_count_h: usize = @intFromFloat(@ceil(sf.h / grid_size));
    //arc.setColor(renderer, grid_color);
    //for (0..grid_count_w) |i| {
    //    const x: f32 = @as(f32, @floatFromInt(i)) * grid_size;
    //    _ = c.SDL_RenderDrawLineF(renderer, x, 0, x, sf.h);
    //}
    //for (0..grid_count_h) |i| {
    //    const y: f32 = @as(f32, @floatFromInt(i)) * grid_size;
    //    _ = c.SDL_RenderDrawLineF(renderer, 0, y, sf.w, y);
    //}
}

pub fn drawWeek(sf: Surface, events: []Event, now: Date) void {
    _ = events;
    _ = now;

    const renderer = sf.renderer;
    _ = c.SDL_SetRenderTarget(renderer, sf.tex);
    _ = c.SDL_SetRenderDrawColor(renderer, 0xFF, 0xFF, 0xFF, 0xFF);
    _ = c.SDL_RenderClear(renderer);

    drawGrid(sf);

    arc.setColor(renderer, divider_color);
    for (0..7) |i| {
        const x: f32 = sf.w * @as(f32, @floatFromInt(i)) / 7;
        _ = c.SDL_RenderDrawLineF(renderer, x, 0, x, sf.h);
    }
    _ = c.SDL_SetRenderTarget(renderer, null);
}

pub fn drawHours(sf: Surface, now: Date) void {
    _ = now;

    const renderer = sf.renderer;
    _ = c.SDL_SetRenderTarget(renderer, sf.tex);
    _ = c.SDL_SetRenderDrawColor(renderer, 0xFF, 0xFF, 0xFF, 0xFF);
    _ = c.SDL_RenderClear(renderer);

    drawGrid(sf);

    arc.setColor(renderer, text_color);
    const sep = sf.h / 24;
    for (0..24) |i| {
        const y: f32 = sep * @as(f32, @floatFromInt(i));
        var buf: [6:0]u8 = undefined;
        buf = std.mem.bytesToValue([6:0]u8, std.fmt.bufPrintZ(&buf, "{}:00", .{i}) catch "error");
        text.drawText(renderer, &buf, sf.w - 10, y + sep / 2, .Right, .Center);
    }

    arc.setColor(renderer, divider_color);
    for (0..24) |i| {
        const y: f32 = sep * @as(f32, @floatFromInt(i));
        _ = c.SDL_RenderDrawLineF(renderer, 0, y, sf.w, y);
    }
    _ = c.SDL_SetRenderTarget(renderer, null);
}

pub fn drawDays(sf: Surface, now: Date) void {
    const renderer = sf.renderer;
    const weekdays = [_][:0]const u8{ "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday" };
    _ = c.SDL_SetRenderTarget(renderer, sf.tex);
    _ = c.SDL_SetRenderDrawColor(renderer, 0xFF, 0xFF, 0xFF, 0xFF);
    _ = c.SDL_RenderClear(renderer);

    drawGrid(sf);

    arc.setColor(renderer, text_color);
    const start_day: usize = @intCast(now.getWeekStart().tm.tm_mday);
    for (0..7, weekdays) |i, weekday| {
        const x: f32 = sf.w * @as(f32, @floatFromInt(i)) / 7;
        var buf: [2:0]u8 = undefined;
        _ = std.fmt.formatIntBuf(&buf, start_day + i, 10, .lower, .{});
        text.drawText(renderer, weekday, x + sf.w / 14, sf.h / 3, .Center, .Center);
        text.drawText(renderer, &buf, x + sf.w / 14, 2 * sf.h / 3, .Center, .Center);
    }
    arc.setColor(renderer, divider_color);
    for (0..7) |i| {
        const x: f32 = sf.w * @as(f32, @floatFromInt(i)) / 7;
        _ = c.SDL_RenderDrawLineF(renderer, x, sf.h * 3.0 / 4, x, sf.h);
    }
    _ = c.SDL_RenderDrawLineF(renderer, 0, sf.h - 1, sf.w, sf.h - 1);

    _ = c.SDL_SetRenderTarget(renderer, null);
}
