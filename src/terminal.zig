const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const windows = std.os.windows;

const builtin = @import("builtin");

pub const Terminal = struct {
    mode_start: ?*const anyopaque,
    stdin: std.io.BufferedReader(4096, std.fs.File.Reader),
    // These are made optional so that printing on failure can be disabled in tests expecting them.
    stdout: ?std.fs.File.Writer,
    stderr: ?std.fs.File.Writer,

    pub fn init(
        allocator: std.mem.Allocator,
        interactive: bool,
    ) !Terminal {
        const stdout = std.io.getStdOut();
        if (interactive and !stdout.getOrEnableAnsiEscapeSupport()) {
            std.debug.print("ANSI escape sequences not supported.\n", .{});
            std.process.exit(1);
        }

        const stdin = std.io.getStdIn();
        var mode_start: ?*const anyopaque = null;
        if (interactive) {
            if (builtin.os.tag == .windows) {
                var mode_stdin: u32 = 0;
                if (windows.kernel32.GetConsoleMode(stdin.handle, &mode_stdin) == 0) {
                    return windows.unexpectedError(windows.kernel32.GetLastError());
                }

                var mode_stdout: u32 = 0;
                if (windows.kernel32.GetConsoleMode(stdout.handle, &mode_stdout) == 0) {
                    return windows.unexpectedError(windows.kernel32.GetLastError());
                }

                const windows_console_mode = try allocator.create(WindowsConsoleMode);
                windows_console_mode.*.stdin = mode_stdin;
                windows_console_mode.*.stdout = mode_stdout;
                mode_start = @ptrCast(windows_console_mode);
            } else {
                const termios = try allocator.create(posix.termios);
                termios.* = try posix.tcgetattr(stdin.handle);
                mode_start = @ptrCast(termios);
            }
        }

        return Terminal{
            .mode_start = mode_start,
            .stdin = std.io.bufferedReader(stdin.reader()),
            .stdout = stdout.writer(),
            .stderr = std.io.getStdErr().writer(),
        };
    }

    pub fn print(
        self: *const Terminal,
        comptime format: []const u8,
        arguments: anytype,
    ) !void {
        if (self.stdout) |stdout| {
            try stdout.print(format, arguments);
        }
    }

    pub fn print_error(
        self: *const Terminal,
        comptime format: []const u8,
        arguments: anytype,
    ) !void {
        if (self.stderr) |stderr| {
            try stderr.print(format, arguments);
        }
    }

    pub fn read_user_input(self: *Terminal) !?UserInput {
        assert(self.mode_start != null);
        const stdin = self.stdin.reader().any();

        switch (try stdin.readByte()) {
            std.ascii.control_code.eot => return null,
            std.ascii.control_code.cr, std.ascii.control_code.lf => return .newline,
            std.ascii.control_code.bs, std.ascii.control_code.del => return .backspace,
            std.ascii.control_code.esc => {
                const second_byte = try stdin.readByte();
                switch (second_byte) {
                    '[' => {
                        const third_byte = try stdin.readByte();
                        switch (third_byte) {
                            'C' => return .right,
                            'D' => return .left,
                            else => return .unhandled,
                        }
                    },
                    else => return .unhandled,
                }
            },
            else => |byte| {
                if (std.ascii.isPrint(byte)) {
                    return .{ .printable = byte };
                }
                return .unhandled;
            },
        }
    }

    pub fn prompt_mode_set(self: *const Terminal) anyerror!void {
        assert(self.mode_start != null);
        const stdin = std.io.getStdIn();
        if (builtin.os.tag == .windows) {
            const console_mode: *const WindowsConsoleMode = @alignCast(@ptrCast(self.mode_start));

            var mode_stdin: u32 = console_mode.*.stdin;
            mode_stdin &= ~@intFromEnum(WindowsConsoleMode.Input.enable_line_input);
            mode_stdin &= ~@intFromEnum(WindowsConsoleMode.Input.enable_echo_input);
            mode_stdin |= @intFromEnum(WindowsConsoleMode.Input.enable_virtual_terminal_input);
            if (windows.kernel32.SetConsoleMode(stdin.handle, mode_stdin) == 0) {
                return windows.unexpectedError(windows.kernel32.GetLastError());
            }

            var mode_stdout: u32 = console_mode.*.stdout;
            mode_stdout |= @intFromEnum(WindowsConsoleMode.Output.enable_processed_output);
            mode_stdout |= @intFromEnum(WindowsConsoleMode.Output.enable_wrap_at_eol_output);
            mode_stdout |= @intFromEnum(
                WindowsConsoleMode.Output.enable_virtual_terminal_processing,
            );
            mode_stdout &= ~@intFromEnum(WindowsConsoleMode.Output.disable_newline_auto_return);
            if (windows.kernel32.SetConsoleMode(std.io.getStdOut().handle, mode_stdout) == 0) {
                return windows.unexpectedError(windows.kernel32.GetLastError());
            }
        } else {
            const termios_start: *const posix.termios = @alignCast(@ptrCast(self.mode_start));

            var termios_new = termios_start.*;
            termios_new.lflag.ECHO = false;
            termios_new.lflag.ICANON = false;
            termios_new.cc[@intFromEnum(posix.V.MIN)] = 1;
            termios_new.cc[@intFromEnum(posix.V.TIME)] = 0;
            try posix.tcsetattr(stdin.handle, .NOW, termios_new);
        }
    }

    pub fn prompt_mode_unset(self: *const Terminal) !void {
        assert(self.mode_start != null);
        const stdin = std.io.getStdIn();
        if (builtin.os.tag == .windows) {
            const console_mode: *const WindowsConsoleMode = @alignCast(@ptrCast(self.mode_start));
            if (windows.kernel32.SetConsoleMode(stdin.handle, console_mode.stdin) == 0) {
                return windows.unexpectedError(windows.kernel32.GetLastError());
            }
            const stdout = std.io.getStdOut();
            if (windows.kernel32.SetConsoleMode(stdout.handle, console_mode.stdout) == 0) {
                return windows.unexpectedError(windows.kernel32.GetLastError());
            }
        } else {
            const termios: *const posix.termios = @alignCast(@ptrCast(self.mode_start));
            try posix.tcsetattr(std.io.getStdIn().handle, .NOW, termios.*);
        }
    }

    fn get_cursor_position(
        self: *Terminal,
        allocator: std.mem.Allocator,
    ) !struct { row: usize, column: usize } {
        // Obtaining the cursor's position relies on sending a request payload to stdout. The
        // response is read from stdin, but it may have been altered by user input, so we keep
        // retrying until successful.
        const stdin = self.stdin.reader().any();
        var buffer = std.ArrayList(u8).init(allocator);
        while (true) {
            // The response is of the form `<ESC>[{row};{col}R`.
            try self.print("\x1b[6n", .{});
            buffer.clearRetainingCapacity();
            try stdin.streamUntilDelimiter(buffer.writer(), '[', null);

            buffer.clearRetainingCapacity();
            try stdin.streamUntilDelimiter(buffer.writer(), ';', null);
            const row = std.fmt.parseInt(usize, buffer.items, 10) catch continue;

            buffer.clearRetainingCapacity();
            try stdin.streamUntilDelimiter(buffer.writer(), 'R', null);
            const column = std.fmt.parseInt(usize, buffer.items, 10) catch continue;

            return .{
                .row = row,
                .column = column,
            };
        }
    }

    pub fn get_screen(
        self: *Terminal,
        allocator: std.mem.Allocator,
    ) !Screen {
        // We move the cursor to a location that is unlikely to exist (2^16th row and column).
        // Terminals usually handle this by placing the cursor at their end position, which we can
        // use to obtain its resolution/size.
        const cursor_start = try self.get_cursor_position(allocator);
        try self.print("\x1b[{};{}H", .{ std.math.maxInt(u16), std.math.maxInt(u16) });

        const cursor_end = try self.get_cursor_position(allocator);
        try self.print("\x1b[{};{}H", .{ cursor_start.row, cursor_start.column });

        return Screen{
            .rows = cursor_end.row,
            .columns = cursor_end.column,
            .cursor_row = cursor_start.row,
            .cursor_column = cursor_start.column,
        };
    }
};

