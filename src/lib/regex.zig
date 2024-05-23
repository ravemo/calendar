const std = @import("std");
const c = @cImport({
    @cInclude("pcre.h");
});

pub const RegexError = error{
    NoMatches,
    RegexError,
};

pub const Captures = struct {
    const Self = @This();
    re: Regex,
    str: [:0]const u8,
    matchCount: usize,
    ovector: [30]c_int,
    pub fn sliceAt(self: *Self, i: usize) ?[]const u8 {
        var substring: [*c]const u8 = null;
        _ = c.pcre_get_substring(
            self.str,
            @ptrCast(&self.ovector),
            @intCast(self.matchCount),
            @intCast(i),
            &substring,
        );
        return std.mem.span(substring);
    }
    pub fn getNamedMatch(self: *Self, name: [:0]const u8) !?[:0]const u8 {
        var substring: [*c]const u8 = null;
        _ = c.pcre_get_named_substring(
            self.re.re,
            self.str,
            @ptrCast(&self.ovector),
            @intCast(self.matchCount),
            name,
            &substring,
        );
        return if (substring) |substr| std.mem.span(substr) else null;
    }

    pub fn deinitMatch(_: Self, match: ?[:0]const u8) void {
        if (match) |m| {
            c.pcre_free_substring(m);
        }
    }
};

pub const Regex = struct {
    const Self = @This();
    re: ?*c.pcre,
    pub fn compile(pattern: [:0]const u8) !Self {
        var err: [*c]u8 = undefined;
        var erroffset: c_int = undefined;

        return .{
            .re = c.pcre_compile(pattern, 0, (&err), &erroffset, null).?,
        };
    }

    pub fn deinit(self: Self) void {
        c.pcre_free.?(self.re);
    }

    pub fn captures(self: Self, subject: [:0]const u8) RegexError!Captures {
        var ovector: [30]c_int = undefined;
        const rc = c.pcre_exec(self.re, null, subject, @intCast(subject.len), 0, 0, &ovector, 30);

        if (rc == c.PCRE_ERROR_NOMATCH) {
            return error.NoMatches;
        } else if (rc < -1) {
            std.debug.print("error {d} from regex\n", .{rc});
            return error.RegexError;
        }
        return .{
            .re = self,
            .str = subject,
            .matchCount = @intCast(rc),
            .ovector = ovector,
        };
    }
};
