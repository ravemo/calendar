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

const Database = @import("cli/database.zig").Database;

const scrn_w = 800;
const scrn_h = 600;

fn callback(events_ptr: ?*anyopaque, argc: c_int, argv: [*c][*c]u8, cols: [*c][*c]u8) callconv(.C) c_int {
    const events: *std.ArrayList(Event) = @alignCast(@ptrCast(events_ptr));
    const allocator = events.allocator;
    var id: i32 = undefined;
    var name: []const u8 = undefined;
    var start: Date = undefined;
    var end: calendar.Deadline = undefined;
    var repeat: ?calendar.RepeatInfo = null;

    for (0..@intCast(argc)) |i| {
        const col = std.mem.span(cols[i]);
        const val = if (argv[i]) |v| std.mem.span(v) else null;
        if (std.mem.eql(u8, col, "Id")) {
            id = std.fmt.parseInt(i32, val.?, 10) catch return -1;
        } else if (std.mem.eql(u8, col, "Name")) {
            name = allocator.dupe(u8, val.?) catch return -1;
        } else if (std.mem.eql(u8, col, "Start")) {
            start = Date.fromString(val.?) catch return -1;
        } else if (std.mem.eql(u8, col, "End")) {
            end = calendar.Deadline.fromString(val.?) catch return -1;
        } else if (std.mem.eql(u8, col, "Repeat")) {
            if (val) |v| {
                repeat = calendar.RepeatInfo.fromString(v) catch return -1;
            }
        }
    }
    events.append(Event.init(allocator, id, name, start, end, repeat) catch return -1) catch return -1;
    std.debug.print("Loaded {} events.\n", .{events.items.len});
    return 0;
}

fn loadEvents(allocator: std.mem.Allocator, db: Database) !std.ArrayList(Event) {
    var events = std.ArrayList(Event).init(allocator);
    const query = try std.fmt.allocPrintZ(
        allocator,
        "SELECT * FROM Events;",
        .{},
    );
    defer allocator.free(query);

    try db.executeCB(query, callback, &events);
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

    const db = try Database.init("calendar.db");
    var events = try loadEvents(allocator, db);
    events = events;

    var hours_surface = Surface.init(allocator, renderer, 0, 96, 64, scrn_h - 96);
    var days_surface = Surface.init(allocator, renderer, 64, 0, scrn_w - 64, 96);
    var week_surface = Surface.init(allocator, renderer, 64, 96, scrn_w - 64, scrn_h - 96);
    defer hours_surface.deinit();
    defer days_surface.deinit();
    defer week_surface.deinit();

    var dragging_event: ?*Event = null;
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
                    else => {},
                },
                c.SDL_MOUSEBUTTONDOWN => {
                    if (week_surface.getEventRectBelow(ev.button.x, ev.button.y)) |er| {
                        for (events.items) |*e| {
                            if (e.id == er.evid) {
                                std.debug.print("{}\n", .{er.evid});
                                dragging_start_x = ev.button.x;
                                dragging_start_y = ev.button.y;
                                dragging_event = e;
                                original_dragging_event = e.*;
                                break;
                            }
                        }
                    }
                },
                c.SDL_MOUSEBUTTONUP => {
                    dragging_event = null;
                },
                c.SDL_MOUSEMOTION => {
                    if (dragging_event) |ev_ptr| {
                        const x0 = week_surface.x;
                        const y0 = week_surface.y;
                        const mx: f32 = @floatFromInt(ev.button.x);
                        const my: f32 = @floatFromInt(ev.button.y);
                        const oev = original_dragging_event.?;
                        const new_day = draw.weekdayFromX(mx - x0, week_surface.w);
                        const new_hr = draw.hourFromY(my - y0, week_surface.h);

                        const old_day = draw.weekdayFromX(@as(f32, @floatFromInt(dragging_start_x)) - x0, week_surface.w);
                        const old_hr = draw.hourFromY(@as(f32, @floatFromInt(dragging_start_y)) - y0, week_surface.h);

                        const d_day = new_day - old_day;
                        const d_hr = new_hr - old_hr;

                        ev_ptr.start.setDay(oev.start.getDay() + d_day);
                        ev_ptr.start.setHourF(oev.start.getHourF() + d_hr);
                        switch (ev_ptr.end) {
                            .date => |*d| {
                                const last_d = oev.end.date;
                                d.setDay(last_d.getDay() + d_day);
                                d.setHourF(last_d.getHourF() + d_hr);
                            },
                            .time => return error.TODO,
                        }
                    }
                },
                else => {},
            }
        }

        // Drawing

        try draw.drawWeek(&week_surface, events.items, Date.now());
        draw.drawHours(&hours_surface, Date.now());
        draw.drawDays(&days_surface, Date.now());

        _ = c.SDL_SetRenderDrawColor(renderer, 0xFF, 0xEE, 0xFF, 0xFF);
        _ = c.SDL_RenderClear(renderer);
        week_surface.draw();
        days_surface.draw();
        hours_surface.draw();

        c.SDL_RenderPresent(renderer);
    }
}

fn sdlPanic() noreturn {
    const str = @as(?[*:0]const u8, c.SDL_GetError()) orelse "unknown error";
    @panic(std.mem.sliceTo(str, 0));
}
