const std = @import("std");
const core = @import("core");

const c = @cImport({
    @cInclude("whisper.h");
});

const LOCK_WAIT_MS: i64 = 2_000;
const STOP_START_WAIT_MS: usize = 1_000;
const TINY_EN_SHA1 = "c78c86eb1a8faa21b369bcd33207cc90d64ae9df";

fn discardWhisperLog(_: c.enum_ggml_log_level, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {}

fn whisperAbort(user_data: ?*anyopaque) callconv(.c) bool {
    const raw = user_data orelse return false;
    const path: [*:0]const u8 = @ptrCast(raw);
    std.fs.cwd().access(std.mem.span(path), .{}) catch return false;
    return true;
}

pub const State = enum { idle, recording, transcribing };

pub const Transcript = struct {
    pane_uuid: [32]u8,
    text: []u8,

    pub fn deinit(self: *Transcript, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

const ProcessIdentity = struct {
    pid: std.posix.pid_t,
    start_ticks: u64,
};

const RuntimeLock = struct {
    allocator: std.mem.Allocator,
    path: []u8,

    fn release(self: *RuntimeLock) void {
        std.fs.cwd().deleteTree(self.path) catch {};
        self.allocator.free(self.path);
        self.* = undefined;
    }
};

fn runtimeDir(allocator: std.mem.Allocator) ![]u8 {
    const base = try core.ipc.getSocketDir(allocator);
    defer allocator.free(base);
    const dir = try std.fs.path.join(allocator, &.{ base, "speech" });
    errdefer allocator.free(dir);
    try core.ipc.ensurePrivateDir(dir);
    return dir;
}

fn modelPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.posix.getenv("HEXE_WHISPER_MODEL")) |path| return allocator.dupe(u8, path);
    if (std.posix.getenv("XDG_DATA_HOME")) |base| {
        return std.fmt.allocPrint(allocator, "{s}/hexe/models/ggml-tiny.en.bin", .{base});
    }
    const home = std.posix.getenv("HOME") orelse return error.HomeUnavailable;
    return std.fmt.allocPrint(allocator, "{s}/.local/share/hexe/models/ggml-tiny.en.bin", .{home});
}

fn pathFor(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ dir, name });
}

fn writeAtomic(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const temp = try std.fmt.allocPrint(allocator, "{s}.{d}.tmp", .{ path, std.os.linux.getpid() });
    defer allocator.free(temp);
    errdefer std.fs.cwd().deleteFile(temp) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = temp, .data = data });
    try std.fs.cwd().rename(temp, path);
}

fn parseProcessStartTicks(stat: []const u8) !u64 {
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return error.InvalidProcStat;
    var fields = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
    var index: usize = 0;
    while (fields.next()) |field| : (index += 1) {
        if (index == 19) return std.fmt.parseInt(u64, field, 10);
    }
    return error.InvalidProcStat;
}

fn processStartTicks(allocator: std.mem.Allocator, pid: std.posix.pid_t) !u64 {
    const path = try std.fmt.allocPrint(allocator, "/proc/{d}/stat", .{pid});
    defer allocator.free(path);
    const raw = try std.fs.cwd().readFileAlloc(allocator, path, 4096);
    defer allocator.free(raw);
    return parseProcessStartTicks(raw);
}

fn currentIdentity(allocator: std.mem.Allocator) !ProcessIdentity {
    const pid: std.posix.pid_t = @intCast(std.os.linux.getpid());
    return .{ .pid = pid, .start_ticks = try processStartTicks(allocator, pid) };
}

fn processMatches(allocator: std.mem.Allocator, identity: ProcessIdentity) bool {
    if (identity.pid <= 0 or identity.start_ticks == 0) return false;
    std.posix.kill(identity.pid, 0) catch return false;
    const ticks = processStartTicks(allocator, identity.pid) catch return false;
    return ticks == identity.start_ticks;
}

fn formatIdentity(buffer: []u8, identity: ProcessIdentity) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{d} {d}\n", .{ identity.pid, identity.start_ticks });
}

fn parseIdentity(raw: []const u8) !ProcessIdentity {
    var fields = std.mem.tokenizeAny(u8, raw, " \t\r\n");
    const pid = try std.fmt.parseInt(std.posix.pid_t, fields.next() orelse return error.InvalidIdentity, 10);
    const ticks = try std.fmt.parseInt(u64, fields.next() orelse return error.InvalidIdentity, 10);
    if (pid <= 0 or ticks == 0) return error.InvalidIdentity;
    return .{ .pid = pid, .start_ticks = ticks };
}

