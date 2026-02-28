const std = @import("std");
const Allocator = std.mem.Allocator;

pub const backend_name = "tmux";
pub const helper_version = "1";

pub const Operation = enum {
    attach,
    ensure,
    status,
    describe,
};

pub const CommandSpec = struct {
    operation: Operation = .attach,
    session: []const u8,
    initial_command: []const []const u8 = &.{},
};

pub const CommandArgs = struct {
    args: []const []const u8,

    pub fn deinit(self: *CommandArgs, alloc: Allocator) void {
        for (self.args) |arg| alloc.free(arg);
        alloc.free(self.args);
        self.* = undefined;
    }
};

pub const ProbeStatus = enum {
    online,
    offline,
    unknown,
};

pub fn parseProbeStatus(output: []const u8) ProbeStatus {
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "online")) return .online;
    if (std.mem.eql(u8, trimmed, "offline")) return .offline;
    return .unknown;
}

pub fn buildCommandArgs(alloc: Allocator, spec: CommandSpec) !CommandArgs {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (args.items) |arg| alloc.free(arg);
        args.deinit(alloc);
    }

    const script = try buildBootstrapScript(alloc);

    try args.append(alloc, try alloc.dupe(u8, "sh"));
    try args.append(alloc, try alloc.dupe(u8, "-lc"));
    try args.append(alloc, script);
    try args.append(alloc, try alloc.dupe(u8, "ghostty-remote-mux"));
    try args.append(alloc, try alloc.dupe(u8, operationString(spec.operation)));
    try args.append(alloc, try alloc.dupe(u8, spec.session));

    if (spec.initial_command.len > 0 and (spec.operation == .attach or spec.operation == .ensure)) {
        try args.append(alloc, try alloc.dupe(u8, "--"));
        for (spec.initial_command) |arg| {
            try args.append(alloc, try alloc.dupe(u8, arg));
        }
    }

    return .{ .args = try args.toOwnedSlice(alloc) };
}

fn operationString(op: Operation) []const u8 {
    return switch (op) {
        .attach => "attach",
        .ensure => "ensure",
        .status => "status",
        .describe => "describe",
    };
}

fn buildBootstrapScript(alloc: Allocator) ![]const u8 {
    return std.fmt.allocPrint(alloc,
        \\set -eu
        \\base="${{XDG_DATA_HOME:-$HOME/.local/share}}/ghostty"
        \\script="$base/remote-mux.sh"
        \\if [ ! -x "$script" ] || ! grep -q '^# ghostty-remote-mux-version:{s}$' "$script" 2>/dev/null; then
        \\  umask 077
        \\  mkdir -p "$base"
        \\  cat > "$script" <<'__GHOSTTY_REMOTE_MUX__'
        \\{s}
        \\__GHOSTTY_REMOTE_MUX__
        \\  chmod 700 "$script"
        \\fi
        \\exec "$script" "$@"
    , .{ helper_version, helperScript() });
}

fn helperScript() []const u8 {
    return 
    \\#!/bin/sh
    \\# ghostty-remote-mux-version:1
    \\set -eu
    \\
    \\cmd="${1:-attach}"
    \\if [ "$#" -gt 0 ]; then shift; fi
    \\session="${1:-}"
    \\if [ "$#" -gt 0 ]; then shift; fi
    \\
    \\if [ -z "$session" ]; then
    \\  echo "ghostty remote mux: missing session name" >&2
    \\  exit 64
    \\fi
    \\
    \\case "$cmd" in
    \\  attach|ensure|status|describe) ;;
    \\  *)
    \\    echo "ghostty remote mux: unknown command: $cmd" >&2
    \\    exit 64
    \\    ;;
    \\esac
    \\
    \\if ! command -v tmux >/dev/null 2>&1; then
    \\  echo "ghostty remote mux: tmux is required on remote host but not installed" >&2
    \\  exit 69
    \\fi
    \\
    \\if [ "$cmd" = "status" ]; then
    \\  if tmux has-session -t "=$session" 2>/dev/null; then
    \\    echo online
    \\  else
    \\    echo offline
    \\  fi
    \\  exit 0
    \\fi
    \\
    \\if [ "$cmd" = "describe" ]; then
    \\  if tmux has-session -t "=$session" 2>/dev/null; then
    \\    tmux display-message -p -t "=$session" 'session=#{session_name} windows=#{session_windows} created=#{session_created}'
    \\  else
    \\    echo "session=$session windows=0 created=0"
    \\  fi
    \\  exit 0
    \\fi
    \\
    \\if ! tmux has-session -t "=$session" 2>/dev/null; then
    \\  if [ "$#" -gt 0 ] && [ "$1" = "--" ]; then
    \\    shift
    \\  fi
    \\
    \\  if [ "$#" -gt 0 ]; then
    \\    tmux new-session -d -s "$session" "$@"
    \\  else
    \\    tmux new-session -d -s "$session"
    \\  fi
    \\fi
    \\
    \\if [ "$cmd" = "ensure" ]; then
    \\  exit 0
    \\fi
    \\
    \\exec tmux attach -t "=$session"
    ;
}

test "build command args for attach includes bootstrap and command passthrough" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cmd = try buildCommandArgs(alloc, .{
        .operation = .attach,
        .session = "prod",
        .initial_command = &.{ "nvim", "-u", "NONE" },
    });
    defer cmd.deinit(alloc);

    try testing.expectEqualStrings("sh", cmd.args[0]);
    try testing.expectEqualStrings("-lc", cmd.args[1]);
    try testing.expect(std.mem.indexOf(u8, cmd.args[2], "ghostty-remote-mux-version:1") != null);
    try testing.expectEqualStrings("attach", cmd.args[4]);
    try testing.expectEqualStrings("prod", cmd.args[5]);
    try testing.expectEqualStrings("--", cmd.args[6]);
    try testing.expectEqualStrings("nvim", cmd.args[7]);
}

test "build command args for status does not include passthrough command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cmd = try buildCommandArgs(alloc, .{
        .operation = .status,
        .session = "prod",
        .initial_command = &.{"ignored"},
    });
    defer cmd.deinit(alloc);

    try testing.expectEqualStrings("status", cmd.args[4]);
    try testing.expectEqual(@as(usize, 6), cmd.args.len);
}

test "parse probe status" {
    const testing = std.testing;

    try testing.expect(parseProbeStatus("online\n") == .online);
    try testing.expect(parseProbeStatus("offline") == .offline);
    try testing.expect(parseProbeStatus("unexpected") == .unknown);
}
