const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("ghostty.zig").Action;
const args = @import("args.zig");
const launch_ghostty = @import("launch_ghostty.zig");
const ssh_session = @import("ssh_session.zig");
const internal_os = @import("../os/main.zig");
const xdg = internal_os.xdg;

pub const Options = struct {
    class: ?[]const u8 = null,
    session: ?[]const u8 = null,
    @"control-path": ?[]const u8 = null,
    @"control-persist": ?[]const u8 = null,
    @"ssh-option": ?[]const u8 = null,
    verbose: bool = false,

    pub fn deinit(self: *Options) void {
        _ = self;
    }

    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

const ParseError = Allocator.Error || error{
    MissingTarget,
    MissingValue,
    InvalidOption,
    ActionHelpRequested,
};

const Parsed = struct {
    class: ?[]const u8 = null,
    session: ?[]const u8 = null,
    control_path: ?[]const u8 = null,
    control_persist: []const u8 = "10m",
    control_persist_owned: bool = false,
    verbose: bool = false,
    target: ?[]const u8 = null,
    ssh_options: std.ArrayList([]const u8) = .empty,
    remote_command: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *Parsed, alloc: Allocator) void {
        if (self.class) |v| alloc.free(v);
        if (self.session) |v| alloc.free(v);
        if (self.control_path) |v| alloc.free(v);
        if (self.target) |v| alloc.free(v);

        for (self.ssh_options.items) |value| alloc.free(value);
        self.ssh_options.deinit(alloc);

        for (self.remote_command.items) |value| alloc.free(value);
        self.remote_command.deinit(alloc);

        if (self.control_persist_owned) {
            alloc.free(self.control_persist);
        }

        self.* = undefined;
    }
};

/// Create an SSH-backed Ghostty session with OpenSSH multiplexing enabled.
///
/// This launches Ghostty with a command that uses OpenSSH `ControlMaster`
/// multiplexing so that new tabs and windows in the same Ghostty instance reuse
/// the same SSH transport.
///
/// The created session is saved under `$XDG_STATE_HOME/ghostty/ssh_sessions` and
/// can later be reopened with `ghostty +connect <session>`.
///
/// Usage:
///
///   ghostty +ssh [options] [user@]host[:port] [remote command ...]
///
/// Flags:
///
///   * `--class=<class>`: Custom Ghostty class/app-id for the launched session.
///
///   * `--session=<name>`: Explicit session name used by `+connect`.
///
///   * `--control-path=<path>`: Explicit OpenSSH control socket path.
///
///   * `--control-persist=<value>`: Value for `ControlPersist` (default: `10m`).
///
///   * `--ssh-option=<name=value>` or `-o <name=value>`: Additional SSH options.
///
///   * `-v`/`--verbose`: Enable verbose SSH output.
pub fn run(alloc_gpa: Allocator) !u8 {
    var iter = try args.argsIterator(alloc_gpa);
    defer iter.deinit();

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const result = runArgs(alloc_gpa, &iter, stderr);
    stderr.flush() catch {};
    return result;
}

fn runArgs(
    alloc_gpa: Allocator,
    argsIter: anytype,
    stderr: *std.Io.Writer,
) !u8 {
    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parsed = parseArgs(alloc, argsIter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        error.MissingTarget => {
            try stderr.print("Error: missing SSH target. Usage: ghostty +ssh [options] [user@]host[:port]\n", .{});
            return 1;
        },
        error.MissingValue => {
            try stderr.print("Error: option requires a value.\n", .{});
            return 1;
        },
        error.InvalidOption => {
            try stderr.print("Error: invalid option. Use ghostty +ssh --help for usage.\n", .{});
            return 1;
        },
        else => return err,
    };
    defer parsed.deinit(alloc);

    const target = parsed.target.?;
    const session_name = if (parsed.session) |name|
        name
    else
        try ssh_session.defaultName(alloc, target);

    if (!ssh_session.isValidName(session_name)) {
        try stderr.print("Error: invalid session name: {s}\n", .{session_name});
        return 1;
    }

    const control_path = if (parsed.control_path) |path|
        path
    else
        try defaultControlPath(alloc, session_name);

    ensureControlPathParent(control_path) catch |err| {
        try stderr.print("Error creating SSH control socket directory: {}\n", .{err});
        return 1;
    };

    const command = buildCommand(
        alloc,
        target,
        control_path,
        parsed.control_persist,
        parsed.verbose,
        parsed.ssh_options.items,
        parsed.remote_command.items,
    ) catch |err| {
        try stderr.print("Error constructing SSH command: {}\n", .{err});
        return 1;
    };

    ssh_session.save(alloc, .{
        .name = session_name,
        .command = command,
        .class = parsed.class,
        .target = target,
        .control_path = control_path,
        .created = std.time.timestamp(),
    }) catch |err| {
        try stderr.print("Error saving SSH session metadata: {}\n", .{err});
        return 1;
    };

    return launch_ghostty.execWithCommand(alloc, .{
        .command = command,
        .class = parsed.class,
    }, stderr);
}

