const std = @import("std");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
});

const datetime = @import("lib/datetime.zig");
const StringError = datetime.StringError;
const Date = datetime.Date;
const Time = datetime.Time;
const Period = datetime.Period;
const event_lib = @import("lib/event.zig");
const Event = event_lib.Event;
const EventList = event_lib.EventList;
const EventIterator = event_lib.EventIterator;

const draw = @import("lib/draw.zig");
const Renderer = draw.Renderer;
const Tooltip = draw.Tooltip;
const Surface = @import("lib/surface.zig").Surface;
const WeekView = @import("lib/weekview.zig").WeekView;

const Database = @import("lib/database.zig").Database;

const task = @import("lib/task.zig");
const Task = task.Task;
const TaskList = task.TaskList;
const Scheduler = @import("lib/scheduler.zig").Scheduler;
const commands_lib = @import("cli/commands.zig");
const AddCmd = commands_lib.AddCmd;
const RmCmd = commands_lib.RmCmd;

const text = @import("lib/text.zig");
const arc = @import("lib/arc.zig");

var scrn_w: f32 = 800;
var scrn_h: f32 = 600;

var wakeEvent: u32 = undefined;

fn intersects(x: i32, y: i32, rect: c.SDL_Rect) bool {
    return x >= rect.x and x <= rect.x + rect.w and
        y >= rect.y and y <= rect.y + rect.h;
}

fn getDeltaDate(sf: Surface, x0: f32, y0: f32, x1: f32, y1: f32) struct { day: i32, hour: f32 } {
    const d_day: i32 = sf.weekdayFromX(x1) - sf.weekdayFromX(x0);
    const d_hr: f32 = sf.hourFromY(y1) - sf.hourFromY(y0);
    return .{
        .day = d_day,
        .hour = @round(d_hr * 4) / 4,
    };
}

test "delta time" {
    const sf = Surface.init(null, 0, 0, 60, 40);
    const d = getDeltaDate(sf, 15, 20, 15, 20);
    try std.testing.expectEqual(0, d.day);
    try std.testing.expectEqual(0, d.hour);
}

fn resetZoomTo(sf: *Surface, hourF: f32) void {
    sf.zoom = 0;
    sf.zoomIn(60);
    sf.sy = 0;
    const sy = sf.h / 2 - sf.yFromHour(hourF);
    sf.scroll(sy);
}