fn readIdentity(allocator: std.mem.Allocator, path: []const u8) !?ProcessIdentity {
    const raw = std.fs.cwd().readFileAlloc(allocator, path, 128) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(raw);
    return parseIdentity(raw) catch null;
}

fn writeIdentity(allocator: std.mem.Allocator, path: []const u8, identity: ProcessIdentity) !void {
    var buffer: [96]u8 = undefined;
    try writeAtomic(allocator, path, try formatIdentity(&buffer, identity));
}

fn acquireLock(allocator: std.mem.Allocator, dir: []const u8) !RuntimeLock {
    try core.ipc.ensurePrivateDir(dir);
    const lock_path = try pathFor(allocator, dir, "lock");
    errdefer allocator.free(lock_path);
    const owner_path = try pathFor(allocator, lock_path, "owner");
    defer allocator.free(owner_path);
    const deadline = std.time.milliTimestamp() + LOCK_WAIT_MS;
    var missing_owner_since: ?i64 = null;

    while (true) {
        std.fs.cwd().makeDir(lock_path) catch |err| switch (err) {
            error.PathAlreadyExists => {
                const owner = try readIdentity(allocator, owner_path);
                if (owner == null or !processMatches(allocator, owner.?)) {
                    if (owner == null) {
                        const now = std.time.milliTimestamp();
                        if (missing_owner_since == null) missing_owner_since = now;
                        if (now - missing_owner_since.? < 100) {
                            std.Thread.sleep(10 * std.time.ns_per_ms);
                            continue;
                        }
                    }
                    std.fs.cwd().deleteTree(lock_path) catch {};
                    missing_owner_since = null;
                    continue;
                }
                missing_owner_since = null;
                if (std.time.milliTimestamp() >= deadline) return error.SpeechBusy;
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };

        writeIdentity(allocator, owner_path, try currentIdentity(allocator)) catch |err| {
            std.fs.cwd().deleteTree(lock_path) catch {};
            return err;
        };
        return .{ .allocator = allocator, .path = lock_path };
    }
}

fn readState(allocator: std.mem.Allocator, dir: []const u8) !State {
    const path = try pathFor(allocator, dir, "state");
    defer allocator.free(path);
    const raw = std.fs.cwd().readFileAlloc(allocator, path, 32) catch |err| switch (err) {
        error.FileNotFound => return .idle,
        else => return err,
    };
    defer allocator.free(raw);
    const value = std.mem.trim(u8, raw, " \t\r\n");
    return std.meta.stringToEnum(State, value) orelse .idle;
}

fn writeState(allocator: std.mem.Allocator, dir: []const u8, value: State) !void {
    const path = try pathFor(allocator, dir, "state");
    defer allocator.free(path);
    try writeAtomic(allocator, path, @tagName(value));
}

fn cleanupFiles(allocator: std.mem.Allocator, dir: []const u8) void {
    const names = [_][]const u8{ "rec.pid", "worker.pid", "rec.wav", "target", "state", "cancel" };
    for (names) |name| {
        const path = pathFor(allocator, dir, name) catch continue;
        std.fs.cwd().deleteFile(path) catch {};
        allocator.free(path);
    }
}

fn recoverStale(allocator: std.mem.Allocator, dir: []const u8) !State {
    const current = try readState(allocator, dir);
    const identity_name: []const u8 = switch (current) {
        .recording => "rec.pid",
        .transcribing => "worker.pid",
        .idle => return .idle,
    };
    const identity_path = try pathFor(allocator, dir, identity_name);
    defer allocator.free(identity_path);
    const identity = try readIdentity(allocator, identity_path);
    if (identity != null and processMatches(allocator, identity.?)) return current;
    cleanupFiles(allocator, dir);
    return .idle;
}

pub fn status(allocator: std.mem.Allocator) !State {
    const dir = try runtimeDir(allocator);
    defer allocator.free(dir);
    var lock = try acquireLock(allocator, dir);
    defer lock.release();
    return recoverStale(allocator, dir);
}

fn spawnRecorder(allocator: std.mem.Allocator, wav_path: []const u8) !ProcessIdentity {
    if (std.posix.getenv("HEXE_SPEECH_RECORDER")) |executable| {
        var child = std.process.Child.init(&.{ executable, wav_path }, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        return .{ .pid = child.id, .start_ticks = try processStartTicks(allocator, child.id) };
    }

    const commands = [_][]const []const u8{
        &.{ "pw-record", "--format=s16", "--rate=16000", "--channels=1", wav_path },
        &.{ "arecord", "-q", "-t", "wav", "-f", "S16_LE", "-c", "1", "-r", "16000", wav_path },
    };
    for (commands) |argv| {
        var child = std.process.Child.init(argv, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        return .{ .pid = child.id, .start_ticks = try processStartTicks(allocator, child.id) };
    }
    return error.RecorderUnavailable;
}

fn ensureModelInstalled(allocator: std.mem.Allocator) !void {
    const model = try modelPath(allocator);
    defer allocator.free(model);
    std.fs.cwd().access(model, .{}) catch return error.ModelNotInstalled;
}

pub fn start(allocator: std.mem.Allocator, pane_uuid: []const u8) !void {
    if (pane_uuid.len != 32) return error.InvalidPaneUuid;
    for (pane_uuid) |byte| if (!std.ascii.isHex(byte)) return error.InvalidPaneUuid;
    try ensureModelInstalled(allocator);

    const dir = try runtimeDir(allocator);
    defer allocator.free(dir);
    var lock = try acquireLock(allocator, dir);
    defer lock.release();
    if (try recoverStale(allocator, dir) != .idle) return error.AlreadyActive;
    cleanupFiles(allocator, dir);

    const wav_path = try pathFor(allocator, dir, "rec.wav");
    defer allocator.free(wav_path);
    const identity = try spawnRecorder(allocator, wav_path);
    errdefer if (processMatches(allocator, identity)) std.posix.kill(identity.pid, std.posix.SIG.KILL) catch {};

    const target_path = try pathFor(allocator, dir, "target");
    defer allocator.free(target_path);
    const pid_path = try pathFor(allocator, dir, "rec.pid");
    defer allocator.free(pid_path);
    try writeAtomic(allocator, target_path, pane_uuid);
    try writeIdentity(allocator, pid_path, identity);
    try writeState(allocator, dir, .recording);
}

fn stopRecorder(allocator: std.mem.Allocator, identity: ProcessIdentity) !void {
    if (!processMatches(allocator, identity)) return error.RecorderExited;
    try std.posix.kill(identity.pid, std.posix.SIG.INT);
    var attempts: usize = 0;
    while (attempts < 200 and processMatches(allocator, identity)) : (attempts += 1) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    if (processMatches(allocator, identity)) {
        std.posix.kill(identity.pid, std.posix.SIG.KILL) catch {};
        return error.RecorderDidNotStop;
    }
}

fn decodeWavBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]f32 {
    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE")) return error.InvalidWav;
    var format_ok = false;
    var pcm: ?[]const u8 = null;
    var offset: usize = 12;
    while (offset + 8 <= bytes.len) {
        const size: usize = std.mem.readInt(u32, bytes[offset + 4 ..][0..4], .little);
        const chunk_start = offset + 8;
        if (chunk_start + size > bytes.len) return error.InvalidWav;
        if (std.mem.eql(u8, bytes[offset .. offset + 4], "fmt ") and size >= 16) {
            const fmt = bytes[chunk_start .. chunk_start + size];
            format_ok = std.mem.readInt(u16, fmt[0..2], .little) == 1 and
                std.mem.readInt(u16, fmt[2..4], .little) == 1 and
                std.mem.readInt(u32, fmt[4..8], .little) == 16_000 and
                std.mem.readInt(u16, fmt[14..16], .little) == 16;
        } else if (std.mem.eql(u8, bytes[offset .. offset + 4], "data")) {
            pcm = bytes[chunk_start .. chunk_start + size];
        }
        offset = chunk_start + size + (size & 1);
    }
    if (!format_ok) return error.UnsupportedWavFormat;
    const data = pcm orelse return error.MissingWavData;
    if (data.len == 0 or data.len % 2 != 0) return error.InvalidWav;
    const samples = try allocator.alloc(f32, data.len / 2);
    for (samples, 0..) |*sample, index| {
        const bits = std.mem.readInt(u16, data[index * 2 ..][0..2], .little);
        sample.* = @as(f32, @floatFromInt(@as(i16, @bitCast(bits)))) / 32768.0;
    }
    return samples;
}

fn decodeWav(allocator: std.mem.Allocator, path: []const u8) ![]f32 {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 256 * 1024 * 1024);
    defer allocator.free(bytes);
    return decodeWavBytes(allocator, bytes);
}

fn transcribe(allocator: std.mem.Allocator, wav_path: []const u8, cancel_path: ?[]const u8) ![]u8 {
    const model = try modelPath(allocator);
    defer allocator.free(model);
    const model_z = try allocator.dupeZ(u8, model);
    defer allocator.free(model_z);
    const cancel_z = if (cancel_path) |path| try allocator.dupeZ(u8, path) else null;
    defer if (cancel_z) |path| allocator.free(path);

    c.whisper_log_set(discardWhisperLog, null);
    var context_params = c.whisper_context_default_params();
    context_params.use_gpu = false;
    const ctx = c.whisper_init_from_file_with_params(model_z.ptr, context_params) orelse return error.WhisperInitFailed;
    defer c.whisper_free(ctx);

    const samples = try decodeWav(allocator, wav_path);
    defer allocator.free(samples);
    var params = c.whisper_full_default_params(c.WHISPER_SAMPLING_GREEDY);
    params.n_threads = @intCast(@min(8, std.Thread.getCpuCount() catch 4));
    params.language = "en";
    params.no_context = true;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.no_timestamps = true;
    params.vad = false;
    if (cancel_z) |path| {
        params.abort_callback = whisperAbort;
        params.abort_callback_user_data = @ptrCast(path.ptr);
    }
    if (c.whisper_full(ctx, params, samples.ptr, @intCast(samples.len)) != 0) {
        if (cancel_path) |path| {
            if (std.fs.cwd().access(path, .{})) |_| return error.TranscriptionCanceled else |_| {}
        }
        return error.TranscriptionFailed;
    }

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const segment_count = c.whisper_full_n_segments(ctx);
    var index: c_int = 0;
    while (index < segment_count) : (index += 1) {
        const text = c.whisper_full_get_segment_text(ctx, index) orelse continue;
        try output.appendSlice(allocator, std.mem.span(text));
    }
    const result = try allocator.dupe(u8, std.mem.trim(u8, output.items, " \t\r\n"));
    output.deinit(allocator);
    return result;
}

pub fn transcribeFile(allocator: std.mem.Allocator, wav_path: []const u8) ![]u8 {
    return transcribe(allocator, wav_path, null);
}

fn finishSession(allocator: std.mem.Allocator, dir: []const u8) void {
    var lock = acquireLock(allocator, dir) catch return;
    defer lock.release();
    cleanupFiles(allocator, dir);
}

pub fn targetPane(allocator: std.mem.Allocator) !?[32]u8 {
    const dir = try runtimeDir(allocator);
    defer allocator.free(dir);
    const target_path = try pathFor(allocator, dir, "target");
    defer allocator.free(target_path);
    const raw = std.fs.cwd().readFileAlloc(allocator, target_path, 32) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(raw);
    if (raw.len != 32) return null;
    for (raw) |byte| if (!std.ascii.isHex(byte)) return null;
    var uuid: [32]u8 = undefined;
    @memcpy(&uuid, raw);
    return uuid;
}

pub fn stop(allocator: std.mem.Allocator) !Transcript {
    const dir = try runtimeDir(allocator);
    defer allocator.free(dir);
    var recorder: ?ProcessIdentity = null;
    var waited: usize = 0;
    while (recorder == null and waited <= STOP_START_WAIT_MS) : (waited += 10) {
        {
            var lock = try acquireLock(allocator, dir);
            defer lock.release();
            const current = try recoverStale(allocator, dir);
            if (current == .recording) {
                const pid_path = try pathFor(allocator, dir, "rec.pid");
                defer allocator.free(pid_path);
                recorder = try readIdentity(allocator, pid_path);
                if (recorder) |identity| {
                    try stopRecorder(allocator, identity);
                    const worker_path = try pathFor(allocator, dir, "worker.pid");
                    defer allocator.free(worker_path);
                    try writeIdentity(allocator, worker_path, try currentIdentity(allocator));
                    try writeState(allocator, dir, .transcribing);
                    std.fs.cwd().deleteFile(pid_path) catch {};
                }
            } else if (current == .transcribing) {
                return error.AlreadyTranscribing;
            }
        }
        if (recorder == null) std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    if (recorder == null) return error.NotRecording;
    defer finishSession(allocator, dir);

    const target = try targetPane(allocator) orelse return error.InvalidPaneUuid;
    const wav_path = try pathFor(allocator, dir, "rec.wav");
    defer allocator.free(wav_path);
    const cancel_path = try pathFor(allocator, dir, "cancel");
    defer allocator.free(cancel_path);
    std.fs.cwd().deleteFile(cancel_path) catch {};
    return .{ .pane_uuid = target, .text = try transcribe(allocator, wav_path, cancel_path) };
}

pub fn cancel(allocator: std.mem.Allocator) !void {
    const dir = try runtimeDir(allocator);
    defer allocator.free(dir);
    var lock = try acquireLock(allocator, dir);
    defer lock.release();
    switch (try recoverStale(allocator, dir)) {
        .idle => cleanupFiles(allocator, dir),
        .recording => {
            const pid_path = try pathFor(allocator, dir, "rec.pid");
            defer allocator.free(pid_path);
            if (try readIdentity(allocator, pid_path)) |identity| {
                if (processMatches(allocator, identity)) std.posix.kill(identity.pid, std.posix.SIG.KILL) catch {};
            }
            cleanupFiles(allocator, dir);
        },
        .transcribing => {
            const cancel_path = try pathFor(allocator, dir, "cancel");
            defer allocator.free(cancel_path);
            try writeAtomic(allocator, cancel_path, "cancel\n");
        },
    }
}

pub fn installTinyModel(allocator: std.mem.Allocator) !void {
    const path = try modelPath(allocator);
    defer allocator.free(path);
    if (verifyTinyModel(path)) |_| return else |err| switch (err) {
        error.FileNotFound, error.ModelChecksumMismatch => {},
        else => return err,
    }
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
    const partial = try std.fmt.allocPrint(allocator, "{s}.{d}.part", .{ path, std.os.linux.getpid() });
    defer allocator.free(partial);
    std.fs.cwd().deleteFile(partial) catch {};
    errdefer std.fs.cwd().deleteFile(partial) catch {};
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "curl",
            "-fL",
            "--progress-bar",
            "-o",
            partial,
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin",
        },
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.stderr.len > 0) try std.fs.File.stderr().writeAll(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) return error.ModelDownloadFailed,
        else => return error.ModelDownloadFailed,
    }
    try verifyTinyModel(partial);
    try std.fs.cwd().rename(partial, path);
}

