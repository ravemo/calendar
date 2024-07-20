const std = @import("std");
const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
    @cInclude("fontconfig/fontconfig.h");
});

pub const TextRenderer = struct {
    const Self = @This();
    renderer: ?*c.SDL_Renderer = null,
    font: ?*c.TTF_Font = null,

    pub fn init(name: [:0]const u8) Self {
        if (c.TTF_Init() < 0)
            sdlPanic();
        const config = c.FcInitLoadConfigAndFonts();

        // configure the search pattern,
        // assume "name" is a std::string with the desired font name in it
        const pat = c.FcNameParse(name);
        defer c.FcPatternDestroy(pat);
        _ = c.FcConfigSubstitute(config, pat, c.FcMatchPattern);
        c.FcDefaultSubstitute(pat);

        const font = blk: {
            // find the font
            var res: c.FcResult = undefined;
            const font_opt = c.FcFontMatch(config, pat, &res);
            defer c.FcPatternDestroy(font_opt);
            if (font_opt) |font| {
                var file: [*c]c.FcChar8 = null;
                if (c.FcPatternGetString(font, c.FC_FILE, 0, &file) == c.FcResultMatch) {
                    const size = 14;
                    const ttf_font = c.TTF_OpenFont(file, size);
                    break :blk ttf_font;
                }
            }
            @panic("Couldn't find font");
        };
        std.debug.assert(font != null);
        return .{
            .font = font,
        };
    }

    pub fn deinit(self: Self) void {
        c.TTF_CloseFont(self.font);
        c.TTF_Quit();
    }

    fn sdlPanic() noreturn {
        const str = @as(?[*:0]const u8, c.SDL_GetError()) orelse "unknown error";
        @panic(std.mem.sliceTo(str, 0));
    }
};

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

pub fn drawText(text_renderer: TextRenderer, label: []const u8, x: f32, y: f32, max_w: f32, max_h: f32, h_align: HAlignment, v_align: VAlignment) void {
    const allocator = std.heap.page_allocator;
    const new_label = allocator.dupeZ(u8, label) catch "ERROR";
    drawTextZ(text_renderer, new_label, x, y, max_w, max_h, h_align, v_align);
}
pub fn drawTextZ(text_renderer: TextRenderer, label: [:0]const u8, x: f32, y: f32, max_w: f32, max_h: f32, h_align: HAlignment, v_align: VAlignment) void {
    const renderer = @as(*c.SDL_Renderer, @ptrCast(text_renderer.renderer));
    if (label.len == 0) return;
    if (max_w > 0 and max_h > 0) {
        _ = c.SDL_RenderSetClipRect(renderer, &c.SDL_Rect{
            .x = @intFromFloat(x),
            .y = @intFromFloat(y),
            .w = @intFromFloat(max_w),
            .h = @intFromFloat(max_h),
        });
    }

    var color: c.SDL_Color = undefined;
    _ = c.SDL_GetRenderDrawColor(renderer, &color.r, &color.g, &color.b, &color.a);

    const text_surface = if (max_w < 0)
        c.TTF_RenderUTF8_Blended(text_renderer.font, label, color)
    else
        c.TTF_RenderUTF8_Blended_Wrapped(text_renderer.font, label, color, @intFromFloat(max_w));
    if (label.len == 0)
        return;
    defer c.SDL_FreeSurface(text_surface);
    std.debug.assert(text_surface != null);

    const text_texture = c.SDL_CreateTextureFromSurface(renderer, text_surface);
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

    _ = c.SDL_RenderCopy(renderer, text_texture, null, &text_location);
    _ = c.SDL_RenderSetClipRect(renderer, null);
}
