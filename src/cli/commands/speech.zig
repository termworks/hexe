const std = @import("std");
const speech = @import("speech");
const pod_send = @import("pod_send.zig");
const cli = @import("com.zig");

const print = std.debug.print;

pub fn runStart(allocator: std.mem.Allocator, uuid: []const u8) !void {
    speech.start(allocator, uuid) catch |err| {
        notify(allocator, uuid, errorMessage(err));
        print("Error: {s}\n", .{errorMessage(err)});
        return err;
    };
    print("recording\n", .{});
}

pub fn runStop(allocator: std.mem.Allocator) !void {
    const initial_target = speech.targetPane(allocator) catch null;
    var transcript = speech.stop(allocator) catch |err| {
        const target = initial_target orelse speech.targetPane(allocator) catch null;
        notify(allocator, if (target) |uuid| uuid[0..] else "", errorMessage(err));
        print("Error: {s}\n", .{errorMessage(err)});
        return err;
    };
    defer transcript.deinit(allocator);
    if (transcript.text.len == 0) {
        notify(allocator, transcript.pane_uuid[0..], "Speech: nothing recognized");
        return;
    }
    pod_send.sendBytes(allocator, transcript.pane_uuid[0..], "", "", transcript.text) catch |err| {
        notify(allocator, transcript.pane_uuid[0..], "Speech: target pane is unavailable");
        print("Error: {s}\n", .{errorMessage(err)});
        return err;
    };
    notify(allocator, transcript.pane_uuid[0..], "Speech inserted");
    print("{s}\n", .{transcript.text});
}

pub fn runStatus(allocator: std.mem.Allocator) !void {
    const current = speech.status(allocator) catch |err| {
        print("Error: {s}\n", .{errorMessage(err)});
        return err;
    };
    print("{s}\n", .{@tagName(current)});
}

pub fn runCancel(allocator: std.mem.Allocator) !void {
    speech.cancel(allocator) catch |err| {
        print("Error: {s}\n", .{errorMessage(err)});
        return err;
    };
    const current = speech.status(allocator) catch |err| {
        print("Error: {s}\n", .{errorMessage(err)});
        return err;
    };
    print("{s}\n", .{@tagName(current)});
}

pub fn runSetup(allocator: std.mem.Allocator) !void {
    speech.installTinyModel(allocator) catch |err| {
        print("Error: {s}\n", .{errorMessage(err)});
        return err;
    };
    print("Speech model ready\n", .{});
}

pub fn runTranscribe(allocator: std.mem.Allocator, wav_path: []const u8) !void {
    if (wav_path.len == 0) {
        print("Error: {s}\n", .{errorMessage(error.MissingWavPath)});
        return error.MissingWavPath;
    }
    const text = speech.transcribeFile(allocator, wav_path) catch |err| {
        print("Error: {s}\n", .{errorMessage(err)});
        return err;
    };
    defer allocator.free(text);
    print("{s}\n", .{text});
}

fn notify(allocator: std.mem.Allocator, uuid: []const u8, message: []const u8) void {
    if (uuid.len != 32) return;
    cli.runNotify(allocator, uuid, false, false, false, message) catch {};
}

fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.ModelNotInstalled => "Speech model missing: run hexe speech setup",
        error.RecorderUnavailable => "Speech recorder missing: install PipeWire or ALSA tools",
        error.AlreadyActive => "Speech is already active",
        error.AlreadyTranscribing => "Speech is already transcribing",
        error.NotRecording => "Speech recording did not start",
        error.RecorderExited => "Speech recorder exited unexpectedly",
        error.RecorderDidNotStop => "Speech recorder did not stop cleanly",
        error.InvalidWav, error.MissingWavData, error.UnsupportedWavFormat => "Speech recorder produced invalid audio",
        error.WhisperInitFailed => "Speech model could not be loaded",
        error.TranscriptionFailed => "Speech transcription failed",
        error.TranscriptionCanceled => "Speech transcription canceled",
        error.ModelChecksumMismatch => "Speech model download failed verification",
        error.ModelDownloadFailed => "Speech model download failed",
        error.MissingWavPath => "Speech WAV path is required",
        error.FileNotFound => "Speech file was not found",
        error.PrivateDirUnusable => "Speech runtime directory is unavailable",
        error.PodNotRunning => "Speech target pane is unavailable",
        else => "Speech failed",
    };
}
