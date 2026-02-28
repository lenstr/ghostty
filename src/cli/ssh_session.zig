const std = @import("std");
const Allocator = std.mem.Allocator;
const internal_os = @import("../os/main.zig");
const env_os = @import("../os/env.zig");
const xdg = internal_os.xdg;

pub const Session = struct {
    name: []const u8,
    command: []const u8,
    status_command: ?[]const u8 = null,
    class: ?[]const u8 = null,
    target: []const u8,
    control_path: []const u8,
    mux_backend: ?[]const u8 = null,
    mux_session: ?[]const u8 = null,
    remote_helper_version: ?[]const u8 = null,
    created: i64,
    last_seen: i64 = 0,

    pub fn deinit(self: *Session, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.command);
        if (self.status_command) |value| alloc.free(value);
        if (self.class) |class| alloc.free(class);
        alloc.free(self.target);
        alloc.free(self.control_path);
        if (self.mux_backend) |value| alloc.free(value);
        if (self.mux_session) |value| alloc.free(value);
        if (self.remote_helper_version) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub fn isValidName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;

    for (name) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.') continue;
        return false;
    }

    return true;
}

pub fn defaultName(alloc: Allocator, target: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    var last_dash = false;
    for (target) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try buf.append(alloc, std.ascii.toLower(c));
            last_dash = false;
            continue;
        }

        if (c == '_' or c == '-') {
            try buf.append(alloc, c);
            last_dash = false;
            continue;
        }

        // Dots are replaced with hyphens because tmux uses dots as
        // window/pane separators in target specifications (session:window.pane).
        // A session name containing dots would confuse tmux target matching
        // even with the exact-match prefix (e.g. `-t "=name.with.dots"`).
        if (c == '.') {
            if (!last_dash) {
                try buf.append(alloc, '-');
                last_dash = true;
            }
            continue;
        }

        if (!last_dash) {
            try buf.append(alloc, '-');
            last_dash = true;
        }
    }

    while (buf.items.len > 0 and buf.items[0] == '-') {
        _ = buf.orderedRemove(0);
    }
    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == '-') {
        _ = buf.pop();
    }

    if (buf.items.len == 0) {
        try buf.appendSlice(alloc, "ssh");
    }

    const max_len: usize = 32;
    if (buf.items.len > max_len) {
        const hash = std.hash.Wyhash.hash(0, target);
        const suffix = try std.fmt.allocPrint(alloc, "-{x:0>8}", .{@as(u32, @truncate(hash))});
        defer alloc.free(suffix);

        const keep = max_len -| suffix.len;
        buf.shrinkRetainingCapacity(keep);
        try buf.appendSlice(alloc, suffix);
    }

    return try buf.toOwnedSlice(alloc);
}

pub fn sessionsDir(alloc: Allocator) ![]const u8 {
    const state_dir = xdg.state(alloc, .{ .subdir = "ghostty" }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionFile,
    };
    defer alloc.free(state_dir);

    return try std.fs.path.join(alloc, &.{ state_dir, "ssh_sessions" });
}

pub fn sessionPath(alloc: Allocator, name: []const u8) ![]const u8 {
    if (!isValidName(name)) return error.InvalidSessionName;

    const dir = try sessionsDir(alloc);
    defer alloc.free(dir);

    return try std.fs.path.join(alloc, &.{ dir, name });
}

pub fn save(alloc: Allocator, session: Session) !void {
    if (!isValidName(session.name)) return error.InvalidSessionName;

    const path = try sessionPath(alloc, session.name);
    defer alloc.free(path);

    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    var file = try std.fs.createFileAbsolute(path, .{
        .read = false,
        .truncate = true,
        .mode = 0o600,
    });
    defer file.close();

    var writer_buf: [1024]u8 = undefined;
    var file_writer = file.writer(&writer_buf);
    const writer = &file_writer.interface;

    try writer.print("version=2\n", .{});
    try writer.print("name={s}\n", .{session.name});
    try writeBase64Field(alloc, writer, "command", session.command);
    try writer.print("target={s}\n", .{session.target});
    try writer.print("control_path={s}\n", .{session.control_path});
    try writer.print("created={d}\n", .{session.created});
    try writer.print("last_seen={d}\n", .{session.last_seen});
    if (session.status_command) |value| {
        try writeBase64Field(alloc, writer, "status_command", value);
    }
    if (session.class) |class| {
        try writer.print("class={s}\n", .{class});
    }
    if (session.mux_backend) |value| {
        try writer.print("mux_backend={s}\n", .{value});
    }
    if (session.mux_session) |value| {
        try writer.print("mux_session={s}\n", .{value});
    }
    if (session.remote_helper_version) |value| {
        try writer.print("remote_helper_version={s}\n", .{value});
    }

    try writer.flush();
}

