const std = @import("std");
const c = @cImport({
    @cInclude("ApplicationServices/ApplicationServices.h");
    @cInclude("CoreFoundation/CoreFoundation.h");
});

/// Send Command-R keystroke to the frontmost application
fn sendCommandR() !void {
    // Ensure the process is trusted for accessibility (required to post keyboard events)
    if (c.AXIsProcessTrusted() == 0) {
        std.debug.print("✗ Accessibility permission required. Add picowatch to System Settings > Privacy & Security > Accessibility.\n", .{});
        return error.AccessibilityNotTrusted;
    }

    // Create an event source for synthesized events within the current session
    const source = c.CGEventSourceCreate(c.kCGEventSourceStateCombinedSessionState);
    defer c.CFRelease(source);

    // Key codes
    const keyCodeR: c.CGKeyCode = 15; // 'r'
    const keyCodeCmd: c.CGKeyCode = 55; // Command (left)

    // Create events: Cmd down, R down, R up, Cmd up
    const cmdDown = c.CGEventCreateKeyboardEvent(source, keyCodeCmd, true);
    defer c.CFRelease(cmdDown);

    const rDown = c.CGEventCreateKeyboardEvent(source, keyCodeR, true);
    defer c.CFRelease(rDown);
    // Ensure Command flag is present on the character event
    c.CGEventSetFlags(rDown, c.kCGEventFlagMaskCommand);

    const rUp = c.CGEventCreateKeyboardEvent(source, keyCodeR, false);
    defer c.CFRelease(rUp);
    c.CGEventSetFlags(rUp, c.kCGEventFlagMaskCommand);

    const cmdUp = c.CGEventCreateKeyboardEvent(source, keyCodeCmd, false);
    defer c.CFRelease(cmdUp);

    // Post events with small delays to ensure the target app processes them
    c.CGEventPost(c.kCGSessionEventTap, cmdDown);
    std.Thread.sleep(30_000_000); // 30 ms

    c.CGEventPost(c.kCGSessionEventTap, rDown);
    std.Thread.sleep(30_000_000); // 30 ms

    c.CGEventPost(c.kCGSessionEventTap, rUp);
    std.Thread.sleep(30_000_000); // 30 ms

    c.CGEventPost(c.kCGSessionEventTap, cmdUp);
}

/// Activate PICO-8 application using osascript
fn activatePico8(allocator: std.mem.Allocator) !void {
    const argv = [_][]const u8{
        "osascript",
        "-e",
        "tell application \"PICO-8\" to activate",
    };

    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    // We don't check the result because the app might not be running,
    // but we'll still try to send the keystroke
    _ = child.spawn() catch return;
    _ = child.wait() catch return;
}

const FileInfo = struct {
    path: []const u8,
    mtime: i128,
};

