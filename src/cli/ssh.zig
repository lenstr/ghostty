const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("ghostty.zig").Action;
const args = @import("args.zig");
const launch_ghostty = @import("launch_ghostty.zig");
const ssh_session = @import("ssh_session.zig");
const remote_mux = @import("remote_mux.zig");

pub const Options = struct {
    class: ?[]const u8 = null,
    session: ?[]const u8 = null,
    @"mux-session": ?[]const u8 = null,
    @"no-mux": bool = false,
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
    mux_session: ?[]const u8 = null,
    no_mux: bool = false,
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
        if (self.mux_session) |v| alloc.free(v);
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

/// Create an SSH-backed Ghostty session with a persistent remote tmux mux.
///
/// By default this launches Ghostty with an SSH command that bootstraps a
/// user-scoped helper on the remote host (`~/.local/share/ghostty/remote-mux.sh`),
/// ensures a tmux session exists, and attaches to it. The remote tmux state
/// survives local GUI shutdown and can be reattached with `ghostty +connect`.
///
/// OpenSSH `ControlMaster` is still enabled so tabs/windows in the same local
/// Ghostty instance reuse SSH transport.
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
///   * `--session=<name>`: Explicit local session name used by `+connect`.
///
///   * `--mux-session=<name>`: Remote tmux session name (default: local session name).
///
///   * `--no-mux`: Disable remote tmux bootstrap and use legacy direct SSH command.
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

    if (parsed.no_mux and parsed.mux_session != null) {
        try stderr.print("Error: --mux-session cannot be used together with --no-mux.\n", .{});
        return 1;
    }

    const mux_session = parsed.mux_session orelse session_name;
    if (!parsed.no_mux and !ssh_session.isValidName(mux_session)) {
        try stderr.print("Error: invalid mux session name: {s}\n", .{mux_session});
        return 1;
    }

    var remote_attach: ?remote_mux.CommandArgs = null;
    defer if (remote_attach) |*value| value.deinit(alloc);

    var remote_status: ?remote_mux.CommandArgs = null;
    defer if (remote_status) |*value| value.deinit(alloc);

    const remote_attach_args: []const []const u8 = if (parsed.no_mux)
        parsed.remote_command.items
    else blk: {
        remote_attach = try remote_mux.buildCommandArgs(alloc, .{
            .operation = .attach,
            .session = mux_session,
            .initial_command = parsed.remote_command.items,
        });
        break :blk remote_attach.?.args;
    };

    const command = buildCommand(
        alloc,
        target,
        control_path,
        parsed.control_persist,
        parsed.verbose,
        parsed.ssh_options.items,
        remote_attach_args,
    ) catch |err| {
        try stderr.print("Error constructing SSH command: {}\n", .{err});
        return 1;
    };

    const status_command: ?[]const u8 = if (parsed.no_mux)
        null
    else blk: {
        remote_status = try remote_mux.buildCommandArgs(alloc, .{
            .operation = .status,
            .session = mux_session,
        });

        var probe_options: std.ArrayList([]const u8) = .empty;
        defer probe_options.deinit(alloc);
        try probe_options.appendSlice(alloc, parsed.ssh_options.items);
        try probe_options.appendSlice(alloc, &.{ "BatchMode=yes", "ConnectTimeout=5" });

        break :blk buildCommand(
            alloc,
            target,
            control_path,
            parsed.control_persist,
            false,
            probe_options.items,
            remote_status.?.args,
        ) catch |err| {
            try stderr.print("Error constructing SSH status command: {}\n", .{err});
            return 1;
        };
    };

    const now = std.time.timestamp();
    ssh_session.save(alloc, .{
        .name = session_name,
        .command = command,
        .status_command = status_command,
        .class = parsed.class,
        .target = target,
        .control_path = control_path,
        .mux_backend = if (parsed.no_mux) null else remote_mux.backend_name,
        .mux_session = if (parsed.no_mux) null else mux_session,
        .remote_helper_version = if (parsed.no_mux) null else remote_mux.helper_version,
        .created = now,
        .last_seen = now,
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
        mux_session,
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
                .mux_session => {
                    if (parsed.mux_session) |v| alloc.free(v);
                    parsed.mux_session = copy;
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

        if (std.mem.startsWith(u8, arg, "--mux-session=")) {
            const value = arg["--mux-session=".len..];
            if (value.len == 0) return error.MissingValue;
            if (parsed.mux_session) |v| alloc.free(v);
            parsed.mux_session = try alloc.dupe(u8, value);
            continue;
        }

        if (std.mem.eql(u8, arg, "--mux-session")) {
            pending = .mux_session;
            continue;
        }

        if (std.mem.eql(u8, arg, "--no-mux")) {
            parsed.no_mux = true;
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
    // Unix domain sockets have a path length limit (108 bytes on Linux,
    // 104 on macOS).  OpenSSH expands `%C` into a long hash, so using
    // $XDG_STATE_HOME can easily exceed this limit.
    //
    // We use $XDG_RUNTIME_DIR (typically /run/user/<uid>) when available,
    // which keeps paths short.  As a fallback we use /tmp with the UID
    // embedded to avoid collisions.
    const runtime_dir: []const u8 = std.posix.getenv("XDG_RUNTIME_DIR") orelse "";
    const base_dir = if (runtime_dir.len > 0)
        try std.fs.path.join(alloc, &.{ runtime_dir, "ghostty-ssh" })
    else
        try std.fmt.allocPrint(alloc, "/tmp/ghostty-ssh-{d}", .{std.os.linux.getuid()});
    defer alloc.free(base_dir);

    // Use just %C (hash of local host, remote host, port, user) as the
    // filename — it is unique per connection and keeps paths short enough
    // to stay within the Unix socket limit even after OpenSSH appends a
    // temporary suffix during socket creation.
    _ = session_name;

    return try std.fs.path.join(alloc, &.{ base_dir, "%C" });
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
    try testing.expect(!parsed.no_mux);
    try testing.expect(parsed.mux_session == null);
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

test "parse args with mux options" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var iter = try std.process.ArgIteratorGeneral(.{}).init(
        alloc,
        "--session=prod --mux-session=remote-prod user@example.com",
    );
    defer iter.deinit();

    var parsed = try parseArgs(alloc, &iter);
    defer parsed.deinit(alloc);

    try testing.expect(!parsed.no_mux);
    try testing.expectEqualStrings("prod", parsed.session.?);
    try testing.expectEqualStrings("remote-prod", parsed.mux_session.?);
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

test "build command with remote mux bootstrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var remote_cmd = try remote_mux.buildCommandArgs(alloc, .{
        .operation = .attach,
        .session = "prod",
        .initial_command = &.{ "nvim", "foo bar" },
    });
    defer remote_cmd.deinit(alloc);

    const cmd = try buildCommand(
        alloc,
        "user@example.com",
        "/tmp/ghostty-%C",
        "10m",
        false,
        &.{},
        remote_cmd.args,
    );
    defer alloc.free(cmd);

    try testing.expect(std.mem.indexOf(u8, cmd, "remote-mux.sh") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "attach") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "foo bar") != null);
}
