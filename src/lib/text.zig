const std = @import("std");
const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
    @cInclude("fontconfig/fontconfig.h");
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

pub fn drawText(renderer: anytype, label: []const u8, x: f32, y: f32, max_w: f32, max_h: f32, h_align: HAlignment, v_align: VAlignment) void {
    const allocator = std.heap.page_allocator;
    const new_label = allocator.dupeZ(u8, label) catch "ERROR";
    drawTextZ(renderer, new_label, x, y, max_w, max_h, h_align, v_align);
}
pub fn drawTextZ(renderer: anytype, label: [:0]const u8, x: f32, y: f32, max_w: f32, max_h: f32, h_align: HAlignment, v_align: VAlignment) void {
    if (label.len == 0) return;
    if (max_w > 0 and max_h > 0) {
        _ = c.SDL_RenderSetClipRect(@ptrCast(renderer), &c.SDL_Rect{
            .x = @intFromFloat(x),
            .y = @intFromFloat(y),
            .w = @intFromFloat(max_w),
            .h = @intFromFloat(max_h),
        });
    }
    const size = 14;

    const font = c.TTF_OpenFont("data/Mecha.ttf", size);
    //var fontpath: [256:0]u8 = undefined;
    //loadFont("Roboto-Regular.ttf", &fontpath);
    //const font = c.TTF_OpenFont(&fontpath, size);
    defer c.TTF_CloseFont(font);
    std.debug.assert(font != null);

    var color: c.SDL_Color = undefined;
    _ = c.SDL_GetRenderDrawColor(@ptrCast(renderer), &color.r, &color.g, &color.b, &color.a);

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
    _ = c.SDL_RenderSetClipRect(@ptrCast(renderer), null);
}

pub fn loadFont(name: [:0]const u8, buf: [:0]u8) void {
    const config = c.FcInitLoadConfigAndFonts();

    // configure the search pattern,
    // assume "name" is a std::string with the desired font name in it
    const pat = c.FcNameParse(name);
    defer c.FcPatternDestroy(pat);
    _ = c.FcConfigSubstitute(config, pat, c.FcMatchPattern);
    c.FcDefaultSubstitute(pat);

    // find the font
    var res: c.FcResult = undefined;
    const font_opt = c.FcFontMatch(config, pat, &res);
    defer c.FcPatternDestroy(font_opt);
    if (font_opt) |font| {
        var file: [*c]c.FcChar8 = null;
        if (c.FcPatternGetString(font, c.FC_FILE, 0, &file) == c.FcResultMatch) {
            // save the file to another std::string
            std.mem.copyForwards(u8, buf, std.mem.span(file));
            buf[std.mem.len(file)] = 0;
            return;
        }
    }
    @panic("Couldn't find font");
}