fn resetZoom(sf: *Surface) void {
    const last_hour_center = sf.hourFromY(sf.h / 2);
    resetZoomTo(sf, last_hour_center);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .enable_memory_limit = true,
    }){ .requested_memory_limit = 1024 * 1024 * 10 };
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();

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
    var events = try EventList.init(alloc, events_db);
    defer events.deinit();
    var base_tasks = try TaskList.init(alloc, tasks_db);
    defer base_tasks.deinit();
    try base_tasks.sanitize();

    var scheduler = try Scheduler.init(alloc, events.events.items, base_tasks, Date.now());
    defer scheduler.deinit();
    var display_tasks = try scheduler.scheduleTasks(&base_tasks);
    defer display_tasks.deinit();

    var hours_surface = Surface.init(renderer, 0, 96, 64, scrn_h - 96);
    var days_surface = Surface.init(renderer, 64, 0, scrn_w - 64, 96);
    var weekview = WeekView.init(alloc, renderer, scrn_w, scrn_h);
    defer hours_surface.deinit();
    defer days_surface.deinit();
    defer weekview.deinit();

    resetZoom(&hours_surface);
    resetZoom(&weekview.sf);

    var selected_event: ?*Event = null;
    var dragging_event: ?*Event = null;
    var is_dragging_end = false; // Whether you are dragging the start of the event or the end
    var original_dragging_event: ?Event = null;
    var dragging_start_x: f32 = undefined;
    var dragging_start_y: f32 = undefined;

    {
        var wake_event = std.mem.zeroes(c.SDL_Event);
        wake_event.type = wakeEvent;
        _ = c.SDL_PushEvent(&wake_event);
    }

    var update = false;

    var cursor = Date.now();
    var tooltip_text: []const u8 = undefined;
    var tooltip: ?Tooltip = null;

    const RepeatOption = enum { Once, Daily, Weekly, Monthly };
    const repeat_option_count = @typeInfo(RepeatOption).Enum.fields.len;
    var repeat_option: RepeatOption = .Once;
    var textbox_text = std.ArrayList(u8).init(alloc);
    defer textbox_text.deinit();
    var show_popup: bool = false;
    const popup_window_rect: c.SDL_Rect = .{
        .x = @as(i32, @intFromFloat(scrn_w / 2)) - 50,
        .y = @as(i32, @intFromFloat(scrn_h / 2)) - 50,
        .w = 100,
        .h = 100,
    };
    const popup_textbox_rect: c.SDL_Rect = .{
        .x = @as(i32, @intFromFloat(scrn_w / 2)) - 40,
        .y = @as(i32, @intFromFloat(scrn_h / 2)) - 40,
        .w = 80,
        .h = 20,
    };
    var popup_radio_rects: [repeat_option_count]c.SDL_Rect = undefined;
    for (0..repeat_option_count) |i| {
        const sep: i32 = @divFloor(80, repeat_option_count);
        popup_radio_rects[i] = .{
            .x = @as(i32, @intFromFloat(scrn_w / 2)) - 35 + @as(i32, @intCast(i)) * sep,
            .y = @as(i32, @intFromFloat(scrn_h / 2)) - 5,
            .w = 10,
            .h = 10,
        };
    }
    const popup_button_rect: c.SDL_Rect = .{
        .x = @as(i32, @intFromFloat(scrn_w / 2)) - 30,
        .y = @as(i32, @intFromFloat(scrn_h / 2)) + 20,
        .w = 60,
        .h = 20,
    };

    c.SDL_StopTextInput();
    mainLoop: while (true) {
        // Control
        var ev: c.SDL_Event = undefined;

        _ = c.SDL_WaitEvent(&ev);
        const keystates = c.SDL_GetKeyboardState(null);
        while (true) {
            switch (ev.type) {
                c.SDL_QUIT => break :mainLoop,
                c.SDL_TEXTINPUT => {
                    for (ev.text.text) |char| {
                        if (char == 0) break;
                        try textbox_text.append(char);
                    }
                },
                c.SDL_KEYDOWN => if (!show_popup) switch (ev.key.keysym.scancode) {
                    c.SDL_SCANCODE_Q => break :mainLoop,
                    c.SDL_SCANCODE_COMMA, c.SDL_SCANCODE_PERIOD => |sc| {
                        if (ev.key.keysym.mod & c.KMOD_SHIFT != 0) {
                            // tmp = 0 if comma, 1 if period
                            const tmp: i32 = @intCast(sc - c.SDL_SCANCODE_COMMA);
                            const d_weeks = tmp * 2 - 1;
                            weekview.start = weekview.start.after(.{ .weeks = d_weeks });
                        }
                    },
                    c.SDL_SCANCODE_F5 => update = true,
                    c.SDL_SCANCODE_Z => {
                        update = true;
                        resetZoomTo(&hours_surface, Date.now().getHourF());
                        resetZoomTo(&weekview.sf, Date.now().getHourF());
                    },
                    c.SDL_SCANCODE_A => {},
                    c.SDL_SCANCODE_DELETE => {
                        if (selected_event) |se| {
                            update = true;
                            try RmCmd.remove(&events_db, se.id);
                            events.remove(se.id);
                        }
                    },
                    else => {},
                },
                c.SDL_KEYUP => if (!show_popup) switch (ev.key.keysym.scancode) {
                    c.SDL_SCANCODE_A => {
                        textbox_text.clearRetainingCapacity();
                        c.SDL_StartTextInput();
                        show_popup = true;
                    },
                    else => {},
                },
                c.SDL_MOUSEBUTTONDOWN => blk: {
                    if (show_popup) {
                        if (!intersects(ev.button.x, ev.button.y, popup_window_rect)) {
                            // cancel everything that was done
                            show_popup = false;
                            c.SDL_StopTextInput();
                        } else {
                            for (popup_radio_rects, 0..) |rect, i| {
                                if (intersects(ev.button.x, ev.button.y, rect)) {
                                    repeat_option = @enumFromInt(i);
                                    break;
                                }
                            }
                            if (intersects(ev.button.x, ev.button.y, popup_button_rect)) {
                                update = true;
                                const start_date = cursor;
                                const end_date = cursor.after(.{ .hours = 2 });
                                const period = switch (repeat_option) {
                                    .Once => null,
                                    .Daily => Period{ .time = Time{ .days = 1 } },
                                    .Weekly => Period{ .time = Time{ .weeks = 1 } },
                                    .Monthly => Period{ .time = Time{ .weeks = 4 } },
                                };
                                try AddCmd.createEvent(&events_db, alloc, textbox_text.items, start_date, end_date, period);
                                show_popup = false;
                                c.SDL_StopTextInput();
                            }
                            break :blk;
                        }
                    }

                    if (tooltip) |_| {
                        alloc.free(tooltip_text);
                        tooltip = null;
                    }
                    if (keystates[c.SDL_SCANCODE_LCTRL] != 0x00) {
                        const x = @as(f32, @floatFromInt(ev.button.x)) - weekview.sf.w / 7 / 2 - weekview.sf.x;
                        const y = @as(f32, @floatFromInt(ev.button.y)) - weekview.sf.y;
                        const h = @round(4 * weekview.sf.hourFromY(y)) / 4.0;
                        cursor.setHourF(h);
                        cursor.setWeekday(@enumFromInt(weekview.sf.weekdayFromX(x)));
                        cursor.update();
                    } else if (weekview.getEventRectBelow(ev.button.x, ev.button.y)) |er| {
                        for (events.events.items) |*e| {
                            if (e.id != er.id) continue;
                            dragging_start_x = @floatFromInt(ev.button.x);
                            dragging_start_y = @floatFromInt(ev.button.y);
                            dragging_event = e;
                            original_dragging_event = e.*;
                            break;
                        }
                    }
                },
                c.SDL_MOUSEBUTTONUP => {
                    selected_event = null;
                    if (dragging_event) |e_ptr| {
                        const mx: f32 = @floatFromInt(ev.motion.x);
                        const my: f32 = @floatFromInt(ev.motion.y);
                        const d = getDeltaDate(weekview.sf, dragging_start_x, dragging_start_y, mx, my);
                        if (d.day == 0 and d.hour == 0.0) {
                            selected_event = e_ptr;
                        } else {
                            try events_db.updateEvent(alloc, e_ptr.*);
                        }
                        dragging_event = null;
                    }
                },
                c.SDL_MOUSEMOTION => {
                    if (dragging_event) |ev_ptr| {
                        const mx: f32 = @floatFromInt(ev.motion.x);
                        const my: f32 = @floatFromInt(ev.motion.y);
                        var d = getDeltaDate(weekview.sf, dragging_start_x, dragging_start_x, mx, my);

                        const oev = original_dragging_event.?;
                        if (is_dragging_end) {
                            d.hour = d.hour + @as(f32, @floatFromInt(d.day)) * 24;
                            ev_ptr.duration = oev.duration.add(Time.initHF(d.hour));
                            if (ev_ptr.duration.shorterThan(.{ .minutes = 15 })) {
                                ev_ptr.duration = .{ .minutes = 15 };
                            }
                        } else { // if dragging the end point of the event
                            ev_ptr.start.setDay(oev.start.getDay() + d.day);
                            ev_ptr.start.setHourF(oev.start.getHourF() + d.hour);
                        }
                    } else {
                        if (tooltip) |_| {
                            alloc.free(tooltip_text);
                            tooltip = null;
                        }
                        c.SDL_SetCursor(normal_cursor);
                        if (weekview.getEventRectBelow(ev.motion.x, ev.motion.y)) |er| {
                            is_dragging_end = weekview.isHoveringEnd(ev.motion.x, ev.motion.y, er);
                            c.SDL_SetCursor(if (is_dragging_end) sizens_cursor else hand_cursor);
                        } else if (weekview.getTaskRectBelow(ev.motion.x, ev.motion.y)) |tr| {
                            const t = base_tasks.getById(tr.id).?;
                            tooltip_text = if (t.parent) |parent|
                                try std.fmt.allocPrint(alloc, "Parent ({}): {s}\n{}: {s}\n", .{ parent, base_tasks.getById(parent).?.name, t.id, t.name })
                            else
                                try std.fmt.allocPrint(alloc, "{}: {s}\n", .{ t.id, t.name });
                            tooltip = .{
                                .text = tooltip_text,
                                .x = ev.motion.x,
                                .y = ev.motion.y,
                            };
                        }
                    }
                },
                c.SDL_MOUSEWHEEL => {
                    if (keystates[c.SDL_SCANCODE_LSHIFT] != 0x00) {
                        hours_surface.zoomIn(ev.wheel.preciseY * 3);
                        weekview.sf.zoomIn(ev.wheel.preciseY * 3);
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
                            weekview = WeekView.init(alloc, renderer, scrn_w, scrn_h);
                            resetZoom(&hours_surface);
                            resetZoom(&weekview.sf);
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
            events.deinit();
            events = try EventList.init(alloc, events_db);
            base_tasks.deinit();
            base_tasks = try TaskList.init(alloc, tasks_db);
            try base_tasks.sanitize();
            try scheduler.reset(events.events.items, base_tasks, Date.now());
            display_tasks.deinit();
            display_tasks = try scheduler.scheduleTasks(&base_tasks);
            cursor = Date.now();
            c.SDL_SetCursor(normal_cursor);
            update = false;
        }

        // Drawing

        var events_it = try EventIterator.init(alloc, events.events.items, weekview.start);
        defer events_it.deinit();
        try draw.drawWeek(&weekview, &events_it, display_tasks.tasks.items, Date.now(), cursor, selected_event);
        draw.drawHours(hours_surface, Date.now());
        draw.drawDays(days_surface, weekview.start);

        _ = c.SDL_SetRenderDrawColor(renderer, 0xFF, 0xEE, 0xFF, 0xFF);
        _ = c.SDL_RenderClear(renderer);
        weekview.sf.draw();
        days_surface.draw();
        hours_surface.draw();

        if (tooltip) |tt| try tt.draw(renderer);

        if (show_popup) {
            _ = c.SDL_SetRenderDrawColor(renderer, 0xEE, 0xEE, 0xEE, 0xFF);
            _ = c.SDL_RenderFillRect(renderer, &popup_window_rect);

            _ = c.SDL_SetRenderDrawColor(renderer, 0xFF, 0xFF, 0xFF, 0xFF);
            _ = c.SDL_RenderFillRect(renderer, &popup_textbox_rect);
            arc.setColor(renderer, arc.colorFromHex(0x000000FF));
            text.drawText(
                renderer,
                textbox_text.items,
                @floatFromInt(popup_textbox_rect.x),
                @floatFromInt(popup_textbox_rect.y),
                @floatFromInt(popup_textbox_rect.w),
                @floatFromInt(popup_textbox_rect.h),
                .Left,
                .Top,
            );

            for (popup_radio_rects, 0..) |r, i| {
                if (i == @intFromEnum(repeat_option)) {
                    arc.setColor(renderer, arc.colorFromHex(0x000000FF));
                } else {
                    arc.setColor(renderer, arc.colorFromHex(0xFFFFFFFF));
                }
                _ = c.SDL_RenderFillRect(renderer, &r);
            }

            _ = c.SDL_SetRenderDrawColor(renderer, 0xDF, 0xDF, 0xDF, 0xFF);
            _ = c.SDL_RenderFillRect(renderer, &popup_button_rect);
        }

        c.SDL_RenderPresent(renderer);
    }
    if (tooltip) |_| {
        alloc.free(tooltip_text);
        tooltip = null;
    }
}

fn sdlPanic() noreturn {
    const str = @as(?[*:0]const u8, c.SDL_GetError()) orelse "unknown error";
    @panic(std.mem.sliceTo(str, 0));
}

test {
    std.testing.refAllDecls(@This());
}
