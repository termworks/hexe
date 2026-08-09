const std = @import("std");
const core = @import("core");

const LuaRuntime = core.LuaRuntime;
const segment = core.segments;
const Style = core.style.Style;
const segment_render = core.segment_render;
const CALLBACK_REF_PREFIX = "__hexe_cb_ref:";

const LuaTraceMode = enum { off, all, slow };

fn parseLuaTraceMode() LuaTraceMode {
    const v = std.posix.getenv("HEXE_LUA_TRACE") orelse return .off;
    if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "all")) return .all;
    if (std.mem.eql(u8, v, "slow")) return .slow;
    return .off;
}

fn luaTraceSlowMs() i64 {
    const raw = std.posix.getenv("HEXE_LUA_TRACE_SLOW_MS") orelse return 8;
    return std.fmt.parseInt(i64, raw, 10) catch 8;
}

fn traceLuaEval(scope: []const u8, code: []const u8, ok: bool, start_ms: i64) void {
    const mode = parseLuaTraceMode();
    if (mode == .off) return;
    const elapsed = std.time.milliTimestamp() - start_ms;
    if (mode == .slow and elapsed < luaTraceSlowMs()) return;
    const code_hint = if (callbackIdFromCode(code) != null) code else "<chunk>";
    std.debug.print("[hexe-lua:{s}] ok={s} elapsed_ms={d} code={s}\n", .{ scope, if (ok) "true" else "false", elapsed, code_hint });
}

fn callbackIdFromCode(code: []const u8) ?i32 {
    if (!std.mem.startsWith(u8, code, CALLBACK_REF_PREFIX)) return null;
    return std.fmt.parseInt(i32, code[CALLBACK_REF_PREFIX.len..], 10) catch null;
}

const LuaEvalMode = enum { chunk, callback };

fn beginLuaEval(rt: *LuaRuntime, code: []const u8) ?LuaEvalMode {
    if (callbackIdFromCode(code)) |cid| {
        if (!core.lua_runtime.pushRegisteredCallback(rt, cid)) return null;
        _ = rt.lua.getGlobal("ctx") catch {
            rt.lua.pop(2);
            return null;
        };
        rt.lua.protectedCall(.{ .args = 1, .results = 1 }) catch {
            rt.lua.pop(2);
            return null;
        };
        return .callback;
    }

    const code_z = rt.allocator.dupeZ(u8, code) catch return null;
    defer rt.allocator.free(code_z);

    rt.lua.loadString(code_z) catch return null;
    rt.lua.protectedCall(.{ .args = 0, .results = 1 }) catch {
        rt.lua.pop(1);
        return null;
    };
    return .chunk;
}

fn endLuaEval(rt: *LuaRuntime, mode: LuaEvalMode) void {
    rt.lua.pop(1);
    if (mode == .callback) rt.lua.pop(1);
}

