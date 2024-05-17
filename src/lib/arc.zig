const std = @import("std");
const sdl = @cImport({
    @cInclude("SDL2/SDL.h");
});

pub const Color = sdl.SDL_Color;

pub fn setColor(renderer: anytype, c: Color) void {
    _ = sdl.SDL_SetRenderDrawColor(@ptrCast(renderer), c.r, c.g, c.b, c.a);
}
pub fn colorFromHex(hex: u32) Color {
    return @bitCast(@byteSwap(@as(u32, hex)));
}

pub fn rgb_from_hsv(h: f32, s: f32, v: f32) Color {
    // h \in [0, 360), s \in [0, 1], v \in [0, 1]
    const c = v * s;
    const h_prime = h / 60;
    const x = c * (1 - @abs(@mod(h_prime, 2) - 1));
    const FColor = struct { r: f32 = 0, g: f32 = 0, b: f32 = 0 };
    var rgb1: FColor = .{};
    // cx0 xc0 0cx 0xc x0c c0x
    if (h_prime < 1) {
        rgb1 = .{ .r = c, .g = x, .b = 0 };
    } else if (h_prime < 2) {
        rgb1 = .{ .r = x, .g = c, .b = 0 };
    } else if (h_prime < 3) {
        rgb1 = .{ .r = 0, .g = c, .b = x };
    } else if (h_prime < 4) {
        rgb1 = .{ .r = 0, .g = x, .b = c };
    } else if (h_prime < 5) {
        rgb1 = .{ .r = x, .g = 0, .b = c };
    } else if (h_prime < 6) {
        rgb1 = .{ .r = c, .g = 0, .b = x };
    }

    const m = v - c;
    return .{
        .r = @intFromFloat(@max(0, @min(@round(255 * (rgb1.r + m)), 255))),
        .g = @intFromFloat(@max(0, @min(@round(255 * (rgb1.g + m)), 255))),
        .b = @intFromFloat(@max(0, @min(@round(255 * (rgb1.b + m)), 255))),
        .a = 0xff,
    };
}

pub fn drawCircle(renderer: anytype, x: i32, y: i32, radius: i32) i32 {
    var offsetx: i32 = 0;
    var offsety: i32 = radius;
    var d: i32 = radius - 1;
    var status: i32 = 0;

    while (offsety >= offsetx) {
        status += sdl.SDL_RenderDrawPoint(renderer, x + offsetx, y + offsety);
        status += sdl.SDL_RenderDrawPoint(renderer, x + offsety, y + offsetx);
        status += sdl.SDL_RenderDrawPoint(renderer, x - offsetx, y + offsety);
        status += sdl.SDL_RenderDrawPoint(renderer, x - offsety, y + offsetx);
        status += sdl.SDL_RenderDrawPoint(renderer, x + offsetx, y - offsety);
        status += sdl.SDL_RenderDrawPoint(renderer, x + offsety, y - offsetx);
        status += sdl.SDL_RenderDrawPoint(renderer, x - offsetx, y - offsety);
        status += sdl.SDL_RenderDrawPoint(renderer, x - offsety, y - offsetx);

        if (status < 0) {
            status = -1;
            break;
        }

        if (d >= 2 * offsetx) {
            d -= 2 * offsetx + 1;
            offsetx += 1;
        } else if (d < 2 * (radius - offsety)) {
            d += 2 * offsety - 1;
            offsety -= 1;
        } else {
            d += 2 * (offsety - offsetx - 1);
            offsety -= 1;
            offsetx += 1;
        }
    }

    return status;
}