fn parseArgs(alloc: Allocator, argsIter: anytype) ParseError!Parsed {
    var parsed: Parsed = .{};
    errdefer parsed.deinit(alloc);

    const Pending = enum {
        class,
        session,
        control_path,
        control_persist,
        ssh_option,
    };

    var pending: ?Pending = null;

    while (argsIter.next()) |arg| {
        if (pending) |key| {
            if (arg.len == 0) return error.MissingValue;
            const copy = try alloc.dupe(u8, arg);
            switch (key) {
                .class => {
                    if (parsed.class) |v| alloc.free(v);
                    parsed.class = copy;
                },
                .session => {
                    if (parsed.session) |v| alloc.free(v);
                    parsed.session = copy;
                },
                .control_path => {
                    if (parsed.control_path) |v| alloc.free(v);
                    parsed.control_path = copy;
                },
                .control_persist => {
                    if (parsed.control_persist_owned) alloc.free(parsed.control_persist);
                    parsed.control_persist = copy;
                    parsed.control_persist_owned = true;
                },
                .ssh_option => try parsed.ssh_options.append(alloc, copy),
            }

            pending = null;
            continue;
        }

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return Action.help_error;
        }

        if (std.mem.eql(u8, arg, "--")) {
            while (argsIter.next()) |value| {
                try parsed.remote_command.append(alloc, try alloc.dupe(u8, value));
            }
            break;
        }

        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            parsed.verbose = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "-o")) {
            pending = .ssh_option;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "-o") and arg.len > 2) {
            try parsed.ssh_options.append(alloc, try alloc.dupe(u8, arg[2..]));
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--ssh-option=")) {
            const value = arg["--ssh-option=".len..];
            if (value.len == 0) return error.MissingValue;
            try parsed.ssh_options.append(alloc, try alloc.dupe(u8, value));
            continue;
        }

        if (std.mem.eql(u8, arg, "--ssh-option")) {
            pending = .ssh_option;
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
            pending = .class;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--session=")) {
            const value = arg["--session=".len..];
            if (value.len == 0) return error.MissingValue;
            if (parsed.session) |v| alloc.free(v);
            parsed.session = try alloc.dupe(u8, value);
            continue;
        }

        if (std.mem.eql(u8, arg, "--session")) {
            pending = .session;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--control-path=")) {
            const value = arg["--control-path=".len..];
            if (value.len == 0) return error.MissingValue;
            if (parsed.control_path) |v| alloc.free(v);
            parsed.control_path = try alloc.dupe(u8, value);
            continue;
        }

        if (std.mem.eql(u8, arg, "--control-path")) {
            pending = .control_path;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--control-persist=")) {
            const value = arg["--control-persist=".len..];
            if (value.len == 0) return error.MissingValue;
            if (parsed.control_persist_owned) alloc.free(parsed.control_persist);
            parsed.control_persist = try alloc.dupe(u8, value);
            parsed.control_persist_owned = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--control-persist")) {
            pending = .control_persist;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--")) {
            return error.InvalidOption;
        }

        if (parsed.target == null) {
            parsed.target = try alloc.dupe(u8, arg);
        } else {
            try parsed.remote_command.append(alloc, try alloc.dupe(u8, arg));
        }
    }

    if (pending != null) return error.MissingValue;
    if (parsed.target == null) return error.MissingTarget;

    return parsed;
}

fn defaultControlPath(alloc: Allocator, session_name: []const u8) ![]const u8 {
    const state_dir = try xdg.state(alloc, .{ .subdir = "ghostty" });
    defer alloc.free(state_dir);

    const filename = try std.fmt.allocPrint(alloc, "{s}-%C", .{session_name});
    defer alloc.free(filename);

    return try std.fs.path.join(alloc, &.{ state_dir, "ssh_mux", filename });
}

fn ensureControlPathParent(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
}

