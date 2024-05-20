const std = @import("std");
const calendar = @import("event.zig");
const Event = calendar.Event;
const Date = calendar.Date;
const DateIter = calendar.DateIter;
const Weekday = calendar.Weekday;
const Time = calendar.Time;

const text = @import("text.zig");
const arc = @import("arc.zig");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
});

pub const Renderer = ?*c.SDL_Renderer;
const background_color = arc.colorFromHex(0xffffffff);
const text_color = arc.colorFromHex(0x000000ff);
const grid_color = arc.colorFromHex(0xeeeeeeff);
const divider_color = arc.colorFromHex(0xaaaaaaff);
const event_color = arc.colorFromHex(0x1f842188);

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
    const renderer = sf.renderer;
    const grid_count_h: usize = @intFromFloat(@ceil(sf.h / 12));
    arc.setColor(renderer, grid_color);
    for (0..grid_count_h) |i| {
        const y: f32 = @as(f32, @floatFromInt(i)) * sf.h / 48;
        _ = c.SDL_RenderDrawLineF(renderer, 0, y, sf.w, y);
    }
}

pub fn xFromWeekday(wday: i32, w: f32) f32 {
    return w * @as(f32, @floatFromInt(wday)) / 7;
}
pub fn yFromHour(hour: f32, h: f32) f32 {
    return h * hour / 24;
}

pub fn drawSingleEvent(sf: Surface, event: Event) void {
    const renderer = sf.renderer;
    // if the event crosses the day boundary, but does not end at midnight
    if (event.start.getDayStart().isBefore(event.getEnd().getDayStart()) and
        event.getEnd().getDayStart().secondsSince(event.getEnd()) != 0)
    {
        const split = event.start.after(.{ .days = 1 }).getDayStart();
        var head = event;
        head.end = .{ .date = split };
        drawSingleEvent(sf, head);

        var tail = event;
        tail.start = split;
        switch (tail.end) {
            .time => |*t| t.* = t.add(.{ .seconds = -head.getEnd().secondsSince(head.start) }),
            else => {},
        }
        drawSingleEvent(sf, tail);
        return;
    }
    const h = switch (event.end) {
        .time => |t| t.getHoursF(),
        .date => |d| d.hoursSinceF(event.start),
    };

    const x = xFromWeekday(event.start.getWeekday(), sf.w) + 3;
    const y = yFromHour(event.start.getHourF(), sf.h);
    arc.setColor(renderer, event_color);
    _ = c.SDL_RenderFillRectF(renderer, &c.SDL_FRect{
        .x = x,
        .y = y,
        .w = sf.w / 7 - 6,
        .h = h * sf.h / 24,
    });

    arc.setColor(renderer, text_color);
    text.drawText(renderer, event.name, x + 2, y + 2, .Left, .Top);
}
pub fn drawEvent(sf: Surface, event: Event, now: Date) void {
    const view_start = Date.now().getWeekStart();
    const view_end = Date.now().getWeekStart().after(.{ .weeks = 1 });

    if (event.repeat) |repeat| {
        var repeat_start = repeat.start;
        // if the event starts after the week view, do nothing
        if (now.after(.{ .weeks = 1 }).getWeekStart().isBefore(repeat_start))
            return;
        // If the event starts before this week view, just start on sunday
        if (repeat_start.isBefore(now.getWeekStart()))
            repeat_start = now.getWeekStart();

        const repeat_end = if (repeat.end) |end| end else repeat_start.after(.{ .days = 8 });

        switch (repeat.period) {
            .time => |t| {
                var iterator = DateIter.init(repeat_start, repeat_end);
                while (iterator.next(t)) |i| {
                    const e = event.atDay(i);
                    if (e.getEnd().isBefore(view_start)) continue;
                    if (view_end.isBefore(e.start)) continue;
                    drawSingleEvent(sf, e);
                }
            },
            .pattern => |p| {
                if (p.sun) drawSingleEvent(sf, event.atWeekday(.Sunday));
                if (p.mon) drawSingleEvent(sf, event.atWeekday(.Monday));
                if (p.tue) drawSingleEvent(sf, event.atWeekday(.Tuesday));
                if (p.wed) drawSingleEvent(sf, event.atWeekday(.Wednesday));
                if (p.thu) drawSingleEvent(sf, event.atWeekday(.Thursday));
                if (p.fri) drawSingleEvent(sf, event.atWeekday(.Friday));
                if (p.sat) drawSingleEvent(sf, event.atWeekday(.Saturday));
            },
        }
    } else {
        drawSingleEvent(sf, event);
    }
}

pub fn drawWeek(sf: Surface, events: []Event, now: Date) void {
    const renderer = sf.renderer;
    _ = c.SDL_SetRenderTarget(renderer, sf.tex);
    arc.setColor(renderer, background_color);
    _ = c.SDL_RenderClear(renderer);

    drawGrid(sf);

    arc.setColor(renderer, divider_color);
    for (0..7) |i| {
        const x = xFromWeekday(@intCast(i), sf.w);
        _ = c.SDL_RenderDrawLineF(renderer, x, 0, x, sf.h);
    }

    for (events) |e| {
        drawEvent(sf, e, now);
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
