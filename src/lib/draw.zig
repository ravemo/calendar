const std = @import("std");
const datetime = @import("datetime.zig");
const Date = datetime.Date;
const DateIter = datetime.DateIter;
const Weekday = datetime.Weekday;
const Time = datetime.Time;
const event_lib = @import("event.zig");
const Event = event_lib.Event;
const EventIterator = event_lib.EventIterator;
const Surface = @import("surface.zig").Surface;
const WeekView = @import("weekview.zig").WeekView;
const Task = @import("task.zig").Task;

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
const task_color = arc.colorFromHex(0x22accc88);
const due_task_color = arc.colorFromHex(0x22acccff);
const tooltip_bg_color = arc.colorFromHex(0xd8d888aa);

pub fn drawGrid(sf: Surface) void {
    const renderer = sf.renderer;
    arc.setColor(renderer, grid_color);
    for (0..48) |i| {
        const y: f32 = sf.yFromHour(@as(f32, @floatFromInt(i)) / 2);
        _ = c.SDL_RenderDrawLineF(renderer, 0, y, sf.w, y);
    }
}

pub fn drawSingleEvent(wv: *WeekView, event: Event) !void {
    const renderer = wv.sf.renderer;
    // if the event crosses the day boundary, but does not end at midnight
    if (event.start.getDayStart().isBefore(event.getEnd().getDayStart()) and
        event.getEnd().getDayStart().secondsSince(event.getEnd()) != 0)
    {
        const split = event.start.after(.{ .days = 1 }).getDayStart();
        var head = event;
        head.duration = split.timeSince(event.start);
        try drawSingleEvent(wv, head);

        var tail = event;
        tail.start = split;
        tail.duration = tail.duration.sub(head.duration);
        try drawSingleEvent(wv, tail);
        return;
    }

    var draw_event = event;
    // if event starts after end of current view or ends before start of current
    // view, don't even draw it
    if (wv.getEnd().isBeforeEq(draw_event.start) or
        draw_event.getEnd().isBeforeEq(wv.start))
        return;
    // If event starts before current view, set start to start of current view
    if (draw_event.start.isBefore(wv.start))
        draw_event.start = wv.start;
    // If event end after current view, set end to end of current view
    if (wv.getEnd().isBefore(draw_event.getEnd()))
        draw_event.duration = wv.getEnd().timeSince(draw_event.start);

    const z = 1 / wv.sf.getScale();
    const h = z * draw_event.duration.getHoursF();

    const x = wv.sf.xFromDate(draw_event.start).? + 3;
    const y = wv.sf.yFromHour(draw_event.start.getHourF());
    arc.setColor(renderer, event_color);
    const rect = c.SDL_FRect{
        .x = x,
        .y = y,
        .w = wv.sf.w / 7 - 5,
        .h = h * wv.sf.h / 24,
    };
    _ = c.SDL_RenderFillRectF(renderer, &rect);

    try wv.eventRects.append(.{ .id = draw_event.id, .rect = rect });

    arc.setColor(renderer, text_color);
    text.drawText(renderer, draw_event.name, x + 2, y + 2, rect.w - 4, .Left, .Top);
}
pub fn drawEvent(wv: *WeekView, event: Event, now: Date) !void {
    _ = now; // TODO: Draw events greyed-out if they are already past
    const view_start = wv.start;
    const view_end = wv.start.after(.{ .weeks = 1 });

    if (event.repeat) |repeat| {
        switch (repeat.period) {
            // TODO: Refactor DateIter so we can support more than weekly repeats
            // Yes. DateIter is not working. You probably have to do the
            // 'repeating task' vs 'normal task' thing.
            // It will be two birds with one stone.
            .time => |_| blk: {
                const e = event.atDay(view_start).atWeekday(@enumFromInt(event.start.getWeekday()));
                if (e.getEnd().isBefore(view_start)) break :blk;
                if (view_end.isBefore(e.start)) break :blk;
                try drawSingleEvent(wv, e);
            },
            .pattern => |p| {
                // TODO use arrays?
                if (p.sun) try drawSingleEvent(wv, event.atWeekday(.Sunday));
                if (p.mon) try drawSingleEvent(wv, event.atWeekday(.Monday));
                if (p.tue) try drawSingleEvent(wv, event.atWeekday(.Tuesday));
                if (p.wed) try drawSingleEvent(wv, event.atWeekday(.Wednesday));
                if (p.thu) try drawSingleEvent(wv, event.atWeekday(.Thursday));
                if (p.fri) try drawSingleEvent(wv, event.atWeekday(.Friday));
                if (p.sat) try drawSingleEvent(wv, event.atWeekday(.Saturday));
            },
        }
    } else {
        try drawSingleEvent(wv, event);
    }
}