fn buildCommand(
    alloc: Allocator,
    target: []const u8,
    control_path: []const u8,
    control_persist: []const u8,
    verbose: bool,
    ssh_options: []const []const u8,
    remote_command: []const []const u8,
) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);

    var owned: std.ArrayList([]const u8) = .empty;
    defer {
        for (owned.items) |value| alloc.free(value);
        owned.deinit(alloc);
    }

    try argv.append(alloc, "ssh");

    try argv.append(alloc, "-o");
    try argv.append(alloc, "ControlMaster=auto");

    const persist_opt = try std.fmt.allocPrint(alloc, "ControlPersist={s}", .{control_persist});
    try owned.append(alloc, persist_opt);
    try argv.append(alloc, "-o");
    try argv.append(alloc, persist_opt);

    const path_opt = try std.fmt.allocPrint(alloc, "ControlPath={s}", .{control_path});
    try owned.append(alloc, path_opt);
    try argv.append(alloc, "-o");
    try argv.append(alloc, path_opt);

    if (verbose) try argv.append(alloc, "-v");

    for (ssh_options) |opt| {
        try argv.append(alloc, "-o");
        try argv.append(alloc, opt);
    }

    try argv.append(alloc, target);
    try argv.appendSlice(alloc, remote_command);

    return buildShellCommand(alloc, argv.items);
}

fn buildShellCommand(alloc: Allocator, argv: []const []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(alloc);

    try result.appendSlice(alloc, "shell:");

    for (argv, 0..) |arg, i| {
        if (i > 0) try result.append(alloc, ' ');
        try appendShellEscaped(alloc, &result, arg);
    }

    return try result.toOwnedSlice(alloc);
}

fn appendShellEscaped(
    alloc: Allocator,
    builder: *std.ArrayList(u8),
    value: []const u8,
) !void {
    if (!needsShellEscaping(value)) {
        try builder.appendSlice(alloc, value);
        return;
    }

    try builder.append(alloc, '\'');
    for (value) |c| {
        if (c == '\'') {
            try builder.appendSlice(alloc, "'\\''");
        } else {
            try builder.append(alloc, c);
        }
    }
    try builder.append(alloc, '\'');
}

fn needsShellEscaping(value: []const u8) bool {
    if (value.len == 0) return true;

    for (value) |c| switch (c) {
        'a'...'z',
        'A'...'Z',
        '0'...'9',
        '_',
        '-',
        '.',
        '/',
        ':',
        '@',
        '+',
        '=',
        ',',
        '%',
        '~',
        => {},
        else => return true,
    };

    return false;
}

test "parse args with target only" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var iter = try std.process.ArgIteratorGeneral(.{}).init(alloc, "user@example.com");
    defer iter.deinit();

    var parsed = try parseArgs(alloc, &iter);
    defer parsed.deinit(alloc);

    try testing.expectEqualStrings("user@example.com", parsed.target.?);
    try testing.expectEqual(@as(usize, 0), parsed.ssh_options.items.len);
    try testing.expectEqual(@as(usize, 0), parsed.remote_command.items.len);
}

test "parse args with options and remote command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var iter = try std.process.ArgIteratorGeneral(.{}).init(
        alloc,
        "--session=prod -oIdentityFile=/tmp/id_ed25519 --control-persist=30m user@example.com -- tmux attach",
    );
    defer iter.deinit();

    var parsed = try parseArgs(alloc, &iter);
    defer parsed.deinit(alloc);

    try testing.expectEqualStrings("prod", parsed.session.?);
    try testing.expectEqualStrings("30m", parsed.control_persist);
    try testing.expectEqual(@as(usize, 1), parsed.ssh_options.items.len);
    try testing.expectEqualStrings("IdentityFile=/tmp/id_ed25519", parsed.ssh_options.items[0]);
    try testing.expectEqualStrings("user@example.com", parsed.target.?);
    try testing.expectEqual(@as(usize, 2), parsed.remote_command.items.len);
    try testing.expectEqualStrings("tmux", parsed.remote_command.items[0]);
    try testing.expectEqualStrings("attach", parsed.remote_command.items[1]);
}

test "build command contains multiplexing options" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const cmd = try buildCommand(
        alloc,
        "user@example.com",
        "/tmp/ghostty-%C",
        "15m",
        false,
        &.{"IdentityFile=/tmp/id"},
        &.{ "printf", "hello world" },
    );
    defer alloc.free(cmd);

    try testing.expect(std.mem.startsWith(u8, cmd, "shell:ssh "));
    try testing.expect(std.mem.indexOf(u8, cmd, "ControlMaster=auto") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "ControlPersist=15m") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "ControlPath=/tmp/ghostty-%C") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "IdentityFile=/tmp/id") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "'hello world'") != null);
}
