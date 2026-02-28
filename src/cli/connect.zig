const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("ghostty.zig").Action;
const args = @import("args.zig");
const launch_ghostty = @import("launch_ghostty.zig");
const ssh_session = @import("ssh_session.zig");
const remote_mux = @import("remote_mux.zig");

pub const Options = struct {
    list: bool = false,
    status: bool = false,
    class: ?[]const u8 = null,

    pub fn deinit(self: *Options) void {
        _ = self;
    }

    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

const ParseError = Allocator.Error || error{
    MissingSession,
    MissingValue,
    InvalidOption,
    ActionHelpRequested,
};

const Parsed = struct {
    list: bool = false,
    status: bool = false,
    class: ?[]const u8 = null,
    session: ?[]const u8 = null,

    fn deinit(self: *Parsed, alloc: Allocator) void {
        if (self.class) |v| alloc.free(v);
        if (self.session) |v| alloc.free(v);
        self.* = undefined;
    }
};

/// Reconnect to a previously created SSH multiplexing session.
///
/// Sessions are created by `ghostty +ssh` and stored in
/// `$XDG_STATE_HOME/ghostty/ssh_sessions`.
///
/// Usage:
///
///   ghostty +connect <session>
///
/// Flags:
///
///   * `--list`: List known SSH sessions.
///
///   * `--status`: With `--list`, probe live remote mux status.
///
///   * `--class=<class>`: Override class/app-id for the launched session.
pub fn run(alloc_gpa: Allocator) !u8 {
    var iter = try args.argsIterator(alloc_gpa);
    defer iter.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const result = runArgs(alloc_gpa, &iter, stdout, stderr);
    stdout.flush() catch {};
    stderr.flush() catch {};
    return result;
}

fn runArgs(
    alloc_gpa: Allocator,
    argsIter: anytype,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parsed = parseArgs(alloc, argsIter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        error.MissingSession => {
            try stderr.print("Error: missing session name. Use ghostty +connect --list to inspect sessions.\n", .{});
            return 1;
        },
        error.MissingValue => {
            try stderr.print("Error: option requires a value.\n", .{});
            return 1;
        },
        error.InvalidOption => {
            try stderr.print("Error: invalid option. Use ghostty +connect --help for usage.\n", .{});
            return 1;
        },
        else => return err,
    };
    defer parsed.deinit(alloc);

    if (parsed.list) {
        return listSessions(alloc, stdout, parsed.status);
    }

    var session = ssh_session.load(alloc, parsed.session.?) catch |err| switch (err) {
        error.SessionNotFound => {
            try stderr.print("Error: session not found: {s}\n", .{parsed.session.?});
            return 1;
        },
        error.InvalidSessionName => {
            try stderr.print("Error: invalid session name: {s}\n", .{parsed.session.?});
            return 1;
        },
        error.InvalidSessionFile => {
            try stderr.print("Error: session metadata is invalid: {s}\n", .{parsed.session.?});
            return 1;
        },
        else => {
            try stderr.print("Error loading session: {}\n", .{err});
            return 1;
        },
    };
    defer session.deinit(alloc);

    session.last_seen = std.time.timestamp();
    ssh_session.save(alloc, session) catch |err| {
        try stderr.print("Warning: failed to update session metadata: {}\n", .{err});
    };

    return launch_ghostty.execWithCommand(alloc, .{
        .command = session.command,
        .class = parsed.class orelse session.class,
    }, stderr);
}

fn parseArgs(alloc: Allocator, argsIter: anytype) ParseError!Parsed {
    var parsed: Parsed = .{};
    errdefer parsed.deinit(alloc);

    var waiting_class = false;

    while (argsIter.next()) |arg| {
        if (waiting_class) {
            if (arg.len == 0) return error.MissingValue;
            if (parsed.class) |v| alloc.free(v);
            parsed.class = try alloc.dupe(u8, arg);
            waiting_class = false;
            continue;
        }

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return Action.help_error;
        }

        if (std.mem.eql(u8, arg, "--list")) {
            parsed.list = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--status")) {
            parsed.status = true;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--class=")) {
            const value = arg["--class=".len..];
            if (value.len == 0) return error.MissingValue;
            if (parsed.class) |v| alloc.free(v);
            parsed.class = try alloc.dupe(u8, value);
            continue;
        }

        if (std.mem.eql(u8, arg, "--class")) {
            waiting_class = true;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--")) {
            return error.InvalidOption;
        }

        if (parsed.session == null) {
            parsed.session = try alloc.dupe(u8, arg);
        } else {
            return error.InvalidOption;
        }
    }

    if (waiting_class) return error.MissingValue;
    if (parsed.status and !parsed.list) return error.InvalidOption;
    if (!parsed.list and parsed.session == null) return error.MissingSession;

    return parsed;
}