fn verifyTinyModel(path: []const u8) !void {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var hasher = std.crypto.hash.Sha1.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = try file.read(&buffer);
        if (count == 0) break;
        hasher.update(buffer[0..count]);
    }
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    hasher.final(&digest);
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual, TINY_EN_SHA1)) return error.ModelChecksumMismatch;
}

test "parse process start ticks" {
    const stat = "123 (name with spaces) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 424242 20";
    try std.testing.expectEqual(@as(u64, 424242), try parseProcessStartTicks(stat));
}

test "decode mono PCM16 WAV" {
    const wav = [_]u8{
        'R', 'I', 'F', 'F', 40, 0, 0, 0, 'W', 'A', 'V', 'E',
        'f', 'm', 't', ' ', 16, 0, 0, 0, 1, 0, 1, 0,
        0x80, 0x3e, 0, 0, 0, 0x7d, 0, 0, 2, 0, 16, 0,
        'd', 'a', 't', 'a', 4, 0, 0, 0, 0, 0, 0xff, 0x7f,
    };
    const samples = try decodeWavBytes(std.testing.allocator, &wav);
    defer std.testing.allocator.free(samples);
    try std.testing.expectEqual(@as(usize, 2), samples.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0), samples[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.999969), samples[1], 0.0001);
}

test "reject stereo WAV" {
    var wav = [_]u8{
        'R', 'I', 'F', 'F', 38, 0, 0, 0, 'W', 'A', 'V', 'E',
        'f', 'm', 't', ' ', 16, 0, 0, 0, 1, 0, 2, 0,
        0x80, 0x3e, 0, 0, 0, 0xfa, 0, 0, 4, 0, 16, 0,
        'd', 'a', 't', 'a', 2, 0, 0, 0, 0, 0,
    };
    try std.testing.expectError(error.UnsupportedWavFormat, decodeWavBytes(std.testing.allocator, &wav));
}
