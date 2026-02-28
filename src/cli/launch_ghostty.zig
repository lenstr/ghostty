const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    command: []const u8,
    class: ?[]const u8 = null,
};

pub fn execWithCommand(
    alloc: Allocator,
    opts: Options,
    stderr: *std.Io.Writer,
) !u8 {
    if (comptime builtin.os.tag == .windows) {
        try stderr.print(
            "The `ghostty +ssh` and `ghostty +connect` commands are not supported on Windows.\n",
            .{},
        );
        return 1;
    }

    comptime assert(builtin.link_libc);

    const exe_path = try std.fs.selfExePathAlloc(alloc);
    defer alloc.free(exe_path);

    const argv = try buildArgv(alloc, exe_path, opts);
    defer {
        for (argv) |arg| alloc.free(arg);
        alloc.free(argv);
    }

    const argv_exec = try alloc.allocSentinel(?[*:0]const u8, argv.len, null);
    defer alloc.free(argv_exec);
    for (argv, 0..) |arg, i| argv_exec[i] = arg.ptr;

    const err = std.posix.execvpeZ(argv[0], argv_exec, std.c.environ);

    try stderr.print(
        "Failed to launch Ghostty with command forwarding. Error={}\n",
        .{err},
    );
    return 1;
}

pub fn buildArgv(
    alloc: Allocator,
    exe_path: []const u8,
    opts: Options,
) ![][:0]const u8 {
    var argv: std.ArrayList([:0]const u8) = .empty;
    errdefer {
        for (argv.items) |arg| alloc.free(arg);
        argv.deinit(alloc);
    }

    try argv.append(alloc, try alloc.dupeZ(u8, exe_path));
    try argv.append(alloc, try alloc.dupeZ(u8, "--gtk-single-instance=false"));

    const command_arg = try std.fmt.allocPrintSentinel(
        alloc,
        "--command={s}",
        .{opts.command},
        0,
    );
    try argv.append(alloc, command_arg);

    const initial_command_arg = try std.fmt.allocPrintSentinel(
        alloc,
        "--initial-command={s}",
        .{opts.command},
        0,
    );
    try argv.append(alloc, initial_command_arg);

    if (opts.class) |class| {
        const class_arg = try std.fmt.allocPrintSentinel(
            alloc,
            "--class={s}",
            .{class},
            0,
        );
        try argv.append(alloc, class_arg);
    }

    return try argv.toOwnedSlice(alloc);
}

test "build argv" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const argv = try buildArgv(alloc, "/usr/bin/ghostty", .{
        .command = "shell:ssh user@example.com",
        .class = "com.example.ghostty",
    });
    defer {
        for (argv) |arg| alloc.free(arg);
        alloc.free(argv);
    }

    try testing.expectEqualStrings("/usr/bin/ghostty", argv[0]);
    try testing.expectEqualStrings("--gtk-single-instance=false", argv[1]);
    try testing.expectEqualStrings("--command=shell:ssh user@example.com", argv[2]);
    try testing.expectEqualStrings("--initial-command=shell:ssh user@example.com", argv[3]);
    try testing.expectEqualStrings("--class=com.example.ghostty", argv[4]);
}