fn writeBase64Field(
    alloc: Allocator,
    writer: *std.Io.Writer,
    key: []const u8,
    value: []const u8,
) !void {
    const enc = std.base64.standard.Encoder;
    const encoded_len = enc.calcSize(value.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    defer alloc.free(encoded);

    _ = enc.encode(encoded, value);
    try writer.print("{s}_b64={s}\n", .{ key, encoded });
}

fn decodeBase64Field(alloc: Allocator, value: []const u8) ![]const u8 {
    const dec = std.base64.standard.Decoder;
    const decoded_len = try dec.calcSizeForSlice(value);
    const decoded = try alloc.alloc(u8, decoded_len);
    errdefer alloc.free(decoded);

    try dec.decode(decoded, value);
    return decoded;
}

pub fn load(alloc: Allocator, name: []const u8) !Session {
    const path = try sessionPath(alloc, name);
    defer alloc.free(path);

    var file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.SessionNotFound,
        else => return err,
    };
    defer file.close();

    const data = try file.readToEndAlloc(alloc, 64 * 1024);
    defer alloc.free(data);

    var command: ?[]const u8 = null;
    var status_command: ?[]const u8 = null;
    var class: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var control_path: ?[]const u8 = null;
    var mux_backend: ?[]const u8 = null;
    var mux_session: ?[]const u8 = null;
    var remote_helper_version: ?[]const u8 = null;
    var created: i64 = 0;
    var last_seen: i64 = 0;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const i = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..i];
        const value = line[i + 1 ..];

        if (std.mem.eql(u8, key, "command")) {
            if (command) |v| alloc.free(v);
            command = try alloc.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "command_b64")) {
            if (command) |v| alloc.free(v);
            command = decodeBase64Field(alloc, value) catch return error.InvalidSessionFile;
        } else if (std.mem.eql(u8, key, "status_command")) {
            if (status_command) |v| alloc.free(v);
            status_command = try alloc.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "status_command_b64")) {
            if (status_command) |v| alloc.free(v);
            status_command = decodeBase64Field(alloc, value) catch return error.InvalidSessionFile;
        } else if (std.mem.eql(u8, key, "class")) {
            if (class) |v| alloc.free(v);
            class = try alloc.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "target")) {
            if (target) |v| alloc.free(v);
            target = try alloc.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "control_path")) {
            if (control_path) |v| alloc.free(v);
            control_path = try alloc.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "mux_backend")) {
            if (mux_backend) |v| alloc.free(v);
            mux_backend = try alloc.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "mux_session")) {
            if (mux_session) |v| alloc.free(v);
            mux_session = try alloc.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "remote_helper_version")) {
            if (remote_helper_version) |v| alloc.free(v);
            remote_helper_version = try alloc.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "created")) {
            created = std.fmt.parseInt(i64, value, 10) catch 0;
        } else if (std.mem.eql(u8, key, "last_seen")) {
            last_seen = std.fmt.parseInt(i64, value, 10) catch 0;
        }
    }

    errdefer {
        if (command) |v| alloc.free(v);
        if (status_command) |v| alloc.free(v);
        if (class) |v| alloc.free(v);
        if (target) |v| alloc.free(v);
        if (control_path) |v| alloc.free(v);
        if (mux_backend) |v| alloc.free(v);
        if (mux_session) |v| alloc.free(v);
        if (remote_helper_version) |v| alloc.free(v);
    }

    if (command == null or target == null or control_path == null) {
        return error.InvalidSessionFile;
    }

    return .{
        .name = try alloc.dupe(u8, name),
        .command = command.?,
        .status_command = status_command,
        .class = class,
        .target = target.?,
        .control_path = control_path.?,
        .mux_backend = mux_backend,
        .mux_session = mux_session,
        .remote_helper_version = remote_helper_version,
        .created = created,
        .last_seen = if (last_seen == 0) created else last_seen,
    };
}

pub fn list(alloc: Allocator) ![]Session {
    const dir_path = try sessionsDir(alloc);
    defer alloc.free(dir_path);

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return try alloc.alloc(Session, 0),
        else => return err,
    };
    defer dir.close();

    var result: std.ArrayList(Session) = .empty;
    errdefer {
        for (result.items) |*session| session.deinit(alloc);
        result.deinit(alloc);
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!isValidName(entry.name)) continue;

        const session = load(alloc, entry.name) catch continue;
        try result.append(alloc, session);
    }

    std.mem.sort(Session, result.items, {}, struct {
        fn lessThan(_: void, a: Session, b: Session) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    return try result.toOwnedSlice(alloc);
}

test "defaultName normalizes target" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const name = try defaultName(alloc, "User@Example.com:2200");
    defer alloc.free(name);

    // Dots are replaced with hyphens because tmux uses dots as
    // window/pane separators in target specifications.
    try testing.expectEqualStrings("user-example-com-2200", name);
}