fn listSessions(alloc: Allocator, stdout: *std.Io.Writer, probe_status: bool) !u8 {
    const sessions = try ssh_session.list(alloc);
    defer {
        for (sessions) |*session| session.deinit(alloc);
        alloc.free(sessions);
    }

    if (sessions.len == 0) {
        try stdout.print("No saved SSH sessions.\n", .{});
        return 0;
    }

    try stdout.print("Saved SSH sessions ({d}):\n", .{sessions.len});
    for (sessions) |session| {
        const backend = session.mux_backend orelse "legacy";
        const mux_session = session.mux_session orelse "-";
        const helper_version = session.remote_helper_version orelse "-";

        const status: remote_mux.ProbeStatus = blk: {
            if (!probe_status) break :blk .unknown;
            const cmd = session.status_command orelse break :blk .unknown;
            break :blk try probeSessionStatus(alloc, cmd);
        };

        try stdout.print(
            "  {s} -> {s} [backend={s} mux-session={s} helper={s} created={d} last-seen={d} status={s}]\n",
            .{
                session.name,
                session.target,
                backend,
                mux_session,
                helper_version,
                session.created,
                session.last_seen,
                @tagName(status),
            },
        );
    }

    return 0;
}

fn probeSessionStatus(alloc: Allocator, command: []const u8) !remote_mux.ProbeStatus {
    const shell_command = if (std.mem.startsWith(u8, command, "shell:"))
        command["shell:".len..]
    else
        command;

    const child_result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "sh", "-lc", shell_command },
        .max_output_bytes = 8 * 1024,
    }) catch {
        return .unknown;
    };
    defer alloc.free(child_result.stdout);
    defer alloc.free(child_result.stderr);

    if (child_result.term != .Exited or child_result.term.Exited != 0) {
        return .unknown;
    }

    return remote_mux.parseProbeStatus(child_result.stdout);
}

test "parse args list" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var iter = try std.process.ArgIteratorGeneral(.{}).init(alloc, "--list");
    defer iter.deinit();

    var parsed = try parseArgs(alloc, &iter);
    defer parsed.deinit(alloc);

    try testing.expect(parsed.list);
    try testing.expect(!parsed.status);
    try testing.expect(parsed.session == null);
}

test "parse args session and class" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var iter = try std.process.ArgIteratorGeneral(.{}).init(alloc, "prod --class=com.example.ghostty");
    defer iter.deinit();

    var parsed = try parseArgs(alloc, &iter);
    defer parsed.deinit(alloc);

    try testing.expectEqualStrings("prod", parsed.session.?);
    try testing.expectEqualStrings("com.example.ghostty", parsed.class.?);
}

test "parse args list with status" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var iter = try std.process.ArgIteratorGeneral(.{}).init(alloc, "--list --status");
    defer iter.deinit();

    var parsed = try parseArgs(alloc, &iter);
    defer parsed.deinit(alloc);

    try testing.expect(parsed.list);
    try testing.expect(parsed.status);
}

test "status requires list" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var iter = try std.process.ArgIteratorGeneral(.{}).init(alloc, "--status");
    defer iter.deinit();

    try testing.expectError(error.InvalidOption, parseArgs(alloc, &iter));
}