pub fn drawSingleTask(wv: *WeekView, task: Task) !void {
    std.debug.assert(task.scheduled_start != null);
    if (!task.getEnd().?.eql(task.getEnd().?.getDayStart()))
        std.debug.assert(task.scheduled_start.?.getDay() == task.getEnd().?.getDay());

    const renderer = wv.sf.renderer;

    if (task.scheduled_start == null) return;

    var draw_task = task;
    var draw_start = &(draw_task.scheduled_start.?);
    // if task starts after end of current view or ends before start of current
    // view, don't even draw it
    if (wv.getEnd().isBeforeEq(draw_start.*) or
        draw_task.getEnd().?.isBeforeEq(wv.start))
        return;
    // If task starts before current view, set start to start of current view
    if (draw_start.isBefore(wv.start))
        draw_start.* = wv.start;
    // If task end after current view, set end to end of current view
    if (wv.getEnd().isBefore(draw_task.getEnd().?))
        draw_task.time = wv.getEnd().timeSince(draw_start.*);
    // TODO: Check if task is visible inside week view

    const z = 1 / wv.sf.getScale();
    const h = z * draw_task.time.getHoursF();

    const x = wv.sf.xFromWeekday(draw_start.getWeekday()) + 3;
    const y = wv.sf.yFromHour(draw_start.getHourF());
    if (task.due != null or task.is_due_dep) {
        arc.setColor(renderer, due_task_color);
    } else {
        arc.setColor(renderer, task_color);
    }
    const rect = c.SDL_FRect{
        .x = x,
        .y = y + 1,
        .w = wv.sf.w / 7 - 5,
        .h = h * wv.sf.h / 24 - 1,
    };
    _ = c.SDL_RenderFillRectF(renderer, &rect);
    try wv.taskRects.append(.{ .id = draw_task.id, .rect = rect });

    arc.setColor(renderer, text_color);
    if (rect.h > 20)
        text.drawText(renderer, draw_task.name, x + 2, y + 2, rect.w - 4, .Left, .Top);
}
pub fn drawTask(wv: *WeekView, task: Task, now: Date) !void {
    _ = now; // TODO: Draw tasks greyed-out if they are already past

    // TODO Check task's start and due to see whether it would even appear on
    // the current week view

    try drawSingleTask(wv, task);
}

pub fn drawWeek(wv: *WeekView, events_it: *EventIterator, tasks: []Task, now: Date, cursor: Date) !void {
    const renderer = wv.sf.renderer;
    _ = c.SDL_SetRenderTarget(renderer, wv.sf.tex);
    arc.setColor(renderer, background_color);
    _ = c.SDL_RenderClear(renderer);
    wv.clearIdRects();

    drawGrid(wv.sf);

    arc.setColor(renderer, divider_color);
    for (0..7) |i| {
        const x = wv.sf.xFromWeekday(@intCast(i));
        _ = c.SDL_RenderDrawLineF(renderer, x, 0, x, wv.sf.h);
    }

    const view_end = wv.start.after(.{ .weeks = 1 });
    while (events_it.next(view_end)) |e|
        try drawEvent(wv, e, now);

    for (tasks) |t|
        try drawTask(wv, t, now);

    if (wv.sf.xFromDate(cursor)) |x| {
        const y = wv.sf.yFromHour(cursor.getHourF());
        _ = c.SDL_RenderDrawLineF(renderer, x, y, x + wv.sf.w / 7, y);
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
    const z = 1 / sf.getScale();
    const sep = z * sf.h / 24;
    for (0..24) |i| {
        const y: f32 = sep * @as(f32, @floatFromInt(i)) + sf.sy;
        var buf: [6:0]u8 = undefined;
        buf = std.mem.bytesToValue([6:0]u8, std.fmt.bufPrintZ(&buf, "{}:00", .{i}) catch "error");
        text.drawText(renderer, &buf, sf.w - 10, y + sep / 2, -1, .Right, .Center);
    }

    arc.setColor(renderer, divider_color);
    for (0..24) |i| {
        const y: f32 = sep * @as(f32, @floatFromInt(i)) + sf.sy;
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

    arc.setColor(renderer, text_color);
    for (0..7, weekdays) |i, weekday| {
        const cur_day = now.getWeekStart().after(.{ .days = @intCast(i) });
        const x: f32 = sf.w * @as(f32, @floatFromInt(i)) / 7;
        var buf: [2:0]u8 = [_:0]u8{ 0, 0 };
        _ = std.fmt.formatIntBuf(&buf, cur_day.getDay(), 10, .lower, .{});
        text.drawText(renderer, weekday, x + sf.w / 14, sf.h / 3, -1, .Center, .Center);
        text.drawText(renderer, &buf, x + sf.w / 14, 2 * sf.h / 3, -1, .Center, .Center);
    }
    arc.setColor(renderer, divider_color);
    for (0..7) |i| {
        const x: f32 = sf.w * @as(f32, @floatFromInt(i)) / 7;
        _ = c.SDL_RenderDrawLineF(renderer, x, sf.h * 3.0 / 4, x, sf.h);
    }
    _ = c.SDL_RenderDrawLineF(renderer, 0, sf.h - 1, sf.w, sf.h - 1);

    _ = c.SDL_SetRenderTarget(renderer, null);
}

pub const Tooltip = struct {
    const Self = @This();
    id: i32,
    text: []const u8,
    x: i32,
    y: i32,

    pub fn draw(self: Self, allocator: std.mem.Allocator, renderer: Renderer) !void {
        arc.setColor(renderer, tooltip_bg_color);
        const rect = c.SDL_Rect{
            .x = self.x,
            .y = self.y - 100,
            .w = 200,
            .h = 100,
        };
        _ = c.SDL_RenderFillRect(renderer, &rect);

        arc.setColor(renderer, text_color);
        var tooltip_text = std.ArrayList(u8).init(allocator);
        defer tooltip_text.deinit();
        try tooltip_text.writer().print("{}: {s}\n", .{ self.id, self.text });
        text.drawText(
            renderer,
            tooltip_text.items,
            @as(f32, @floatFromInt(self.x)) + 5,
            @as(f32, @floatFromInt(self.y)) - 100 + 5,
            200,
            .Left,
            .Top,
        );
    }
};