test "defaultName replaces dots for tmux compatibility" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const name = try defaultName(alloc, "user@10.10.10.110");
    defer alloc.free(name);

    try testing.expectEqualStrings("user-10-10-10-110", name);
}

test "save and load" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const original = std.posix.getenv("XDG_STATE_HOME");
    defer {
        if (original) |v| {
            _ = env_os.setenv("XDG_STATE_HOME", v);
        } else {
            _ = env_os.unsetenv("XDG_STATE_HOME");
        }
    }

    const state_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(state_path);
    const state_path_z = try alloc.dupeZ(u8, state_path);
    defer alloc.free(state_path_z);
    _ = env_os.setenv("XDG_STATE_HOME", state_path_z);

    try save(alloc, .{
        .name = "example",
        .command = "shell:ssh example.com",
        .status_command = "shell:ssh example.com -- status",
        .class = "com.example.ghostty",
        .target = "example.com",
        .control_path = "/tmp/ghostty.sock",
        .mux_backend = "tmux",
        .mux_session = "example",
        .remote_helper_version = "1",
        .created = 123,
        .last_seen = 456,
    });

    var session = try load(alloc, "example");
    defer session.deinit(alloc);

    try testing.expectEqualStrings("example", session.name);
    try testing.expectEqualStrings("shell:ssh example.com", session.command);
    try testing.expectEqualStrings("shell:ssh example.com -- status", session.status_command.?);
    try testing.expectEqualStrings("com.example.ghostty", session.class.?);
    try testing.expectEqualStrings("example.com", session.target);
    try testing.expectEqualStrings("/tmp/ghostty.sock", session.control_path);
    try testing.expectEqualStrings("tmux", session.mux_backend.?);
    try testing.expectEqualStrings("example", session.mux_session.?);
    try testing.expectEqualStrings("1", session.remote_helper_version.?);
    try testing.expectEqual(@as(i64, 123), session.created);
    try testing.expectEqual(@as(i64, 456), session.last_seen);
}

test "load legacy version 1 metadata" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const original = std.posix.getenv("XDG_STATE_HOME");
    defer {
        if (original) |v| {
            _ = env_os.setenv("XDG_STATE_HOME", v);
        } else {
            _ = env_os.unsetenv("XDG_STATE_HOME");
        }
    }

    const state_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(state_path);
    const state_path_z = try alloc.dupeZ(u8, state_path);
    defer alloc.free(state_path_z);
    _ = env_os.setenv("XDG_STATE_HOME", state_path_z);

    const sessions_dir = try sessionsDir(alloc);
    defer alloc.free(sessions_dir);
    try std.fs.cwd().makePath(sessions_dir);

    const path = try sessionPath(alloc, "legacy");
    defer alloc.free(path);

    var file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(
        "version=1\n" ++
            "name=legacy\n" ++
            "command=shell:ssh legacy.example\n" ++
            "target=legacy.example\n" ++
            "control_path=/tmp/legacy.sock\n" ++
            "created=42\n",
    );

    var session = try load(alloc, "legacy");
    defer session.deinit(alloc);

    try testing.expectEqualStrings("legacy", session.name);
    try testing.expectEqualStrings("shell:ssh legacy.example", session.command);
    try testing.expect(session.status_command == null);
    try testing.expect(session.mux_backend == null);
    try testing.expect(session.mux_session == null);
    try testing.expectEqual(@as(i64, 42), session.created);
    try testing.expectEqual(@as(i64, 42), session.last_seen);
}

test "save and load multiline command with base64 encoding" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const original = std.posix.getenv("XDG_STATE_HOME");
    defer {
        if (original) |v| {
            _ = env_os.setenv("XDG_STATE_HOME", v);
        } else {
            _ = env_os.unsetenv("XDG_STATE_HOME");
        }
    }

    const state_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(state_path);
    const state_path_z = try alloc.dupeZ(u8, state_path);
    defer alloc.free(state_path_z);
    _ = env_os.setenv("XDG_STATE_HOME", state_path_z);

    try save(alloc, .{
        .name = "multiline",
        .command = "shell:ssh host sh -lc 'line1\nline2'",
        .target = "host",
        .control_path = "/tmp/m.sock",
        .created = 77,
        .last_seen = 77,
    });

    var session = try load(alloc, "multiline");
    defer session.deinit(alloc);

    try testing.expectEqualStrings("shell:ssh host sh -lc 'line1\nline2'", session.command);
}