fn isPromptBuiltinAllowed(name: []const u8) bool {
    const allowed = [_][]const u8{
        "directory",
        "git_branch",
        "git_status",
        "status",
        "sudo",
        "jobs",
        "duration",
        "pod_name",
        "hostname",
        "username",
        "character",
    };
    for (allowed) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

fn populateLuaContext(runtime: *LuaRuntime, ctx: *segment.Context) void {
    runtime.lua.createTable(0, 8);
    _ = runtime.lua.pushString(ctx.cwd);
    runtime.lua.setField(-2, "cwd");

    if (ctx.home) |home| {
        _ = runtime.lua.pushString(home);
        runtime.lua.setField(-2, "home");
    }

    if (ctx.exit_status) |st| {
        runtime.lua.pushInteger(st);
        runtime.lua.setField(-2, "exit_status");
    }
    if (ctx.cmd_duration_ms) |d| {
        runtime.lua.pushInteger(@intCast(d));
        runtime.lua.setField(-2, "cmd_duration_ms");
    }
    runtime.lua.pushInteger(ctx.jobs);
    runtime.lua.setField(-2, "jobs");

    // Absent rather than an empty string when the shell has no answer, so a config writes
    // `if ctx.language then` and a segment disappears on bash instead of rendering a blank.
    if (ctx.language) |language| {
        _ = runtime.lua.pushString(language);
        runtime.lua.setField(-2, "language");
    }
    if (ctx.vimode) |vimode| {
        _ = runtime.lua.pushString(vimode);
        runtime.lua.setField(-2, "vimode");
    }

    runtime.lua.pushInteger(ctx.terminal_width);
    runtime.lua.setField(-2, "terminal_width");
    runtime.lua.pushInteger(@intCast(ctx.now_ms));
    runtime.lua.setField(-2, "now_ms");

    var env_map_opt = std.process.getEnvMap(runtime.allocator) catch null;
    if (env_map_opt) |*env_map| {
        defer env_map.deinit();
        runtime.lua.createTable(0, @intCast(env_map.count()));
        var it = env_map.iterator();
        while (it.next()) |entry| {
            _ = runtime.lua.pushString(entry.key_ptr.*);
            _ = runtime.lua.pushString(entry.value_ptr.*);
            runtime.lua.setTable(-3);
        }
        runtime.lua.setField(-2, "env");
    } else {
        runtime.lua.createTable(0, 0);
        runtime.lua.setField(-2, "env");
    }

    runtime.lua.pushValue(-1);
    runtime.lua.setGlobal("__hexe_when_pane0");
    runtime.lua.pushValue(-1);
    runtime.lua.setGlobal("ctx");

    const pane_api =
        "if type(ctx)=='table' then " ++
        "ctx.panes={ [1]=__hexe_when_pane0 }; " ++
        "ctx.pane=function(id) " ++
        "if id==nil or id==0 then return __hexe_when_pane0 end; " ++
        "if id==1 then return __hexe_when_pane0 end; " ++
        "if type(id)=='string' and (id=='focused' or id=='current') then return __hexe_when_pane0 end; " ++
        "return nil end; " ++
        "__hexe_ctx_cache=__hexe_ctx_cache or {}; " ++
        "ctx.cache = ctx.cache or {}; " ++
        "ctx.cache.get=function(key) " ++
        "local k=tostring(key); local e=__hexe_ctx_cache[k]; if not e then return nil end; " ++
        "local now=(ctx.now_ms or 0); if e.exp and e.exp < now then __hexe_ctx_cache[k]=nil; return nil end; " ++
        "return e.val end; " ++
        "ctx.cache.set=function(key,val,ttl_ms) " ++
        "local k=tostring(key); local exp=nil; " ++
        "if ttl_ms and type(ttl_ms)=='number' and ttl_ms>0 then exp=(ctx.now_ms or 0)+ttl_ms end; " ++
        "__hexe_ctx_cache[k]={ val=val, exp=exp }; return val end; " ++
        "ctx.cache.del=function(key) __hexe_ctx_cache[tostring(key)]=nil end; " ++
        "ctx.status = ctx.pane(0); " ++
        "end; " ++
        "if type(hexe)=='table' then hexe.status=hexe.status or {}; hexe.status.pane=ctx.pane; end";
    const pane_api_z = runtime.allocator.dupeZ(u8, pane_api) catch {
        runtime.lua.setGlobal("ctx");
        return;
    };
    defer runtime.allocator.free(pane_api_z);
    runtime.lua.loadString(pane_api_z) catch {
        runtime.lua.setGlobal("ctx");
        return;
    };
    runtime.lua.protectedCall(.{ .args = 0, .results = 0 }) catch {
        runtime.lua.pop(1);
        runtime.lua.setGlobal("ctx");
        return;
    };

    runtime.lua.setGlobal("ctx");
}

const LuaBlock = struct {
    text: [128]u8 = [_]u8{0} ** 128,
    len: usize = 0,
    prefix: [32]u8 = [_]u8{0} ** 32,
    prefix_len: usize = 0,
    suffix: [32]u8 = [_]u8{0} ** 32,
    suffix_len: usize = 0,
    style: Style = .{},
};

const LuaValue = struct {
    text: [512]u8 = [_]u8{0} ** 512,
    text_len: usize = 0,
    blocks: [16]LuaBlock = [_]LuaBlock{.{}} ** 16,
    block_count: usize = 0,

    fn textSlice(self: *const LuaValue) []const u8 {
        return self.text[0..self.text_len];
    }
};

fn evalLuaCommand(runtime: *LuaRuntime, callback_runtime: ?*LuaRuntime, ctx: *segment.Context, code: []const u8) LuaValue {
    var out: LuaValue = .{};
    const rt = callback_runtime orelse runtime;
    const start_ms = std.time.milliTimestamp();
    populateLuaContext(rt, ctx);
    const mode = beginLuaEval(rt, code) orelse {
        traceLuaEval("prompt.value", code, false, start_ms);
        return out;
    };
    defer endLuaEval(rt, mode);
    defer traceLuaEval("prompt.value", code, true, start_ms);

    switch (rt.lua.typeOf(-1)) {
        .string => {
            const s = rt.lua.toString(-1) catch return out;
            const n = @min(s.len, out.text.len);
            @memcpy(out.text[0..n], s[0..n]);
            out.text_len = n;
            return out;
        },
        .number => {
            const n = rt.lua.toNumber(-1) catch return out;
            const s = std.fmt.bufPrint(out.text[0..], "{d}", .{n}) catch "";
            out.text_len = s.len;
            return out;
        },
        .boolean => {
            if (!rt.lua.toBoolean(-1)) return out;
            @memcpy(out.text[0..4], "true");
            out.text_len = 4;
            return out;
        },
        .table => {
            const len: i32 = @intCast(@min(rt.lua.rawLen(-1), out.blocks.len));
            var i: i32 = 1;
            while (i <= len) : (i += 1) {
                _ = rt.lua.rawGetIndex(-1, i);
                defer rt.lua.pop(1);
                if (rt.lua.typeOf(-1) != .table) continue;

                _ = rt.lua.getField(-1, "text");
                if (rt.lua.typeOf(-1) != .string) {
                    rt.lua.pop(1);
                    continue;
                }
                const txt = rt.lua.toString(-1) catch {
                    rt.lua.pop(1);
                    continue;
                };
                rt.lua.pop(1);

                if (txt.len == 0) continue;
                var blk = LuaBlock{};
                const tn = @min(txt.len, blk.text.len);
                @memcpy(blk.text[0..tn], txt[0..tn]);
                blk.len = tn;

                _ = rt.lua.getField(-1, "prefix");
                if (rt.lua.typeOf(-1) == .string) {
                    const ps = rt.lua.toString(-1) catch "";
                    const pn = @min(ps.len, blk.prefix.len);
                    @memcpy(blk.prefix[0..pn], ps[0..pn]);
                    blk.prefix_len = pn;
                }
                rt.lua.pop(1);

                _ = rt.lua.getField(-1, "suffix");
                if (rt.lua.typeOf(-1) == .string) {
                    const ss = rt.lua.toString(-1) catch "";
                    const sn = @min(ss.len, blk.suffix.len);
                    @memcpy(blk.suffix[0..sn], ss[0..sn]);
                    blk.suffix_len = sn;
                }
                rt.lua.pop(1);

                _ = rt.lua.getField(-1, "style");
                if (rt.lua.typeOf(-1) == .string) {
                    const ss = rt.lua.toString(-1) catch "";
                    blk.style = Style.parse(ss);
                }
                rt.lua.pop(1);

                _ = rt.lua.getField(-1, "fg");
                if (rt.lua.typeOf(-1) == .number) {
                    const fg = rt.lua.toInteger(-1) catch -1;
                    if (fg >= 0 and fg <= 255) blk.style.fg = .{ .palette = @intCast(fg) };
                }
                rt.lua.pop(1);

                _ = rt.lua.getField(-1, "bg");
                if (rt.lua.typeOf(-1) == .number) {
                    const bg = rt.lua.toInteger(-1) catch -1;
                    if (bg >= 0 and bg <= 255) blk.style.bg = .{ .palette = @intCast(bg) };
                }
                rt.lua.pop(1);

                _ = rt.lua.getField(-1, "bold");
                if (rt.lua.typeOf(-1) == .boolean) blk.style.bold = rt.lua.toBoolean(-1);
                rt.lua.pop(1);

                _ = rt.lua.getField(-1, "italic");
                if (rt.lua.typeOf(-1) == .boolean) blk.style.italic = rt.lua.toBoolean(-1);
                rt.lua.pop(1);

                out.blocks[out.block_count] = blk;
                out.block_count += 1;
            }
            return out;
        },
        else => return out,
    }
}

fn evalLuaGate(runtime: *LuaRuntime, ctx: *segment.Context, code: []const u8) bool {
    const start_ms = std.time.milliTimestamp();
    populateLuaContext(runtime, ctx);
    const mode = beginLuaEval(runtime, code) orelse {
        traceLuaEval("prompt.when", code, false, start_ms);
        return false;
    };
    defer endLuaEval(runtime, mode);
    const ok = switch (runtime.lua.typeOf(-1)) {
        .boolean => runtime.lua.toBoolean(-1),
        .number => (runtime.lua.toNumber(-1) catch 0) != 0,
        .string => (runtime.lua.toString(-1) catch "").len > 0,
        else => false,
    };
    traceLuaEval("prompt.when", code, true, start_ms);
    return ok;
}

const BuiltinDesc = struct {
    name_buf: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    style: Style = .{},
    prefix_buf: [32]u8 = [_]u8{0} ** 32,
    prefix_len: usize = 0,
    prefix_style: Style = .{},
    suffix_buf: [32]u8 = [_]u8{0} ** 32,
    suffix_len: usize = 0,
    suffix_style: Style = .{},

    fn name(self: *const BuiltinDesc) ?[]const u8 {
        if (self.name_len == 0) return null;
        return self.name_buf[0..self.name_len];
    }

    fn prefix(self: *const BuiltinDesc) []const u8 {
        return self.prefix_buf[0..self.prefix_len];
    }

    fn suffix(self: *const BuiltinDesc) []const u8 {
        return self.suffix_buf[0..self.suffix_len];
    }

    fn prefixStyle(self: *const BuiltinDesc) Style {
        return if (self.prefix_style.isEmpty()) self.style else self.prefix_style;
    }

    fn suffixStyle(self: *const BuiltinDesc) Style {
        return if (self.suffix_style.isEmpty()) self.style else self.suffix_style;
    }
};

fn evalLuaBuiltinDesc(runtime: *LuaRuntime, callback_runtime: ?*LuaRuntime, ctx: *segment.Context, code: []const u8) BuiltinDesc {
    var desc: BuiltinDesc = .{};
    const rt = callback_runtime orelse runtime;
    const start_ms = std.time.milliTimestamp();
    populateLuaContext(rt, ctx);
    const mode = beginLuaEval(rt, code) orelse {
        traceLuaEval("prompt.builtin", code, false, start_ms);
        return desc;
    };
    defer endLuaEval(rt, mode);
    defer traceLuaEval("prompt.builtin", code, true, start_ms);

    switch (rt.lua.typeOf(-1)) {
        .string => {
            const s = rt.lua.toString(-1) catch return desc;
            const t = std.mem.trim(u8, s, " \t\r\n");
            if (t.len > 0) {
                const n = @min(t.len, desc.name_buf.len);
                @memcpy(desc.name_buf[0..n], t[0..n]);
                desc.name_len = n;
            }
            return desc;
        },
        .table => {
            _ = rt.lua.getField(-1, "name");
            if (rt.lua.typeOf(-1) == .string) {
                const s = rt.lua.toString(-1) catch "";
                const t = std.mem.trim(u8, s, " \t\r\n");
                if (t.len > 0) {
                    const n = @min(t.len, desc.name_buf.len);
                    @memcpy(desc.name_buf[0..n], t[0..n]);
                    desc.name_len = n;
                }
            }
            rt.lua.pop(1);

            _ = rt.lua.getField(-1, "style");
            if (rt.lua.typeOf(-1) == .string) {
                const s = rt.lua.toString(-1) catch "";
                desc.style = Style.parse(s);
            }
            rt.lua.pop(1);

            _ = rt.lua.getField(-1, "fg");
            if (rt.lua.typeOf(-1) == .number) {
                const fg = rt.lua.toInteger(-1) catch -1;
                if (fg >= 0 and fg <= 255) desc.style.fg = .{ .palette = @intCast(fg) };
            }
            rt.lua.pop(1);

            _ = rt.lua.getField(-1, "bg");
            if (rt.lua.typeOf(-1) == .number) {
                const bg = rt.lua.toInteger(-1) catch -1;
                if (bg >= 0 and bg <= 255) desc.style.bg = .{ .palette = @intCast(bg) };
            }
            rt.lua.pop(1);

            _ = rt.lua.getField(-1, "prefix");
            if (rt.lua.typeOf(-1) == .string) {
                const s = rt.lua.toString(-1) catch "";
                const n = @min(s.len, desc.prefix_buf.len);
                @memcpy(desc.prefix_buf[0..n], s[0..n]);
                desc.prefix_len = n;
            } else if (rt.lua.typeOf(-1) == .table) {
                _ = rt.lua.getField(-1, "output");
                if (rt.lua.typeOf(-1) == .string) {
                    const s = rt.lua.toString(-1) catch "";
                    const n = @min(s.len, desc.prefix_buf.len);
                    @memcpy(desc.prefix_buf[0..n], s[0..n]);
                    desc.prefix_len = n;
                } else if (rt.lua.typeOf(-1) != .nil) {
                    _ = rt.lua.pushString("builtin.prefix.output must be string");
                    rt.lua.raiseError();
                }
                rt.lua.pop(1);

                _ = rt.lua.getField(-1, "style");
                if (rt.lua.typeOf(-1) == .string) {
                    const s = rt.lua.toString(-1) catch "";
                    desc.prefix_style = Style.parse(s);
                } else if (rt.lua.typeOf(-1) != .nil) {
                    _ = rt.lua.pushString("builtin.prefix.style must be string");
                    rt.lua.raiseError();
                }
                rt.lua.pop(1);
            }
            rt.lua.pop(1);

            _ = rt.lua.getField(-1, "suffix");
            if (rt.lua.typeOf(-1) == .string) {
                const s = rt.lua.toString(-1) catch "";
                const n = @min(s.len, desc.suffix_buf.len);
                @memcpy(desc.suffix_buf[0..n], s[0..n]);
                desc.suffix_len = n;
            } else if (rt.lua.typeOf(-1) == .table) {
                _ = rt.lua.getField(-1, "output");
                if (rt.lua.typeOf(-1) == .string) {
                    const s = rt.lua.toString(-1) catch "";
                    const n = @min(s.len, desc.suffix_buf.len);
                    @memcpy(desc.suffix_buf[0..n], s[0..n]);
                    desc.suffix_len = n;
                } else if (rt.lua.typeOf(-1) != .nil) {
                    _ = rt.lua.pushString("builtin.suffix.output must be string");
                    rt.lua.raiseError();
                }
                rt.lua.pop(1);

                _ = rt.lua.getField(-1, "style");
                if (rt.lua.typeOf(-1) == .string) {
                    const s = rt.lua.toString(-1) catch "";
                    desc.suffix_style = Style.parse(s);
                } else if (rt.lua.typeOf(-1) != .nil) {
                    _ = rt.lua.pushString("builtin.suffix.style must be string");
                    rt.lua.raiseError();
                }
                rt.lua.pop(1);
            }
            rt.lua.pop(1);

            if (desc.suffix_len == 0 and desc.suffix_style.isEmpty()) {
                _ = rt.lua.getField(-1, "sufix");
                if (rt.lua.typeOf(-1) == .table) {
                    _ = rt.lua.getField(-1, "output");
                    if (rt.lua.typeOf(-1) == .string) {
                        const s = rt.lua.toString(-1) catch "";
                        const n = @min(s.len, desc.suffix_buf.len);
                        @memcpy(desc.suffix_buf[0..n], s[0..n]);
                        desc.suffix_len = n;
                    } else if (rt.lua.typeOf(-1) != .nil) {
                        _ = rt.lua.pushString("builtin.sufix.output must be string");
                        rt.lua.raiseError();
                    }
                    rt.lua.pop(1);

                    _ = rt.lua.getField(-1, "style");
                    if (rt.lua.typeOf(-1) == .string) {
                        const s = rt.lua.toString(-1) catch "";
                        desc.suffix_style = Style.parse(s);
                    } else if (rt.lua.typeOf(-1) != .nil) {
                        _ = rt.lua.pushString("builtin.sufix.style must be string");
                        rt.lua.raiseError();
                    }
                    rt.lua.pop(1);
                }
                rt.lua.pop(1);
            }

            _ = rt.lua.getField(-1, "prefix_style");
            if (rt.lua.typeOf(-1) == .string) {
                const s = rt.lua.toString(-1) catch "";
                desc.prefix_style = Style.parse(s);
            }
            rt.lua.pop(1);

            _ = rt.lua.getField(-1, "suffix_style");
            if (rt.lua.typeOf(-1) == .string) {
                const s = rt.lua.toString(-1) catch "";
                desc.suffix_style = Style.parse(s);
            }
            rt.lua.pop(1);

            return desc;
        },
        else => return desc,
    }
}

pub fn renderModulesSimple(allocator: std.mem.Allocator, callback_runtime: ?*LuaRuntime, ctx: *segment.Context, modules: []const core.Segment, stdout: std.fs.File, is_zsh: bool) !void {
    // Rendering one prompt makes hundreds of small, short-lived allocations.
    // Served straight from the page allocator that was one mmap and one munmap
    // each — over 1600 syscalls per prompt, most of this function's cost. They
    // all die when the prompt is written, which is exactly an arena.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const ModuleResult = struct {
        when_passed: bool = true,
        output: LuaValue = .{},
        width: u16 = 0,
        should_render: bool = true,
        visible: bool = true,
    };

    var results: [32]ModuleResult = [_]ModuleResult{.{}} ** 32;
    const mod_count = @min(modules.len, 32);

    var lua_rt: ?LuaRuntime = null;
    defer if (lua_rt) |*rt| rt.deinit();

    for (modules[0..mod_count], 0..) |mod, i| {
        if (mod.command) |cmd| {
            if (mod.kind == .progress) {
                if (mod.progress_show_when) |gate| {
                    if (lua_rt == null) lua_rt = LuaRuntime.init(alloc) catch null;
                    if (lua_rt == null) {
                        results[i].when_passed = false;
                        continue;
                    }
                    if (!evalLuaGate(&lua_rt.?, ctx, gate)) {
                        results[i].when_passed = false;
                        continue;
                    }
                }
            }
            if (lua_rt == null) lua_rt = LuaRuntime.init(alloc) catch null;
            if (lua_rt == null) {
                results[i].when_passed = false;
                continue;
            }
            if (mod.kind == .builtin) {
                const desc = evalLuaBuiltinDesc(&lua_rt.?, callback_runtime, ctx, cmd);
                if (desc.name()) |builtin_name| {
                    var bi = LuaValue{};
                    if (isPromptBuiltinAllowed(builtin_name)) {
                        if (ctx.renderSegment(builtin_name)) |segs| {
                            const pref = desc.prefix();
                            if (pref.len > 0 and bi.block_count < bi.blocks.len) {
                                var pblk = LuaBlock{};
                                const pn = @min(pref.len, pblk.text.len);
                                @memcpy(pblk.text[0..pn], pref[0..pn]);
                                pblk.len = pn;
                                pblk.style = desc.prefixStyle();
                                bi.blocks[bi.block_count] = pblk;
                                bi.block_count += 1;
                            }
                            if (segs.len > 0) {
                                for (segs) |seg_out| {
                                    if (bi.block_count >= bi.blocks.len) break;
                                    if (seg_out.text.len == 0) continue;
                                    var blk = LuaBlock{};
                                    const tn = @min(seg_out.text.len, blk.text.len);
                                    @memcpy(blk.text[0..tn], seg_out.text[0..tn]);
                                    blk.len = tn;
                                    blk.style = if (desc.style.isEmpty()) seg_out.style else desc.style;
                                    bi.blocks[bi.block_count] = blk;
                                    bi.block_count += 1;
                                }
                            }
                            const suff = desc.suffix();
                            if (suff.len > 0 and bi.block_count < bi.blocks.len) {
                                var sblk = LuaBlock{};
                                const sn = @min(suff.len, sblk.text.len);
                                @memcpy(sblk.text[0..sn], suff[0..sn]);
                                sblk.len = sn;
                                sblk.style = desc.suffixStyle();
                                bi.blocks[bi.block_count] = sblk;
                                bi.block_count += 1;
                            }
                        }
                    }
                    results[i].output = bi;
                }
            } else {
                results[i].output = evalLuaCommand(&lua_rt.?, callback_runtime, ctx, cmd);
            }
        } else if (mod.builtin) |builtin_name| {
            var bi = LuaValue{};
            if (isPromptBuiltinAllowed(builtin_name)) {
                if (ctx.renderSegment(builtin_name)) |segs| {
                    if (segs.len > 0) {
                        for (segs) |seg_out| {
                            if (bi.block_count >= bi.blocks.len) break;
                            if (seg_out.text.len == 0) continue;
                            var blk = LuaBlock{};
                            const tn = @min(seg_out.text.len, blk.text.len);
                            @memcpy(blk.text[0..tn], seg_out.text[0..tn]);
                            blk.len = tn;
                            blk.style = seg_out.style;
                            bi.blocks[bi.block_count] = blk;
                            bi.block_count += 1;
                        }
                    }
                }
            }
            results[i].output = bi;
        } else if (ctx.renderSegment(mod.name)) |segs| {
            if (segs.len > 0) {
                var bi = results[i].output;
                for (segs) |seg_out| {
                    if (bi.block_count >= bi.blocks.len) break;
                    if (seg_out.text.len == 0) continue;
                    var blk = LuaBlock{};
                    const tn = @min(seg_out.text.len, blk.text.len);
                    @memcpy(blk.text[0..tn], seg_out.text[0..tn]);
                    blk.len = tn;
                    blk.style = seg_out.style;
                    bi.blocks[bi.block_count] = blk;
                    bi.block_count += 1;
                }
                results[i].output = bi;
            }
        }
    }

    for (modules[0..mod_count], 0..) |_, i| {
        if (!results[i].when_passed) {
            results[i].should_render = false;
            continue;
        }

        var output_text = results[i].output.textSlice();
        if (segment_render.builtinNameFromMarker(output_text)) |builtin_name| {
            if (isPromptBuiltinAllowed(builtin_name)) {
                if (ctx.renderSegment(builtin_name)) |segs| {
                    if (segs.len > 0) {
                        var bi = LuaValue{};
                        for (segs) |seg_out| {
                            if (bi.block_count >= bi.blocks.len) break;
                            if (seg_out.text.len == 0) continue;
                            var blk = LuaBlock{};
                            const tn = @min(seg_out.text.len, blk.text.len);
                            @memcpy(blk.text[0..tn], seg_out.text[0..tn]);
                            blk.len = tn;
                            blk.style = seg_out.style;
                            bi.blocks[bi.block_count] = blk;
                            bi.block_count += 1;
                        }
                        results[i].output = bi;
                    } else {
                        results[i].should_render = false;
                        continue;
                    }
                } else {
                    results[i].should_render = false;
                    continue;
                }
            } else {
                results[i].should_render = false;
                continue;
            }
        }

        if (results[i].output.block_count > 0) {
            for (results[i].output.blocks[0..results[i].output.block_count]) |blk| {
                const bt = blk.text[0..blk.len];
                if (segment_render.builtinNameFromMarker(bt)) |builtin_name| {
                    if (isPromptBuiltinAllowed(builtin_name)) {
                        if (ctx.renderSegment(builtin_name)) |segs| {
                            var seg_width: u16 = 0;
                            for (segs) |s| seg_width += @intCast(s.text.len);
                            if (seg_width > 0) {
                                results[i].width += seg_width;
                                results[i].width += @intCast(blk.prefix_len + blk.suffix_len);
                            }
                        }
                    }
                } else {
                    results[i].width += @intCast(blk.len);
                }
            }
        } else {
            output_text = results[i].output.textSlice();
            if (output_text.len == 0) {
                results[i].should_render = false;
                continue;
            }
            results[i].width = @intCast(output_text.len);
        }
    }

    const width_budget = ctx.terminal_width / 2;
    var used_width: u16 = 0;

    var priority_order: [32]usize = undefined;
    for (0..mod_count) |i| priority_order[i] = i;

    for (1..mod_count) |i| {
        const key = priority_order[i];
        const key_priority = modules[key].priority;
        var j: usize = i;
        while (j > 0) {
            const prev_priority = modules[priority_order[j - 1]].priority;
            if (prev_priority <= key_priority) break;
            priority_order[j] = priority_order[j - 1];
            j -= 1;
        }
        priority_order[j] = key;
    }

    for (priority_order[0..mod_count]) |idx| {
        if (!results[idx].should_render) continue;
        if (used_width + results[idx].width <= width_budget) {
            results[idx].visible = true;
            used_width += results[idx].width;
        } else {
            results[idx].visible = false;
        }
    }

    for (modules[0..mod_count], 0..) |mod, i| {
        _ = mod;
        if (!results[i].should_render or !results[i].visible) continue;

        var wrote_module = false;

        if (results[i].output.block_count > 0) {
            for (results[i].output.blocks[0..results[i].output.block_count]) |blk| {
                if (blk.len == 0) continue;
                const bt = blk.text[0..blk.len];
                const style = blk.style;
                if (segment_render.builtinNameFromMarker(bt)) |builtin_name| {
                    if (isPromptBuiltinAllowed(builtin_name)) {
                        if (ctx.renderSegment(builtin_name)) |segs| {
                            if (segs.len == 0) continue;
                            var wrote_any = false;
                            for (segs) |s| {
                                if (s.text.len > 0) {
                                    wrote_any = true;
                                    break;
                                }
                            }
                            if (!wrote_any) continue;
                            try writeStyleDirect(stdout, style, is_zsh);
                            if (blk.prefix_len > 0) try stdout.writeAll(blk.prefix[0..blk.prefix_len]);
                            for (segs) |s| {
                                try stdout.writeAll(s.text);
                                if (s.text.len > 0) wrote_module = true;
                            }
                            if (blk.suffix_len > 0) try stdout.writeAll(blk.suffix[0..blk.suffix_len]);
                            if (blk.prefix_len > 0 or blk.suffix_len > 0) wrote_module = true;
                            if (!style.isEmpty()) {
                                try writeResetDirect(stdout, is_zsh);
                            }
                        }
                    }
                } else {
                    try writeStyleDirect(stdout, style, is_zsh);
                    try stdout.writeAll(bt);
                    wrote_module = true;
                    if (!style.isEmpty()) {
                        try writeResetDirect(stdout, is_zsh);
                    }
                }
            }
        } else {
            const output_text = results[i].output.textSlice();
            const style = Style{};
            try writeStyleDirect(stdout, style, is_zsh);
            try stdout.writeAll(output_text);
            wrote_module = output_text.len > 0;
            if (!style.isEmpty()) {
                try writeResetDirect(stdout, is_zsh);
            }
        }

        if (wrote_module) {
            try writeResetDirect(stdout, is_zsh);
        }
    }
}