const Screen = struct {
    rows: usize,
    columns: usize,
    cursor_row: usize,
    cursor_column: usize,

    pub fn update_cursor_position(self: *Screen, delta: isize) void {
        if (delta == 0) return;

        // Rows and columns in terminals are one-based indexed. For simple manipulation across the
        // grid, we map it to a zero-based index array of cells. When experiencing overflows on
        // either end, we always saturate them such that they remain within the first or last row of
        // the terminal (assuming a fixed size).
        const cell_total: isize = @intCast(self.rows * self.columns);
        const cell_index_current: isize = @intCast(
            (self.cursor_row - 1) * self.columns + (self.cursor_column - 1),
        );
        assert(cell_index_current >= 0 and cell_index_current < cell_total);

        const cell_index_last: isize = @intCast(cell_total - 1);
        const column_total: isize = @intCast(self.columns);

        var cell_index_after_delta: isize = cell_index_current + delta;
        if (cell_index_after_delta > cell_index_last) {
            const cell_index_row_n_col_1 = cell_total - column_total;
            const cell_extra = cell_index_after_delta - cell_index_last;
            cell_index_after_delta = cell_index_row_n_col_1 + @rem((cell_extra - 1), column_total);
        } else if (cell_index_after_delta < 0) {
            const cell_index_row_1_col_n = column_total - 1;
            const cell_extra: isize = @intCast(@abs(cell_index_after_delta));
            cell_index_after_delta = cell_index_row_1_col_n - @rem((cell_extra - 1), column_total);
        }

        const row_after_delta = @divTrunc(cell_index_after_delta, column_total) + 1;
        const column_after_delta = @rem(cell_index_after_delta, column_total) + 1;

        assert(row_after_delta >= 1 and row_after_delta <= self.rows);
        assert(column_after_delta >= 1 and column_after_delta <= self.columns);

        self.cursor_row = @intCast(row_after_delta);
        self.cursor_column = @intCast(column_after_delta);
    }
};

