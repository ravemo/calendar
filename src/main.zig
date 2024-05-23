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
const Surface = draw.Surface;

const Database = @import("cli/database.zig").Database;

const scrn_w = 800;
const scrn_h = 600;

fn callback(events_ptr: ?*anyopaque, argc: c_int, argv: [*c][*c]u8, cols: [*c][*c]u8) callconv(.C) c_int {
    const events: *std.ArrayList(Event) = @alignCast(@ptrCast(events_ptr));
    const allocator = events.allocator;
    var name: []const u8 = undefined;
    var start: Date = undefined;
    var end: calendar.Deadline = undefined;
    var repeat: ?calendar.RepeatInfo = null;

    for (0..@intCast(argc)) |i| {
        const col = std.mem.span(cols[i]);
        const val = if (argv[i]) |v| std.mem.span(v) else null;
        if (std.mem.eql(u8, col, "Id")) {
            // TODO
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
    events.append(Event.init(allocator, name, start, end, repeat) catch return -1) catch return -1;
    std.debug.print("Loaded {} events.\n", .{events.items.len});
    return 0;
}

fn loadEvents(allocator: std.mem.Allocator, db: Database) !std.ArrayList(Event) {
    var events = std.ArrayList(Event).init(allocator);
    std.debug.print("???\n", .{});
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
    try events.append(try Event.init(
        allocator,
        "Dinner",
        Date.todayAt(16, 40),
        .{ .time = .{ .hours = 1, .minutes = 50 } },
        .{ .start = Date.last(.Monday), .period = .{
            .pattern = .{
                .mon = true,
                .tue = true,
                .wed = true,
                .thu = true,
                .fri = true,
                .sat = true,
            },
        } },
    ));
    try events.append(try Event.init(
        allocator,
        "Sleep",
        Date.todayAt(22, 30),
        .{ .time = .{ .hours = 8 } },
        .{ .start = Date.last(.Sunday), .period = .{ .time = .{ .weeks = 1 } } },
    ));

    const hours_surface = Surface.init(renderer, 0, 96, 64, scrn_h - 96);
    const days_surface = Surface.init(renderer, 64, 0, scrn_w - 64, 96);
    const week_surface = Surface.init(renderer, 64, 96, scrn_w - 64, scrn_h - 96);

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
                else => {},
            }
        }

        // Drawing

        draw.drawWeek(week_surface, events.items, Date.now());
        draw.drawHours(hours_surface, Date.now());
        draw.drawDays(days_surface, Date.now());

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
