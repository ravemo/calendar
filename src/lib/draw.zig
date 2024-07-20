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
const TextRenderer = @import("text.zig").TextRenderer;
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
const selected_event_color = arc.colorFromHex(0x2fc46188);
const TaskColor = enum {
    red,
    orange,
    yellow,
    green,
    blue,
    purple,
    gray,
};
const task_colors: [@typeInfo(TaskColor).Enum.fields.len]arc.Color = .{
    arc.colorFromHex(0xac3232ff),
    arc.colorFromHex(0xeda626ff),
    arc.colorFromHex(0xfbf236ff),
    arc.colorFromHex(0x6abe30ff),
    arc.colorFromHex(0x22acccff),
    arc.colorFromHex(0x76428aff),
    arc.colorFromHex(0x696a6aff),
};
const tooltip_bg_color = arc.colorFromHex(0xd8d888aa);

pub fn drawGrid(sf: Surface) void {
    const renderer = sf.text_renderer.renderer;
    arc.setColor(renderer, grid_color);
    for (0..48) |i| {
        const y: f32 = sf.yFromHour(@as(f32, @floatFromInt(i)) / 2);
        _ = c.SDL_RenderDrawLineF(@ptrCast(renderer), 0, y, sf.w, y);
    }
}

pub fn drawEvent(wv: *WeekView, event: Event, selected: bool) !void {
    const text_renderer = wv.sf.text_renderer;
    const renderer = @as(*c.SDL_Renderer, @ptrCast(text_renderer.renderer));
    // if the event crosses the day boundary, but does not end at midnight
    if (event.start.getDayStart().isBefore(event.getEnd().getDayStart()) and
        !event.getEnd().getDayStart().eql(event.getEnd()))
    {
        const split = event.start.after(.{ .days = 1 }).getDayStart();
        var head = event;
        head.duration = split.timeSince(event.start);
        try drawEvent(wv, head, selected);

        var tail = event;
        tail.start = split;
        tail.duration = tail.duration.sub(head.duration);
        try drawEvent(wv, tail, selected);
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
    if (selected) {
        arc.setColor(renderer, selected_event_color);
    } else {
        arc.setColor(renderer, event_color);
    }
    const rect = c.SDL_FRect{
        .x = x,
        .y = y,
        .w = wv.sf.w / 7 - 5,
        .h = h * wv.sf.h / 24,
    };
    _ = c.SDL_RenderFillRectF(renderer, &rect);

    try wv.eventRects.append(.{ .id = draw_event.id, .rect = rect });

    arc.setColor(renderer, text_color);
    text.drawText(text_renderer, draw_event.name, x + 2, y + 2, rect.w - 4, rect.h - 4, .Left, .Top);
}

pub fn drawTask(wv: *WeekView, task: Task, now: Date, selected: bool) !void {
    _ = now; // TODO: Draw tasks greyed-out if they are already past

    // TODO Check task's start and due to see whether it would even appear on
    // the current week view

    std.debug.assert(task.scheduled_start != null);
    if (!task.getEnd().?.eql(task.getEnd().?.getDayStart()))
        std.debug.assert(task.scheduled_start.?.getDay() == task.getEnd().?.getDay());

    const text_renderer = wv.sf.text_renderer;
    const renderer = @as(*c.SDL_Renderer, @ptrCast(text_renderer.renderer));

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
    const alpha: u8 = if (task.earliest_due != null) 0xFF else 0x80;

    const task_color_enum: TaskColor = if (task.parent != null and task.parent.? == 11)
        .orange
    else
        .blue;
    const task_color = task_colors[@intFromEnum(task_color_enum)];
    const rect = c.SDL_FRect{
        .x = x,
        .y = y + 1,
        .w = wv.sf.w / 7 - 5,
        .h = h * wv.sf.h / 24 - 1,
    };
    if (selected) {
        arc.setColor(renderer, arc.invertColor(task_color));
        _ = c.SDL_RenderFillRectF(renderer, &rect);
        arc.setColor(renderer, arc.setAlpha(task_color, alpha));
        const border = 3;
        const new_rect = c.SDL_FRect{
            .x = rect.x + border,
            .y = rect.y + border,
            .w = rect.w - 2 * border,
            .h = rect.h - 2 * border,
        };
        _ = c.SDL_RenderFillRectF(renderer, &new_rect);
    } else {
        arc.setColor(renderer, arc.setAlpha(task_color, alpha));
        _ = c.SDL_RenderFillRectF(renderer, &rect);
    }
    try wv.taskRects.append(.{ .id = draw_task.id, .rect = rect });

    arc.setColor(renderer, text_color);
    if (rect.h > 20)
        text.drawText(text_renderer, draw_task.name, x + 2, y + 2, rect.w - 4, rect.h - 4, .Left, .Top);
}

pub fn drawWeek(wv: *WeekView, events_it: *EventIterator, tasks: []Task, now: Date, cursor: Date, selected_task: ?*Task, selected_event: ?*Event) !void {
    const text_renderer = wv.sf.text_renderer;
    const renderer = @as(*c.SDL_Renderer, @ptrCast(text_renderer.renderer));
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
    events_it.reset(wv.start);
    while (events_it.next(view_end)) |e|
        try drawEvent(wv, e, selected_event != null and e.id == selected_event.?.id);

    for (tasks) |t|
        try drawTask(wv, t, now, selected_task != null and t.id == selected_task.?.id);

    if (wv.sf.xFromDate(cursor)) |x| {
        const y = wv.sf.yFromHour(cursor.getHourF());
        _ = c.SDL_RenderDrawLineF(renderer, x, y, x + wv.sf.w / 7, y);
    }

    _ = c.SDL_SetRenderTarget(renderer, null);
}

pub fn drawHours(sf: Surface, now: Date) void {
    _ = now;

    const text_renderer = sf.text_renderer;
    const renderer = @as(*c.SDL_Renderer, @ptrCast(text_renderer.renderer));
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
        text.drawText(text_renderer, &buf, sf.w - 20, y, -1, -1, .Right, .Center);
    }

    arc.setColor(renderer, divider_color);
    for (0..24) |i| {
        const y: f32 = sep * @as(f32, @floatFromInt(i)) + sf.sy;
        _ = c.SDL_RenderDrawLineF(renderer, sf.w - 15, y, sf.w, y);
    }
    _ = c.SDL_SetRenderTarget(renderer, null);
}