const Watcher = struct {
    watch_path: []const u8,
    allocator: std.mem.Allocator,
    files: std.ArrayList(FileInfo),
    debounce_ns: u64,
    last_reload_time: i128,
    is_directory: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, watch_path: []const u8) !Self {
        var files: std.ArrayList(FileInfo) = .{};

        // Check if path is a file or directory
        const stat = std.fs.cwd().statFile(watch_path) catch |err| {
            std.debug.print("✗ Error: Path not found: {s}\n", .{watch_path});
            return err;
        };

        const is_directory = stat.kind == .directory;

        if (is_directory) {
            // Scan directory for .lua and .p8 files
            try scanDirectory(allocator, watch_path, &files);
            if (files.items.len == 0) {
                std.debug.print("⚠ Warning: No .lua or .p8 files found in directory: {s}\n", .{watch_path});
            }
        } else {
            // Single file mode
            const path_copy = try allocator.dupe(u8, watch_path);
            try files.append(allocator, .{
                .path = path_copy,
                .mtime = stat.mtime,
            });
        }

        return Self{
            .watch_path = watch_path,
            .allocator = allocator,
            .files = files,
            .debounce_ns = 100_000_000, // 100ms debounce
            .last_reload_time = 0,
            .is_directory = is_directory,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.files.items) |file_info| {
            self.allocator.free(file_info.path);
        }
        self.files.deinit(self.allocator);
    }

    fn scanDirectory(allocator: std.mem.Allocator, dir_path: []const u8, files: *std.ArrayList(FileInfo)) !void {
        var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;

            // Check if file has .lua or .p8 extension
            const ext = std.fs.path.extension(entry.name);
            if (!std.mem.eql(u8, ext, ".lua") and !std.mem.eql(u8, ext, ".p8")) {
                continue;
            }

            // Build full path
            const full_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });

            // Get modification time
            const stat = try dir.statFile(entry.name);

            try files.append(allocator, .{
                .path = full_path,
                .mtime = stat.mtime,
            });
        }
    }

    pub fn watch(self: *Self) !void {
        std.debug.print("🎮 PICO-8 Auto-Reload Watcher (Pure Zig)\n", .{});
        if (self.is_directory) {
            std.debug.print("📁 Watching directory: {s}\n", .{self.watch_path});
            std.debug.print("📄 Monitoring {d} file(s) (.lua, .p8)\n", .{self.files.items.len});
        } else {
            std.debug.print("📁 Watching file: {s}\n", .{self.watch_path});
        }
        std.debug.print("👀 Waiting for changes... (Press Ctrl+C to stop)\n\n", .{});

        while (true) {
            // Sleep for a bit before checking again
            std.Thread.sleep(50_000_000); // 50ms polling interval

            // If watching a directory, rescan for new files
            if (self.is_directory) {
                var new_files: std.ArrayList(FileInfo) = .{};
                try scanDirectory(self.allocator, self.watch_path, &new_files);

                // Check for new files that weren't in our list before
                for (new_files.items) |new_file| {
                    var found = false;
                    for (self.files.items) |existing| {
                        if (std.mem.eql(u8, existing.path, new_file.path)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        const path_copy = try self.allocator.dupe(u8, new_file.path);
                        try self.files.append(self.allocator, .{
                            .path = path_copy,
                            .mtime = new_file.mtime,
                        });
                        std.debug.print("➕ Now watching new file: {s}\n", .{std.fs.path.basename(path_copy)});
                    }
                }

                // Clean up temporary scan
                for (new_files.items) |file_info| {
                    self.allocator.free(file_info.path);
                }
                new_files.deinit(self.allocator);
            }

            // Check each file for modifications
            for (self.files.items) |*file_info| {
                const file = std.fs.cwd().openFile(file_info.path, .{}) catch |err| {
                    // File might have been deleted, skip it
                    if (err == error.FileNotFound) continue;
                    std.debug.print("✗ Error opening file {s}: {}\n", .{ file_info.path, err });
                    continue;
                };
                defer file.close();

                const stat = file.stat() catch |err| {
                    std.debug.print("✗ Error getting file stats for {s}: {}\n", .{ file_info.path, err });
                    continue;
                };

                const current_mtime = stat.mtime;

                // Check if file has been modified
                if (current_mtime > file_info.mtime) {
                    const now = std.time.nanoTimestamp();

                    // Debounce: only reload if enough time has passed since last reload
                    if (now - self.last_reload_time > self.debounce_ns) {
                        std.debug.print("✓ Detected change in {s}\n", .{std.fs.path.basename(file_info.path)});
                        try self.reload();
                        self.last_reload_time = now;
                    }

                    file_info.mtime = current_mtime;
                }
            }
        }
    }

    fn reload(self: *Self) !void {
        // Activate PICO-8
        activatePico8(self.allocator) catch |err| {
            std.debug.print("⚠ Could not activate PICO-8: {}\n", .{err});
        };

        // Wait a bit for the app to come to foreground
        std.Thread.sleep(700_000_000); // 700ms

        // Send Command-R
        sendCommandR() catch |err| {
            std.debug.print("✗ Error sending Command-R: {}\n", .{err});
            return err;
        };

        std.debug.print("→ Sent reload command to PICO-8\n", .{});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command-line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <path_to_file_or_directory>\n", .{args[0]});
        std.debug.print("\nExamples:\n", .{});
        std.debug.print("  Watch a single file:\n", .{});
        std.debug.print("    {s} ~/pico-8/carts/mygame.p8\n", .{args[0]});
        std.debug.print("  Watch a directory (monitors all .lua and .p8 files):\n", .{});
        std.debug.print("    {s} ~/pico-8/carts/mygame/\n", .{args[0]});
        std.process.exit(1);
    }

    const watch_path = args[1];

    // Create and start watcher
    var watcher = try Watcher.init(allocator, watch_path);
    defer watcher.deinit();
    try watcher.watch();
}
