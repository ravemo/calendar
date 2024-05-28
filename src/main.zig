const std = @import("std");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
});

const datetime = @import("lib/datetime.zig");
const StringError = datetime.StringError;
const Date = datetime.Date;
const Time = datetime.Time;
const event_lib = @import("lib/event.zig");
const Event = event_lib.Event;
const EventIterator = event_lib.EventIterator;

const draw = @import("lib/draw.zig");
const Renderer = draw.Renderer;
const Surface = @import("lib/surface.zig").Surface;
const WeekView = @import("lib/weekview.zig").WeekView;

const Database = @import("lib/database.zig").Database;

const task = @import("lib/task.zig");
const Task = task.Task;
const TaskList = task.TaskList;
const Scheduler = @import("lib/scheduler.zig").Scheduler;

var scrn_w: f32 = 800;
var scrn_h: f32 = 600;

var wakeEvent: u32 = undefined;
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // SDL-related stuff
    if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS) < 0)
        sdlPanic();

    defer c.SDL_Quit();
    if (c.TTF_Init() < 0)
        sdlPanic();
    defer c.TTF_Quit();

    const window = c.SDL_CreateWindow(
        "Calendar",
        c.SDL_WINDOWPOS_CENTERED,
        c.SDL_WINDOWPOS_CENTERED,
        @intFromFloat(scrn_w),
        @intFromFloat(scrn_h),
        c.SDL_WINDOW_SHOWN, // | c.SDL_WINDOW_RESIZABLE,
    ) orelse sdlPanic();
    defer _ = c.SDL_DestroyWindow(window);

    const renderer = c.SDL_CreateRenderer(window, -1, c.SDL_RENDERER_ACCELERATED | c.SDL_RENDERER_PRESENTVSYNC) orelse sdlPanic();
    defer _ = c.SDL_DestroyRenderer(renderer);
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
    const normal_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_ARROW);
    const wait_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_WAIT);
    const hand_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_HAND);
    const sizens_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_SIZENS);

    wakeEvent = c.SDL_RegisterEvents(1);

    var events_db = try Database.init("calendar.db");
    defer events_db.deinit();
    // TODO: Use proper user_data_dir-like function when releasing to the public
    const tasks_db = try Database.init("/home/victor/.local/share/scrytask/tasks.db");
    defer tasks_db.deinit();
    const events = try event_lib.loadEvents(allocator, events_db);
    var base_tasks = try TaskList.init(allocator, tasks_db);
    defer base_tasks.deinit();
    try base_tasks.sanitize();

    var scheduler = try Scheduler.init(allocator, events.items, base_tasks);
    defer scheduler.deinit();
    var tasks = try scheduler.scheduleTasks(base_tasks);

    var hours_surface = Surface.init(renderer, 0, 96, 64, scrn_h - 96);
    var days_surface = Surface.init(renderer, 64, 0, scrn_w - 64, 96);
    var weekview = WeekView.init(allocator, renderer, scrn_w, scrn_h);
    defer hours_surface.deinit();
    defer days_surface.deinit();
    defer weekview.deinit();

    {
        const initial_zoom: f32 = 30;
        hours_surface.zoomIn(initial_zoom);
        weekview.sf.zoomIn(initial_zoom);
        const z = 1 / hours_surface.getScale();
        const sy = z * draw.yFromHour(Date.now().getHourF(), hours_surface.h) - hours_surface.h / 2;
        hours_surface.scroll(-sy);
        weekview.sf.scroll(-sy);
    }

    var dragging_event: ?*Event = null;
    var is_dragging_end = false; // Whether you are dragging the start of the event or the end
    var original_dragging_event: ?Event = null;
    var dragging_start_x: i32 = undefined;
    var dragging_start_y: i32 = undefined;

    var holding_shift = false;

    {
        var wake_event = std.mem.zeroes(c.SDL_Event);
        wake_event.type = wakeEvent;
        _ = c.SDL_PushEvent(&wake_event);
    }

    var update = false;
    mainLoop: while (true) {
        // Control
        var ev: c.SDL_Event = undefined;

        _ = c.SDL_WaitEvent(&ev);
        while (true) {
            switch (ev.type) {
                c.SDL_QUIT => break :mainLoop,
                c.SDL_KEYDOWN => switch (ev.key.keysym.scancode) {
                    c.SDL_SCANCODE_Q => break :mainLoop,
                    c.SDL_SCANCODE_COMMA, c.SDL_SCANCODE_PERIOD => |sc| {
                        if (ev.key.keysym.mod & c.KMOD_SHIFT != 0) {
                            // tmp = 0 if comma, 1 if period
                            const tmp: i32 = @intCast(sc - c.SDL_SCANCODE_COMMA);
                            const d_weeks = tmp * 2 - 1;
                            weekview.start = weekview.start.after(.{ .weeks = d_weeks });
                        }
                    },
                    c.SDL_SCANCODE_LSHIFT => holding_shift = true,
                    c.SDL_SCANCODE_F5 => update = true,
                    else => {
                        std.debug.print("Unhandled key: {}\n", .{ev.key.keysym.scancode});
                    },
                },
                c.SDL_KEYUP => switch (ev.key.keysym.scancode) {
                    c.SDL_SCANCODE_LSHIFT => holding_shift = false,
                    else => {},
                },
                c.SDL_MOUSEBUTTONDOWN => {
                    if (weekview.getEventRectBelow(ev.button.x, ev.button.y)) |er| {
                        for (events.items) |*e| {
                            if (e.id != er.evid) continue;
                            dragging_start_x = ev.button.x;
                            dragging_start_y = ev.button.y;
                            dragging_event = e;
                            original_dragging_event = e.*;
                            break;
                        }
                    }
                },
                c.SDL_MOUSEBUTTONUP => {
                    if (dragging_event) |e_ptr| {
                        try events_db.updateEvent(allocator, e_ptr.*);
                        dragging_event = null;
                    }
                },
                c.SDL_MOUSEMOTION => {
                    if (dragging_event) |ev_ptr| {
                        const x0 = weekview.sf.x;
                        const y0 = weekview.sf.y;
                        const scale = weekview.sf.getScale();
                        const mx: f32 = @floatFromInt(ev.motion.x);
                        const my: f32 = @floatFromInt(ev.motion.y);
                        const oev = original_dragging_event.?;
                        const new_day = draw.weekdayFromX(mx - x0, weekview.sf.w);
                        const new_hr = scale * draw.hourFromY(my - y0, weekview.sf.h);

                        const old_day = draw.weekdayFromX(@as(f32, @floatFromInt(dragging_start_x)) - x0, weekview.sf.w);
                        const old_hr = scale * draw.hourFromY(@as(f32, @floatFromInt(dragging_start_y)) - y0, weekview.sf.h);

                        const d_day: i32 = new_day - old_day;
                        var d_hr: f32 = new_hr - old_hr;
                        d_hr = @round(d_hr * 2) / 2; // Move in steps of 30 minutes

                        if (is_dragging_end) {
                            d_hr = d_hr + @as(f32, @floatFromInt(d_day)) * 24;
                            ev_ptr.duration = oev.duration.add(Time.initHF(d_hr));
                            if (ev_ptr.duration.shorterThan(.{ .minutes = 30 })) {
                                ev_ptr.duration = .{ .minutes = 30 };
                            }
                        } else { // if dragging the end point of the event
                            ev_ptr.start.setDay(oev.start.getDay() + d_day);
                            ev_ptr.start.setHourF(oev.start.getHourF() + d_hr);
                        }
                    } else {
                        if (weekview.getEventRectBelow(ev.motion.x, ev.motion.y)) |er| {
                            is_dragging_end = weekview.isHoveringEnd(ev.motion.x, ev.motion.y, er);
                            c.SDL_SetCursor(if (is_dragging_end) sizens_cursor else hand_cursor);
                        } else {
                            c.SDL_SetCursor(normal_cursor);
                        }
                    }
                },
                c.SDL_MOUSEWHEEL => {
                    if (holding_shift) {
                        hours_surface.zoomIn(ev.wheel.preciseY);
                        weekview.sf.zoomIn(ev.wheel.preciseY);
                    } else {
                        hours_surface.scroll(ev.wheel.preciseY * 20);
                        weekview.sf.scroll(ev.wheel.preciseY * 20);
                    }
                },
                c.SDL_WINDOWEVENT => {
                    switch (ev.window.event) {
                        c.SDL_WINDOWEVENT_RESIZED, c.SDL_WINDOWEVENT_SIZE_CHANGED => {
                            const new_scrn_w = ev.window.data1;
                            const new_scrn_h = ev.window.data2;
                            scrn_w = @floatFromInt(new_scrn_w);
                            scrn_h = @floatFromInt(new_scrn_h);
                            hours_surface.deinit();
                            days_surface.deinit();
                            weekview.deinit();
                            hours_surface = Surface.init(renderer, 0, 96, 64, scrn_h - 96);
                            days_surface = Surface.init(renderer, 64, 0, scrn_w - 64, 96);
                            weekview = WeekView.init(allocator, renderer, scrn_w, scrn_h);
                        },
                        else => {},
                    }
                },
                else => {},
            }
            if (c.SDL_PollEvent(&ev) == 0) break;
        }

        if (update) {
            c.SDL_SetCursor(wait_cursor);
            base_tasks.deinit();
            base_tasks = try TaskList.init(allocator, tasks_db);
            try base_tasks.sanitize();
            try scheduler.reset(events.items, base_tasks);
            tasks = try scheduler.scheduleTasks(base_tasks);
            c.SDL_SetCursor(normal_cursor);
            update = false;
        }

        // Drawing

        var events_it = try EventIterator.init(allocator, events.items, weekview.start);
        try draw.drawWeek(&weekview, &events_it, tasks.tasks.items, Date.now());
        draw.drawHours(hours_surface, Date.now());
        draw.drawDays(days_surface, weekview.start);

        _ = c.SDL_SetRenderDrawColor(renderer, 0xFF, 0xEE, 0xFF, 0xFF);
        _ = c.SDL_RenderClear(renderer);
        weekview.sf.draw();
        days_surface.draw();
        hours_surface.draw();

        c.SDL_RenderPresent(renderer);
    }
}

fn sdlPanic() noreturn {
    const str = @as(?[*:0]const u8, c.SDL_GetError()) orelse "unknown error";
    @panic(std.mem.sliceTo(str, 0));
}