const UserInput = union(enum) {
    printable: u8,
    newline,
    backspace,
    left,
    right,
    unhandled,
};

const WindowsConsoleMode = struct {
    stdin: u32,
    stdout: u32,

    const Input = enum(u32) {
        enable_line_input = 0x0002,
        enable_echo_input = 0x0004,
        enable_virtual_terminal_input = 0x0200,
    };

    const Output = enum(u32) {
        enable_processed_output = 0x0001,
        enable_wrap_at_eol_output = 0x0002,
        enable_virtual_terminal_processing = 0x0004,
        disable_newline_auto_return = 0x0008,
    };
};

test "terminal.zig: Terminal cursor position change is valid" {
    const tests = [_]struct {
        rows: usize,
        columns: usize,
        row_source: usize,
        column_source: usize,
        delta: isize,
        row_destination: usize,
        column_destination: usize,
    }{
        .{
            .rows = 10,
            .columns = 10,
            .row_source = 1,
            .column_source = 1,
            .delta = -32,
            .row_destination = 1,
            .column_destination = 9,
        },
        .{
            .rows = 10,
            .columns = 10,
            .row_source = 1,
            .column_source = 1,
            .delta = -1,
            .row_destination = 1,
            .column_destination = 10,
        },
        .{
            .rows = 10,
            .columns = 10,
            .row_source = 1,
            .column_source = 2,
            .delta = -1,
            .row_destination = 1,
            .column_destination = 1,
        },
        .{
            .rows = 10,
            .columns = 10,
            .row_source = 3,
            .column_source = 8,
            .delta = -26,
            .row_destination = 1,
            .column_destination = 2,
        },
        .{
            .rows = 10,
            .columns = 10,
            .row_source = 2,
            .column_source = 9,
            .delta = 0,
            .row_destination = 2,
            .column_destination = 9,
        },
        .{
            .rows = 10,
            .columns = 10,
            .row_source = 2,
            .column_source = 9,
            .delta = 61,
            .row_destination = 8,
            .column_destination = 10,
        },
        .{
            .rows = 10,
            .columns = 10,
            .row_source = 10,
            .column_source = 9,
            .delta = 1,
            .row_destination = 10,
            .column_destination = 10,
        },
        .{
            .rows = 10,
            .columns = 10,
            .row_source = 10,
            .column_source = 10,
            .delta = 1,
            .row_destination = 10,
            .column_destination = 1,
        },
        .{
            .rows = 10,
            .columns = 10,
            .row_source = 10,
            .column_source = 10,
            .delta = 21,
            .row_destination = 10,
            .column_destination = 1,
        },
    };

    for (tests) |t| {
        var screen = Screen{
            .rows = t.rows,
            .columns = t.columns,
            .cursor_row = t.row_source,
            .cursor_column = t.column_source,
        };
        screen.update_cursor_position(t.delta);
        try std.testing.expectEqual(screen.cursor_row, t.row_destination);
        try std.testing.expectEqual(screen.cursor_column, t.column_destination);
    }
}
