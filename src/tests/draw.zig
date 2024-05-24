const std = @import("std");
const draw = @import("../lib/draw.zig");
const RndGen = std.rand.DefaultPrng;

test "Coordinate and time relation" {
    var rnd = RndGen.init(0);
    const test_count: usize = 100;
    const w = 600;
    const h = 300;
    for (0..test_count) |_| {
        const x: f32 = rnd.random().float(f32) * w;
        const y: f32 = rnd.random().float(f32) * h;
        const hr: f32 = rnd.random().float(f32) * 24;
        const wd: i32 = rnd.random().int(i32) % 7;

        const x2 = draw.xFromWeekday(wd, w);
        const y2 = draw.yFromHour(hr, h);
        const hr2 = draw.weekdayFromX(x, w);
        const wd2 = draw.hourFromY(y, h);

        std.testing.expectApproxEqAbs(x, x2, 0.1);
        std.testing.expectApproxEqAbs(y, y2, 0.1);
        std.testing.expectApproxEqAbs(hr, hr2, 0.1);
        std.testing.expectApproxEqAbs(wd, wd2, 0.1);
    }
}
