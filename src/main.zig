const std = @import("std");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
});

const calendar = @import("lib/event.zig");
const StringError = calendar.StringError;
const Event = calendar.Event;
const Date = calendar.Date;
const Time = calendar.Time;

const draw = @import("lib/draw.zig");
const Renderer = draw.Renderer;
const Surface = @import("lib/surface.zig").Surface;
const WeekView = @import("lib/weekview.zig").WeekView;

const Database = @import("cli/database.zig").Database;

const scrn_w = 800;
const scrn_h = 600;

fn load_event_cb(events_ptr: ?*anyopaque, argc: c_int, argv: [*c][*c]u8, cols: [*c][*c]u8) callconv(.C) c_int {
    const events: *std.ArrayList(Event) = @alignCast(@ptrCast(events_ptr));
    const allocator = events.allocator;
    var id: i32 = undefined;
    var name: []const u8 = undefined;
    var start: Date = undefined;
    var end: Date = undefined;
    var has_repeat = false;
    var r_start: ?Date = null;
    var r_end: ?Date = null;
    var repeat: ?calendar.RepeatInfo = null;
    repeat = repeat;

    for (0..@intCast(argc)) |i| {
        const col = std.mem.span(cols[i]);
        const val = if (argv[i]) |v| std.mem.span(v) else null;
        if (std.mem.eql(u8, col, "E_Id")) {
            id = std.fmt.parseInt(i32, val.?, 10) catch return -1;
        } else if (std.mem.eql(u8, col, "Name")) {
            name = allocator.dupe(u8, val.?) catch return -1;
        } else if (std.mem.eql(u8, col, "E_Start")) {
            start = Date.fromString(val.?) catch return -1;
        } else if (std.mem.eql(u8, col, "E_End")) {
            end = calendar.Date.fromString(val.?) catch return -1;
        } else if (std.mem.eql(u8, col, "Repeat")) {
            if (val != null) has_repeat = true;
        } else if (std.mem.eql(u8, col, "R_Start")) {
            if (val) |v| {
                r_start = Date.fromString(v) catch return -1;
            }
        } else if (std.mem.eql(u8, col, "R_End")) {
            if (val) |v|
                r_end = Date.fromString(v) catch return -1;
        } else if (std.mem.eql(u8, col, "Period")) {
            if (val) |v|
                repeat = .{ .period = calendar.Period.fromString(v) catch return -1 };
        }
    }

    if (has_repeat) std.debug.assert(repeat != null);
    if (repeat) |*r| {
        r.start = r_start;
        r.end = r_end;
    }
    events.append(Event.init(allocator, id, name, start, end.timeSince(start), repeat) catch return -1) catch return -1;
    std.debug.print("Loaded {} events.\n", .{events.items.len});
    return 0;
}

fn loadEvents(allocator: std.mem.Allocator, db: Database) !std.ArrayList(Event) {
    var events = std.ArrayList(Event).init(allocator);
    const query = try std.fmt.allocPrintZ(allocator,
        \\ SELECT Events.Id as E_Id, Repeats.Id as R_Id,
        \\        Events.Start as E_Start, Events.End as E_End,
        \\        Repeats.Start as R_Start, Repeats.End as R_End, *
        \\ FROM Events LEFT JOIN Repeats ON Events.Repeat = Repeats.Id;
    , .{});
    defer allocator.free(query);

    try db.executeCB(query, load_event_cb, &events);
    return events;
}

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
        scrn_w,
        scrn_h,
        c.SDL_WINDOW_SHOWN,
    ) orelse sdlPanic();
    defer _ = c.SDL_DestroyWindow(window);

    const renderer = c.SDL_CreateRenderer(window, -1, c.SDL_RENDERER_ACCELERATED | c.SDL_RENDERER_PRESENTVSYNC) orelse sdlPanic();
    defer _ = c.SDL_DestroyRenderer(renderer);

    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);

    const normal_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_ARROW);
    const hand_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_HAND);
    const sizens_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_SIZENS);

    var db = try Database.init("calendar.db");
    var events = try loadEvents(allocator, db);
    events = events;

    var hours_surface = Surface.init(renderer, 0, 96, 64, scrn_h - 96);
    var days_surface = Surface.init(renderer, 64, 0, scrn_w - 64, 96);
    var weekview = WeekView.init(allocator, renderer, scrn_w, scrn_h);
    defer hours_surface.deinit();
    defer days_surface.deinit();
    defer weekview.deinit();

    var dragging_event: ?*Event = null;
    var is_dragging_end = false; // Whether you are dragging the start of the event or the end
    var original_dragging_event: ?Event = null;
    var dragging_start_x: i32 = undefined;
    var dragging_start_y: i32 = undefined;

    mainLoop: while (true) {
        // Control
        var ev: c.SDL_Event = undefined;

        while (c.SDL_PollEvent(&ev) != 0) {
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
                    else => {
                        std.debug.print("Unhandled key: {}\n", .{ev.key.keysym.scancode});
                    },
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
                        try db.updateEvent(allocator, e_ptr.*);
                        dragging_event = null;
                    }
                },
                c.SDL_MOUSEMOTION => {
                    if (dragging_event) |ev_ptr| {
                        const x0 = weekview.sf.x;
                        const y0 = weekview.sf.y;
                        const mx: f32 = @floatFromInt(ev.motion.x);
                        const my: f32 = @floatFromInt(ev.motion.y);
                        const oev = original_dragging_event.?;
                        const new_day = draw.weekdayFromX(mx - x0, weekview.sf.w);
                        const new_hr = draw.hourFromY(my - y0, weekview.sf.h);

                        const old_day = draw.weekdayFromX(@as(f32, @floatFromInt(dragging_start_x)) - x0, weekview.sf.w);
                        const old_hr = draw.hourFromY(@as(f32, @floatFromInt(dragging_start_y)) - y0, weekview.sf.h);

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
                else => {},
            }
        }

        // Drawing

        try draw.drawWeek(&weekview, events.items, Date.now());
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
