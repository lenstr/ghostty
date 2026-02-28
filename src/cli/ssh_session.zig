const std = @import("std");
const Allocator = std.mem.Allocator;
const internal_os = @import("../os/main.zig");
const env_os = @import("../os/env.zig");
const xdg = internal_os.xdg;

pub const Session = struct {
    name: []const u8,
    command: []const u8,
    class: ?[]const u8 = null,
    target: []const u8,
    control_path: []const u8,
    created: i64,

    pub fn deinit(self: *Session, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.command);
        if (self.class) |class| alloc.free(class);
        alloc.free(self.target);
        alloc.free(self.control_path);
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

        if (c == '_' or c == '.' or c == '-') {
            try buf.append(alloc, c);
            last_dash = false;
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

    try writer.print("version=1\n", .{});
    try writer.print("name={s}\n", .{session.name});
    try writer.print("command={s}\n", .{session.command});
    try writer.print("target={s}\n", .{session.target});
    try writer.print("control_path={s}\n", .{session.control_path});
    try writer.print("created={d}\n", .{session.created});
    if (session.class) |class| {
        try writer.print("class={s}\n", .{class});
    }

    try writer.flush();
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
    var class: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var control_path: ?[]const u8 = null;
    var created: i64 = 0;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const i = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..i];
        const value = line[i + 1 ..];

        if (std.mem.eql(u8, key, "command")) {
            command = try alloc.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "class")) {
            class = try alloc.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "target")) {
            target = try alloc.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "control_path")) {
            control_path = try alloc.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "created")) {
            created = std.fmt.parseInt(i64, value, 10) catch 0;
        }
    }

    errdefer {
        if (command) |v| alloc.free(v);
        if (class) |v| alloc.free(v);
        if (target) |v| alloc.free(v);
        if (control_path) |v| alloc.free(v);
    }

    if (command == null or target == null or control_path == null) {
        return error.InvalidSessionFile;
    }

    return .{
        .name = try alloc.dupe(u8, name),
        .command = command.?,
        .class = class,
        .target = target.?,
        .control_path = control_path.?,
        .created = created,
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

    try testing.expectEqualStrings("user-example.com-2200", name);
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
        .class = "com.example.ghostty",
        .target = "example.com",
        .control_path = "/tmp/ghostty.sock",
        .created = 123,
    });

    var session = try load(alloc, "example");
    defer session.deinit(alloc);

    try testing.expectEqualStrings("example", session.name);
    try testing.expectEqualStrings("shell:ssh example.com", session.command);
    try testing.expectEqualStrings("com.example.ghostty", session.class.?);
    try testing.expectEqualStrings("example.com", session.target);
    try testing.expectEqualStrings("/tmp/ghostty.sock", session.control_path);
    try testing.expectEqual(@as(i64, 123), session.created);
}