pub fn fillCircleF(renderer: anytype, x: f32, y: f32, radius: f32) i32 {
    var offsetx: f32 = 0;
    var offsety: f32 = radius;
    var d: f32 = radius - 1;
    var status: i32 = 0;

    while (offsety >= offsetx) {
        status += sdl.SDL_RenderDrawLineF(renderer, x - offsety, y + offsetx, x + offsety, y + offsetx);
        status += sdl.SDL_RenderDrawLineF(renderer, x - offsetx, y + offsety, x + offsetx, y + offsety);
        status += sdl.SDL_RenderDrawLineF(renderer, x - offsetx, y - offsety, x + offsetx, y - offsety);
        status += sdl.SDL_RenderDrawLineF(renderer, x - offsety, y - offsetx, x + offsety, y - offsetx);

        if (status < 0) {
            status = -1;
            break;
        }

        if (d >= 2 * offsetx) {
            d -= 2 * offsetx + 1;
            offsetx += 1;
        } else if (d < 2 * (radius - offsety)) {
            d += 2 * offsety - 1;
            offsety -= 1;
        } else {
            d += 2 * (offsety - offsetx - 1);
            offsety -= 1;
            offsetx += 1;
        }
    }

    return status;
}

pub fn fillCircle(renderer: anytype, x: i32, y: i32, radius: i32) i32 {
    var offsetx: i32 = 0;
    var offsety: i32 = radius;
    var d: i32 = radius - 1;
    var status: i32 = 0;

    while (offsety >= offsetx) {
        status += sdl.SDL_RenderDrawLine(renderer, x - offsety, y + offsetx, x + offsety, y + offsetx);
        status += sdl.SDL_RenderDrawLine(renderer, x - offsetx, y + offsety, x + offsetx, y + offsety);
        status += sdl.SDL_RenderDrawLine(renderer, x - offsetx, y - offsety, x + offsetx, y - offsety);
        status += sdl.SDL_RenderDrawLine(renderer, x - offsety, y - offsetx, x + offsety, y - offsetx);

        if (status < 0) {
            status = -1;
            break;
        }

        if (d >= 2 * offsetx) {
            d -= 2 * offsetx + 1;
            offsetx += 1;
        } else if (d < 2 * (radius - offsety)) {
            d += 2 * offsety - 1;
            offsety -= 1;
        } else {
            d += 2 * (offsety - offsetx - 1);
            offsety -= 1;
            offsetx += 1;
        }
    }

    return status;
}

pub const Point = struct {
    x: f32,
    y: f32,
    pub fn scale(self: Point, s: f32) Point {
        return .{
            .x = self.x * s,
            .y = self.y * s,
        };
    }
    pub fn add(self: Point, p: Point) Point {
        return .{
            .x = self.x + p.x,
            .y = self.y + p.y,
        };
    }
    pub fn rotate(self: Point, angle: f32) Point {
        const cos = std.math.cos(angle);
        const sin = std.math.sin(angle);
        return .{
            .x = cos * self.x + sin * self.y,
            .y = -cos * self.y + sin * self.x,
        };
    }
};

pub fn drawRotatedRect(renderer: anytype, x: f32, y: f32, w: f32, h: f32, angle: f32) i32 {
    var status: i32 = 0;
    var pos = Point{ .x = x, .y = y };
    var dim = Point{ .x = w, .y = h };
    var alt_dim = Point{ .x = w, .y = -h };
    const corner1 = pos.add(dim.scale(0.5).rotate(angle));
    const corner2 = pos.add(alt_dim.scale(0.5).rotate(angle));
    const corner3 = pos.add(dim.scale(-0.5).rotate(angle));
    const corner4 = pos.add(alt_dim.scale(-0.5).rotate(angle));

    status += sdl.SDL_RenderDrawLine(renderer, @intFromFloat(corner1.x), @intFromFloat(corner1.y), @intFromFloat(corner2.x), @intFromFloat(corner2.y));
    status += sdl.SDL_RenderDrawLine(renderer, @intFromFloat(corner2.x), @intFromFloat(corner2.y), @intFromFloat(corner3.x), @intFromFloat(corner3.y));
    status += sdl.SDL_RenderDrawLine(renderer, @intFromFloat(corner3.x), @intFromFloat(corner3.y), @intFromFloat(corner4.x), @intFromFloat(corner4.y));
    status += sdl.SDL_RenderDrawLine(renderer, @intFromFloat(corner4.x), @intFromFloat(corner4.y), @intFromFloat(corner1.x), @intFromFloat(corner1.y));

    return status;
}