pub fn drawDays(sf: Surface, now: Date) void {
    const text_renderer = sf.text_renderer;
    const renderer = @as(*c.SDL_Renderer, @ptrCast(text_renderer.renderer));
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
        text.drawText(text_renderer, weekday, x + sf.w / 14, sf.h / 3, -1, -1, .Center, .Center);
        text.drawText(text_renderer, &buf, x + sf.w / 14, 2 * sf.h / 3, -1, -1, .Center, .Center);
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
    text: []const u8,
    x: i32,
    y: i32,

    pub fn draw(self: Self, text_renderer: TextRenderer) !void {
        const renderer = @as(*c.SDL_Renderer, @ptrCast(text_renderer.renderer));
        arc.setColor(renderer, tooltip_bg_color);
        const rect = c.SDL_Rect{
            .x = self.x,
            .y = self.y - 100,
            .w = 200,
            .h = 100,
        };
        _ = c.SDL_RenderFillRect(renderer, &rect);

        arc.setColor(renderer, text_color);
        text.drawText(
            text_renderer,
            self.text,
            @as(f32, @floatFromInt(self.x)) + 5,
            @as(f32, @floatFromInt(self.y)) - 100 + 5,
            @as(f32, @floatFromInt(rect.w)) - 10,
            @as(f32, @floatFromInt(rect.h)) - 10,
            .Left,
            .Top,
        );
    }
};