fn writeStyleDirect(stdout: std.fs.File, style: Style, is_zsh: bool) !void {
    if (style.isEmpty()) return;

    if (is_zsh) try stdout.writeAll("%{");

    var buf: [64]u8 = undefined;
    var len: usize = 0;

    buf[0] = '\x1b';
    buf[1] = '[';
    len = 2;

    var need_semi = false;

    if (style.bold) {
        buf[len] = '1';
        len += 1;
        need_semi = true;
    }
    if (style.dim) {
        if (need_semi) {
            buf[len] = ';';
            len += 1;
        }
        buf[len] = '2';
        len += 1;
        need_semi = true;
    }
    if (style.italic) {
        if (need_semi) {
            buf[len] = ';';
            len += 1;
        }
        buf[len] = '3';
        len += 1;
        need_semi = true;
    }
    if (style.underline) {
        if (need_semi) {
            buf[len] = ';';
            len += 1;
        }
        buf[len] = '4';
        len += 1;
        need_semi = true;
    }

    switch (style.fg) {
        .none => {},
        .palette => |p| {
            if (need_semi) {
                buf[len] = ';';
                len += 1;
            }
            const code = if (p < 8)
                std.fmt.bufPrint(buf[len..], "{d}", .{30 + p}) catch ""
            else if (p < 16)
                std.fmt.bufPrint(buf[len..], "{d}", .{90 + p - 8}) catch ""
            else
                std.fmt.bufPrint(buf[len..], "38;5;{d}", .{p}) catch "";
            len += code.len;
            need_semi = true;
        },
        .rgb => |rgb| {
            if (need_semi) {
                buf[len] = ';';
                len += 1;
            }
            const code = std.fmt.bufPrint(buf[len..], "38;2;{d};{d};{d}", .{ rgb.r, rgb.g, rgb.b }) catch "";
            len += code.len;
            need_semi = true;
        },
    }

    switch (style.bg) {
        .none => {},
        .palette => |p| {
            if (need_semi) {
                buf[len] = ';';
                len += 1;
            }
            const code = if (p < 8)
                std.fmt.bufPrint(buf[len..], "{d}", .{40 + p}) catch ""
            else if (p < 16)
                std.fmt.bufPrint(buf[len..], "{d}", .{100 + p - 8}) catch ""
            else
                std.fmt.bufPrint(buf[len..], "48;5;{d}", .{p}) catch "";
            len += code.len;
        },
        .rgb => |rgb| {
            if (need_semi) {
                buf[len] = ';';
                len += 1;
            }
            const code = std.fmt.bufPrint(buf[len..], "48;2;{d};{d};{d}", .{ rgb.r, rgb.g, rgb.b }) catch "";
            len += code.len;
        },
    }

    buf[len] = 'm';
    len += 1;

    try stdout.writeAll(buf[0..len]);
    if (is_zsh) try stdout.writeAll("%}");
}

fn writeResetDirect(stdout: std.fs.File, is_zsh: bool) !void {
    if (is_zsh) try stdout.writeAll("%{");
    try stdout.writeAll("\x1b[0m");
    if (is_zsh) try stdout.writeAll("%}");
}
