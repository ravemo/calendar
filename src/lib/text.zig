const std = @import("std");
const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
});

const HAlignment = enum {
    Left,
    Center,
    Right,
};
const VAlignment = enum {
    Top,
    Center,
    Bottom,
};

pub fn drawText(renderer: anytype, label: []const u8, x: f32, y: f32, max_w: f32, h_align: HAlignment, v_align: VAlignment) void {
    const allocator = std.heap.page_allocator;
    const new_label = allocator.dupeZ(u8, label) catch "ERROR";
    drawTextZ(renderer, new_label, x, y, max_w, h_align, v_align);
}
pub fn drawTextZ(renderer: anytype, label: [:0]const u8, x: f32, y: f32, max_w: f32, h_align: HAlignment, v_align: VAlignment) void {
    const size = 14;

    const font = c.TTF_OpenFont("data/Mecha.ttf", size);
    defer c.TTF_CloseFont(font);
    std.debug.assert(font != null);

    var color: c.SDL_Color = undefined;
    _ = c.SDL_GetRenderDrawColor(renderer, &color.r, &color.g, &color.b, &color.a);

    const text_surface = if (max_w < 0)
        c.TTF_RenderUTF8_Blended(font, label, color)
    else
        c.TTF_RenderUTF8_Blended_Wrapped(font, label, color, @intFromFloat(max_w));
    if (label.len == 0)
        return;
    defer c.SDL_FreeSurface(text_surface);
    std.debug.assert(text_surface != null);

    const text_texture = c.SDL_CreateTextureFromSurface(@ptrCast(renderer), text_surface);
    defer c.SDL_DestroyTexture(text_texture);
    std.debug.assert(text_texture != null);
    const w = text_surface.*.w;
    const h = text_surface.*.h;

    const draw_x = switch (h_align) {
        .Right => @as(i32, @intFromFloat(x)) - w,
        .Center => @as(i32, @intFromFloat(x)) - @divFloor(w, 2),
        .Left => @as(i32, @intFromFloat(x)),
    };
    const draw_y = switch (v_align) {
        .Bottom => @as(i32, @intFromFloat(y)) - h,
        .Center => @as(i32, @intFromFloat(y)) - @divFloor(h, 2),
        .Top => @as(i32, @intFromFloat(y)),
    };
    const text_location: c.SDL_Rect = .{ .x = draw_x, .y = draw_y, .w = w, .h = h };

    _ = c.SDL_RenderCopy(@ptrCast(renderer), text_texture, null, &text_location);
}
