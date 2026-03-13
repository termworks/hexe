const std = @import("std");
const posix = std.posix;
const zlua = @import("zlua");
const Lua = zlua.Lua;
const LuaState = zlua.LuaState;
const LuaType = zlua.LuaType;
const config_builder = @import("config_builder.zig");
const ConfigBuilder = config_builder.ConfigBuilder;
const api_bridge = @import("api_bridge.zig");

// Import C API functions
const hexe_mux_config_set = api_bridge.hexe_mux_config_set;
const hexe_mux_config_setup = api_bridge.hexe_mux_config_setup;
const hexe_mux_keymap_set = api_bridge.hexe_mux_keymap_set;
const hexe_mux_float_set_defaults = api_bridge.hexe_mux_float_set_defaults;
const hexe_mux_float_set_adhoc = api_bridge.hexe_mux_float_set_adhoc;
const hexe_mux_float_set_match = api_bridge.hexe_mux_float_set_match;
const hexe_mux_float_define = api_bridge.hexe_mux_float_define;
const hexe_mux_tabs_add_segment = api_bridge.hexe_mux_tabs_add_segment;
const hexe_mux_tabs_set_status = api_bridge.hexe_mux_tabs_set_status;
const hexe_mux_splits_setup = api_bridge.hexe_mux_splits_setup;
const hexe_ses_layout_define = api_bridge.hexe_ses_layout_define;
const hexe_ses_session_setup = api_bridge.hexe_ses_session_setup;
const hexe_ses_isolation_set = api_bridge.hexe_ses_isolation_set;

const hexe_shp_prompt_left = api_bridge.hexe_shp_prompt_left;
const hexe_shp_prompt_right = api_bridge.hexe_shp_prompt_right;
const hexe_shp_prompt_add = api_bridge.hexe_shp_prompt_add;

const hexe_pop_notify_setup = api_bridge.hexe_pop_notify_setup;
const hexe_pop_confirm_setup = api_bridge.hexe_pop_confirm_setup;
const hexe_pop_choose_setup = api_bridge.hexe_pop_choose_setup;
const hexe_pop_widgets_pokemon = api_bridge.hexe_pop_widgets_pokemon;
const hexe_pop_widgets_keycast = api_bridge.hexe_pop_widgets_keycast;
const hexe_pop_widgets_digits = api_bridge.hexe_pop_widgets_digits;
const hexe_record_start = api_bridge.hexe_record_start;
const hexe_record_stop = api_bridge.hexe_record_stop;
const hexe_record_toggle = api_bridge.hexe_record_toggle;
const hexe_record_status = api_bridge.hexe_record_status;
const hexe_api_exec = @import("lua_api_exec.zig").hexe_api_exec;
const CALLBACK_TABLE_KEY = "__hexe_cb_table";

fn hexe_autocmd_on(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    const argc = lua.getTop();
    var event_idx: i32 = 1;
    var fn_idx: i32 = 2;

    // Support both dot and colon calls on the internal autocmd table:
    // - hx.events.on("event", fn) (canonical public API)
    // - hexe.autocmd.on("event", fn) / hexe.autocmd:on("event", fn) (storage path)
    if (argc >= 3 and lua.typeOf(1) == .table and lua.typeOf(2) == .string and lua.typeOf(3) == .function) {
        event_idx = 2;
        fn_idx = 3;
    } else if (!(argc >= 2 and lua.typeOf(1) == .string and lua.typeOf(2) == .function)) {
        _ = lua.pushString("usage: hx.events.on(event_name, fn)");
        lua.raiseError();
    }

    const event_name = lua.toString(event_idx) catch {
        _ = lua.pushString("autocmd event must be string");
        lua.raiseError();
    };

    _ = lua.getGlobal("hexe") catch {
        _ = lua.pushString("hexe module not found");
        lua.raiseError();
    };
    if (lua.typeOf(-1) != .table) {
        lua.pop(1);
        _ = lua.pushString("hexe module is invalid");
        lua.raiseError();
    }

    _ = lua.getField(-1, "autocmd");
    if (lua.typeOf(-1) != .table) {
        lua.pop(2);
        _ = lua.pushString("event handler storage table is missing");
        lua.raiseError();
    }

    _ = lua.pushString(event_name);
    _ = lua.getTable(-2);
    const existing_ty = lua.typeOf(-1);

    switch (existing_ty) {
        .nil => {
            lua.pop(1); // nil
            _ = lua.pushString(event_name);
            lua.pushValue(fn_idx);
            lua.setTable(-3);
        },
        .function => {
            lua.createTable(2, 0);
            lua.pushValue(-2); // existing fn
            lua.rawSetIndex(-2, 1);
            lua.pushValue(fn_idx); // new fn
            lua.rawSetIndex(-2, 2);
            lua.pop(1); // existing fn
            _ = lua.pushString(event_name);
            lua.pushValue(-2); // handler table
            lua.setTable(-4); // set in autocmd
            lua.pop(1); // handler table
        },
        .table => {
            const len: i32 = @intCast(lua.rawLen(-1));
            lua.pushValue(fn_idx);
            lua.rawSetIndex(-2, len + 1);
            lua.pop(1); // existing table
        },
        else => {
            lua.pop(3); // existing, autocmd, hexe
            _ = lua.pushString("autocmd slot already used by non-function value");
            lua.raiseError();
        },
    }

    // Pop autocmd + hexe.
    lua.pop(2);

    // Return the registered function.
    lua.pushValue(fn_idx);
    return 1;
}

fn injectRecordTargetHelper(lua: *Lua) void {
    const code =
        "if type(hexe)=='table' and type(hexe.record)=='table' then " ++
        "local __rec=hexe.record; " ++
        "if __rec.target==nil then " ++
        "__rec.target=function(target, defaults) " ++
        "local base={}; " ++
        "if type(defaults)=='table' then for k,v in pairs(defaults) do base[k]=v end end; " ++
        "if type(target)=='string' then base.uuid=target " ++
        "elseif type(target)=='table' then for k,v in pairs(target) do base[k]=v end end; " ++
        "local function mk(extra) local o={}; for k,v in pairs(base) do o[k]=v end; if type(extra)=='table' then for k,v in pairs(extra) do o[k]=v end end; return o end; " ++
        "local out={}; " ++
        "out.start=function(extra) return __rec.start(mk(extra)) end; " ++
        "out.stop=function(extra) return __rec.stop(mk(extra)) end; " ++
        "out.toggle=function(extra) return __rec.toggle(mk(extra)) end; " ++
        "out.status=function(extra) return __rec.status(mk(extra)) end; " ++
        "out.switch=function(extra) " ++
        "local o=mk(extra); local sc=o.scope or 'pod'; " ++
        "local st=__rec.status({ scope=sc }); local start_cmd=__rec.start(o); " ++
        "if not st or not st.active then return start_cmd end; " ++
        "if sc=='pod' and o.uuid and st.uuid and st.uuid==o.uuid then return __rec.stop({ scope=sc }) end; " ++
        "return __rec.stop({ scope=sc }) .. '; ' .. start_cmd end; " ++
        "return out end; " ++
        "end; " ++
        "if __rec.active==nil then " ++
        "__rec.active=function(c, defaults) " ++
        "local ap=(hexe.status and hexe.status.active_pod) and hexe.status.active_pod(c) or nil; " ++
        "if not ap or not ap.uuid then return nil end; " ++
        "return __rec.target({ uuid=ap.uuid }, defaults) end; " ++
        "end; " ++
        "end";

    const z = std.heap.page_allocator.dupeZ(u8, code) catch return;
    defer std.heap.page_allocator.free(z);
    lua.loadString(z) catch return;
    lua.protectedCall(.{ .args = 0, .results = 0 }) catch {
        lua.pop(1);
        return;
    };
}

fn injectStatusHelpers(lua: *Lua) void {
    const code =
        "if type(hexe)=='table' then " ++
        // Canonical ctx helpers.
        "hexe.ctx=hexe.ctx or {}; " ++
        "if hexe.ctx.current==nil then hexe.ctx.current=function() local c=rawget(_G,'ctx'); if type(c)=='table' then return c end; return nil end end; " ++
        "if hexe.ctx.pane==nil then hexe.ctx.pane=function(sel) local c=hexe.ctx.current(); if c and type(c.pane)=='function' then return c.pane(sel) end; return nil end end; " ++
        // Canonical exec helper namespace.
        "hexe.exec=hexe.exec or {}; " ++
        "if hexe.exec.run==nil and type(hexe.api)=='table' and type(hexe.api.exec)=='function' then hexe.exec.run=hexe.api.exec end; " ++
        // Canonical events namespace (backed by hexe.autocmd storage).
        "hexe.events=hexe.events or {}; " ++
        "if hexe.events.on==nil and type(hexe.autocmd)=='table' and type(hexe.autocmd.on)=='function' then hexe.events.on=hexe.autocmd.on end; " ++
        "if hexe.events.off==nil then hexe.events.off=function(event,fn) " ++
        "if type(event)~='string' then return false end; " ++
        "local ac=hexe.autocmd or {}; local cur=ac[event]; if cur==nil then return false end; " ++
        "if fn==nil then ac[event]=nil; return true end; " ++
        "if type(cur)=='function' then if cur==fn then ac[event]=nil; return true end; return false end; " ++
        "if type(cur)=='table' then local w=1; local removed=false; for i=1,#cur do local f=cur[i]; if f~=fn then cur[w]=f; w=w+1 else removed=true end end; for i=w,#cur do cur[i]=nil end; if #cur==0 then ac[event]=nil end; return removed end; " ++
        "return false end end; " ++
        "if hexe.events.once==nil then hexe.events.once=function(event,fn) " ++
        "if type(fn)~='function' then return nil end; local wrap=nil; wrap=function(ev) hexe.events.off(event,wrap); return fn(ev) end; return hexe.events.on(event,wrap) end end; " ++
        "if hexe.events.debounce==nil then hexe.events.debounce=function(interval_ms,fn) " ++
        "if type(interval_ms)~='number' or interval_ms<0 or type(fn)~='function' then return fn end; local last=nil; return function(ev) local now=0; if type(ev)=='table' and type(ev.now_ms)=='number' then now=ev.now_ms end; if last~=nil and now>=last and (now-last)<interval_ms then return nil end; last=now; return fn(ev) end end end; " ++
        "if hexe.events.throttle==nil then hexe.events.throttle=function(interval_ms,fn) " ++
        "if type(interval_ms)~='number' or interval_ms<0 or type(fn)~='function' then return fn end; local last=nil; return function(ev) local now=0; if type(ev)=='table' and type(ev.now_ms)=='number' then now=ev.now_ms end; if last~=nil and now>=last and (now-last)<interval_ms then return nil end; last=now; return fn(ev) end end end; " ++
        "hexe.status=hexe.status or {}; " ++
        "if hexe.status.current==nil then hexe.status.current=function(c) if type(c)=='table' then return c end; return hexe.ctx.current() end end; " ++
        "if hexe.status.pane==nil then hexe.status.pane=function(sel,c) local cx=hexe.status.current(c); if type(cx)=='table' and type(cx.pane)=='function' then return cx.pane(sel) end; return nil end end; " ++
        "if hexe.status.active_pod==nil then " ++
        "hexe.status.active_pod=function(c) " ++
        "local cx=hexe.status.current(c); " ++
        "if type(cx)~='table' then return nil end; " ++
        "local p=nil; if type(cx.pane)=='function' then p=cx.pane(0) else p=cx end; " ++
        "if type(p)~='table' then return nil end; " ++
        "local u=p.uuid or p.pane_uuid or os.getenv('HEXE_PANE_UUID') or os.getenv('HEXE_FOCUSED_PANE_UUID') or os.getenv('HEXE_STATUS_FOCUSED_PANE_UUID'); " ++
        "if not u or u=='' then return nil end; " ++
        "return { uuid=u, pane=p } end; " ++
        "end; " ++
        "if hexe.status.active_pod_uuid==nil then " ++
        "hexe.status.active_pod_uuid=function(c) local ap=hexe.status.active_pod(c); return ap and ap.uuid or nil end; " ++
        "end; " ++
        "if hexe.status.recording==nil then " ++
        "hexe.status.recording=function(scope) if type(hexe.record)=='table' and type(hexe.record.status)=='function' then return hexe.record.status({ scope=scope or 'pod' }) end; return { active=false, scope=scope or 'pod' } end; " ++
        "end; " ++
        "end";

    const z = std.heap.page_allocator.dupeZ(u8, code) catch return;
    defer std.heap.page_allocator.free(z);
    lua.loadString(z) catch return;
    lua.protectedCall(.{ .args = 0, .results = 0 }) catch {
        lua.pop(1);
        return;
    };
}

/// Configuration loading status
pub const ConfigStatus = enum {
    loaded,
    missing,
    @"error",
};

/// Result of loading a config file
pub const ConfigResult = struct {
    status: ConfigStatus,
    message: ?[]const u8 = null,
};

/// Check if unsafe config mode is enabled
pub fn isUnsafeMode() bool {
    if (posix.getenv("HEXE_UNRESTRICTED_CONFIG")) |v| {
        return std.mem.eql(u8, v, "1");
    }
    // Backward compatibility with legacy env var.
    if (posix.getenv("HEXE_UNSAFE_CONFIG")) |v| {
        return std.mem.eql(u8, v, "1");
    }
    // Default to unrestricted mode unless explicitly disabled.
    return true;
}

/// Get the config directory path
pub fn getConfigDir(allocator: std.mem.Allocator) ![]const u8 {
    if (posix.getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.allocPrint(allocator, "{s}/hexe", .{xdg});
    }
    const home = posix.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.config/hexe", .{home});
}

/// Get the path to a specific config file
pub fn getConfigPath(allocator: std.mem.Allocator, filename: []const u8) ![]const u8 {
    const dir = try getConfigDir(allocator);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, filename });
}

/// Push callback table and function by registered callback id.
/// On success, stack has: [..., callback_table, callback_function].
pub fn pushRegisteredCallback(runtime: *LuaRuntime, callback_id: i32) bool {
    _ = runtime.lua.getField(zlua.registry_index, CALLBACK_TABLE_KEY);
    if (runtime.lua.typeOf(-1) != .table) {
        runtime.lua.pop(1);
        return false;
    }

    _ = runtime.lua.rawGetIndex(-1, callback_id);
    if (runtime.lua.typeOf(-1) != .function) {
        runtime.lua.pop(2);
        return false;
    }
    return true;
}

/// Lua runtime for config loading
pub const LuaRuntime = struct {
    lua: *Lua,
    allocator: std.mem.Allocator,
    unsafe_mode: bool,
    last_error: ?[]const u8 = null,
    config_builder: ?*ConfigBuilder = null,

    const Self = @This();

    /// Create a new Lua runtime
    pub fn init(allocator: std.mem.Allocator) !Self {
        const unsafe = isUnsafeMode();
        var lua = try Lua.init(allocator);

        // Open safe standard libraries
        lua.openBase();
        lua.openTable();
        lua.openString();
        lua.openMath();
        lua.openUtf8();

        // Unsafe mode: open additional libraries
        if (unsafe) {
            lua.openIO();
            lua.openOS();
            lua.openPackage();
        }

        // Set up require
        if (unsafe) {
            try setupUnsafeRequire(lua, allocator);
        } else {
            try setupSafeRequire(lua);
        }

        // Inject hexe module
        try injectHexeModule(lua);

        // Heap-allocate ConfigBuilder so pointer remains stable
        const builder = try allocator.create(ConfigBuilder);
        builder.* = try ConfigBuilder.init(allocator);

        // Store pointer to builder in Lua registry (now it's heap-allocated and stable)
        try api_bridge.storeConfigBuilder(lua, builder);

        // Create runtime instance
        const runtime = Self{
            .lua = lua,
            .allocator = allocator,
            .unsafe_mode = unsafe,
            .config_builder = builder,
        };

        return runtime;
    }

    pub fn deinit(self: *Self) void {
        if (self.last_error) |err| {
            self.allocator.free(err);
        }
        if (self.config_builder) |builder| {
            builder.deinit();
            self.allocator.destroy(builder);
        }
        self.lua.deinit();
    }

    /// Get the config builder for API functions to use
    pub fn getBuilder(self: *Self) ?*ConfigBuilder {
        return self.config_builder;
    }

    /// Set the target section for config evaluation.
    ///
    /// This is a performance knob: a single config file can branch on
    /// `HEXE_SECTION` and only construct the relevant subtree (mux/shp/pop/etc).
    pub fn setHexeSection(self: *Self, section: []const u8) void {
        _ = self.lua.pushString(section);
        self.lua.setGlobal("HEXE_SECTION");
    }

    pub fn clearHexeSection(self: *Self) void {
        self.lua.pushNil();
        self.lua.setGlobal("HEXE_SECTION");
    }

    /// Load a Lua config file and return the top-level table
    /// Returns the index of the table on the stack (always 1 after successful load)
    pub fn loadConfig(self: *Self, path: []const u8) !void {
        // Clear any previous error
        if (self.last_error) |err| {
            self.allocator.free(err);
            self.last_error = null;
        }

        // Path needs to be null-terminated for loadFile
        const path_z = self.allocator.dupeZ(u8, path) catch return error.OutOfMemory;
        defer self.allocator.free(path_z);

        // Load and execute the file
        self.lua.loadFile(path_z, .binary_text) catch |err| {
            if (err == error.LuaFile) {
                return error.FileNotFound;
            }
            self.last_error = try self.allocator.dupe(u8, self.getErrorMessage());
            return error.LuaError;
        };

        // Execute the loaded chunk
        self.lua.protectedCall(.{ .args = 0, .results = 1 }) catch {
            self.last_error = try self.allocator.dupe(u8, self.getErrorMessage());
            return error.LuaError;
        };

        // New API: config may or may not return a value
        // (old table-based API returned a table, new dynamic API returns nil)
        // We accept any return value for backward compatibility
    }

    fn getErrorMessage(self: *Self) []const u8 {
        if (self.lua.typeOf(-1) == .string) {
            return self.lua.toString(-1) catch "unknown error";
        }
        return "unknown error";
    }

    // ===== Table reading helpers =====

    /// Get a string field from the table at the given index
    pub fn getString(self: *Self, table_idx: i32, key: [:0]const u8) ?[]const u8 {
        _ = self.lua.getField(table_idx, key);
        defer self.lua.pop(1);
        if (self.lua.typeOf(-1) == .string) {
            return self.lua.toString(-1) catch null;
        }
        return null;
    }

    /// Get an allocated copy of a string field
    pub fn getStringAlloc(self: *Self, table_idx: i32, key: [:0]const u8) ?[]const u8 {
        if (self.getString(table_idx, key)) |s| {
            return self.allocator.dupe(u8, s) catch null;
        }
        return null;
    }

    /// Get an integer field from the table
    pub fn getInt(self: *Self, comptime T: type, table_idx: i32, key: [:0]const u8) ?T {
        _ = self.lua.getField(table_idx, key);
        defer self.lua.pop(1);
        if (self.lua.typeOf(-1) == .number) {
            const val = self.lua.toInteger(-1) catch return null;
            return std.math.cast(T, val);
        }
        return null;
    }

    /// Get a number field from the table
    pub fn getNumber(self: *Self, table_idx: i32, key: [:0]const u8) ?f64 {
        _ = self.lua.getField(table_idx, key);
        defer self.lua.pop(1);
        if (self.lua.typeOf(-1) == .number) {
            return self.lua.toNumber(-1) catch null;
        }
        return null;
    }

    /// Get a boolean field from the table
    pub fn getBool(self: *Self, table_idx: i32, key: [:0]const u8) ?bool {
        _ = self.lua.getField(table_idx, key);
        defer self.lua.pop(1);
        if (self.lua.typeOf(-1) == .boolean) {
            return self.lua.toBoolean(-1);
        }
        return null;
    }

    /// Push a table field onto the stack (caller must pop when done)
    pub fn pushTable(self: *Self, table_idx: i32, key: [:0]const u8) bool {
        _ = self.lua.getField(table_idx, key);
        if (self.lua.typeOf(-1) == .table) {
            return true;
        }
        self.lua.pop(1);
        return false;
    }

    /// Get the length of an array table at the given stack index
    pub fn getArrayLen(self: *Self, table_idx: i32) usize {
        return @intCast(self.lua.rawLen(table_idx));
    }

    /// Push array element at 1-based index onto stack (caller must pop)
    pub fn pushArrayElement(self: *Self, table_idx: i32, index: usize) bool {
        _ = self.lua.rawGetIndex(table_idx, @intCast(index));
        if (self.lua.typeOf(-1) != .nil) {
            return true;
        }
        self.lua.pop(1);
        return false;
    }

    /// Pop the top element from the stack
    pub fn pop(self: *Self) void {
        self.lua.pop(1);
    }

    /// Get the type at stack index
    pub fn typeOf(self: *Self, idx: i32) LuaType {
        return self.lua.typeOf(idx);
    }

    /// Get the type of a field in a table.
    pub fn fieldType(self: *Self, table_idx: i32, key: [:0]const u8) LuaType {
        _ = self.lua.getField(table_idx, key);
        defer self.lua.pop(1);
        return self.lua.typeOf(-1);
    }

    /// Convert stack top to string
    pub fn toStringAt(self: *Self, idx: i32) ?[]const u8 {
        return self.lua.toString(idx) catch null;
    }

    /// Convert stack top to integer
    pub fn toIntAt(self: *Self, comptime T: type, idx: i32) ?T {
        const val = self.lua.toInteger(idx) catch return null;
        return std.math.cast(T, val);
    }
};

// ===== Internal setup functions =====

fn setupSafeRequire(lua: *Lua) !void {
    // In safe mode, only allow require("hexe")
    lua.pushFunction(safeRequire);
    lua.setGlobal("require");
}

fn safeRequire(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    const name = lua.toString(1) catch {
        _ = lua.pushString("require: expected string argument");
        lua.raiseError();
    };

    if (std.mem.eql(u8, name, "hexe")) {
        // Return the hexe module from registry
        _ = lua.getField(zlua.registry_index, "_hexe_module");
        return 1;
    }

    _ = lua.pushString("require() not allowed in safe mode");
    lua.raiseError();
}

fn setupUnsafeRequire(lua: *Lua, allocator: std.mem.Allocator) !void {
    // Set up restricted package.path (only hexe config dirs)
    const config_dir = getConfigDir(allocator) catch return;
    defer allocator.free(config_dir);

    const path = std.fmt.allocPrint(allocator, "{s}/lua/?.lua;{s}/lua/?/init.lua", .{ config_dir, config_dir }) catch return;
    defer allocator.free(path);
    const path_z = allocator.dupeZ(u8, path) catch return;
    defer allocator.free(path_z);

    // Set package.path
    _ = lua.getGlobal("package") catch return;
    if (lua.typeOf(-1) == .table) {
        _ = lua.pushString(path_z);
        lua.setField(-2, "path");
        // Clear cpath to disable native modules
        _ = lua.pushString("");
        lua.setField(-2, "cpath");
    }
    lua.pop(1);

    // Preload hexe module
    _ = lua.getGlobal("package") catch return;
    if (lua.typeOf(-1) == .table) {
        _ = lua.getField(-1, "preload");
        if (lua.typeOf(-1) == .table) {
            lua.pushFunction(hexeLoader);
            lua.setField(-2, "hexe");
        }
        lua.pop(1); // preload
    }
    lua.pop(1); // package
}

fn injectHexeModule(lua: *Lua) !void {
    // Create the hexe module table
    lua.createTable(0, 5);

    // hx.mod = { ctrl = 2, alt = 1, shift = 4, super = 8 }
    lua.createTable(0, 4);
    lua.pushInteger(2);
    lua.setField(-2, "ctrl");
    lua.pushInteger(1);
    lua.setField(-2, "alt");
    lua.pushInteger(4);
    lua.setField(-2, "shift");
    lua.pushInteger(8);
    lua.setField(-2, "super");
    lua.setField(-2, "mod");

    // hx.when = { press = "press", release = "release", repeat = "repeat", hold = "hold" }
    lua.createTable(0, 4);
    _ = lua.pushString("press");
    lua.setField(-2, "press");
    _ = lua.pushString("release");
    lua.setField(-2, "release");
    _ = lua.pushString("repeat");
    lua.setField(-2, "repeat");
    _ = lua.pushString("hold");
    lua.setField(-2, "hold");
    lua.setField(-2, "when");

    // hx.action = { mux_quit = "mux.quit", tab_new = "tab.new", ... }
    lua.createTable(0, 21);
    _ = lua.pushString("mux.quit");
    lua.setField(-2, "mux_quit");
    _ = lua.pushString("mux.detach");
    lua.setField(-2, "mux_detach");
    _ = lua.pushString("pane.disown");
    lua.setField(-2, "pane_disown");
    _ = lua.pushString("pane.adopt");
    lua.setField(-2, "pane_adopt");
    _ = lua.pushString("pane.select_mode");
    lua.setField(-2, "pane_select_mode");
    _ = lua.pushString("clipboard.copy");
    lua.setField(-2, "clipboard_copy");
    _ = lua.pushString("clipboard.request");
    lua.setField(-2, "clipboard_request");
    _ = lua.pushString("system.notify");
    lua.setField(-2, "system_notify");
    _ = lua.pushString("overlay.keycast_toggle");
    lua.setField(-2, "keycast_toggle");
    _ = lua.pushString("overlay.sprite_toggle");
    lua.setField(-2, "sprite_toggle");
    _ = lua.pushString("split.h");
    lua.setField(-2, "split_h");
    _ = lua.pushString("split.v");
    lua.setField(-2, "split_v");
    _ = lua.pushString("split.resize");
    lua.setField(-2, "split_resize");
    _ = lua.pushString("tab.new");
    lua.setField(-2, "tab_new");
    _ = lua.pushString("tab.next");
    lua.setField(-2, "tab_next");
    _ = lua.pushString("tab.prev");
    lua.setField(-2, "tab_prev");
    _ = lua.pushString("tab.close");
    lua.setField(-2, "tab_close");
    _ = lua.pushString("float.toggle");
    lua.setField(-2, "float_toggle");
    _ = lua.pushString("float.nudge");
    lua.setField(-2, "float_nudge");
    _ = lua.pushString("focus.move");
    lua.setField(-2, "focus_move");
    _ = lua.pushString("layout.save");
    lua.setField(-2, "layout_save");
    _ = lua.pushString("layout.load");
    lua.setField(-2, "layout_load");
    lua.setField(-2, "action");

    // hx.mode = { act_and_consume = "act_and_consume", act_and_passthrough = "act_and_passthrough", passthrough_only = "passthrough_only" }
    lua.createTable(0, 3);
    _ = lua.pushString("act_and_consume");
    lua.setField(-2, "act_and_consume");
    _ = lua.pushString("act_and_passthrough");
    lua.setField(-2, "act_and_passthrough");
    _ = lua.pushString("passthrough_only");
    lua.setField(-2, "passthrough_only");
    lua.setField(-2, "mode");

    // hx.key = { ctrl, alt, shift, super, a-z, 0-9, up, down, left, right, space, ... }
    // Usage: key = { hx.key.alt, hx.key.right } or key = { hx.key.ctrl, hx.key.alt, hx.key.q }
    lua.createTable(0, 64);
    // Modifiers (prefixed with "mod:" to distinguish from keys)
    _ = lua.pushString("mod:ctrl");
    lua.setField(-2, "ctrl");
    _ = lua.pushString("mod:alt");
    lua.setField(-2, "alt");
    _ = lua.pushString("mod:shift");
    lua.setField(-2, "shift");
    _ = lua.pushString("mod:super");
    lua.setField(-2, "super");
    // Arrow keys
    _ = lua.pushString("up");
    lua.setField(-2, "up");
    _ = lua.pushString("down");
    lua.setField(-2, "down");
    _ = lua.pushString("left");
    lua.setField(-2, "left");
    _ = lua.pushString("right");
    lua.setField(-2, "right");
    // Special keys
    _ = lua.pushString("space");
    lua.setField(-2, "space");
    _ = lua.pushString("enter");
    lua.setField(-2, "enter");
    _ = lua.pushString("tab");
    lua.setField(-2, "tab");
    _ = lua.pushString("esc");
    lua.setField(-2, "esc");
    _ = lua.pushString("backspace");
    lua.setField(-2, "backspace");
    // Letters a-z
    inline for ("abcdefghijklmnopqrstuvwxyz") |c| {
        _ = lua.pushString(&[_]u8{c});
        lua.setField(-2, &[_:0]u8{c});
    }
    // Numbers 0-9
    inline for ("0123456789") |c| {
        _ = lua.pushString(&[_]u8{c});
        lua.setField(-2, &[_:0]u8{c});
    }
    // Common punctuation
    _ = lua.pushString(".");
    lua.setField(-2, "dot");
    _ = lua.pushString(",");
    lua.setField(-2, "comma");
    _ = lua.pushString(";");
    lua.setField(-2, "semicolon");
    _ = lua.pushString("/");
    lua.setField(-2, "slash");
    _ = lua.pushString("-");
    lua.setField(-2, "minus");
    _ = lua.pushString("=");
    lua.setField(-2, "equal");
    _ = lua.pushString("[");
    lua.setField(-2, "lbracket");
    _ = lua.pushString("]");
    lua.setField(-2, "rbracket");
    lua.setField(-2, "key");

    // hexe.mux = { config = {}, keymap = {}, float = {}, tabs = {}, splits = {} }
    lua.createTable(0, 5);

    // hexe.mux.config = { set = fn, setup = fn }
    lua.createTable(0, 2);
    lua.pushFunction(hexe_mux_config_set);
    lua.setField(-2, "set");
    lua.pushFunction(hexe_mux_config_setup);
    lua.setField(-2, "setup");
    lua.setField(-2, "config");

    // hexe.mux.keymap = { set = fn }
    lua.createTable(0, 1);
    lua.pushFunction(hexe_mux_keymap_set);
    lua.setField(-2, "set");
    lua.setField(-2, "keymap");

    // hexe.mux.float = { set_defaults = fn, set_adhoc = fn, set_match = fn, define = fn }
    lua.createTable(0, 4);
    lua.pushFunction(hexe_mux_float_set_defaults);
    lua.setField(-2, "set_defaults");
    lua.pushFunction(hexe_mux_float_set_adhoc);
    lua.setField(-2, "set_adhoc");
    lua.pushFunction(hexe_mux_float_set_match);
    lua.setField(-2, "set_match");
    lua.pushFunction(hexe_mux_float_define);
    lua.setField(-2, "define");
    lua.setField(-2, "float");

    // hexe.mux.tabs = { add_segment = fn, set_status = fn }
    lua.createTable(0, 2);
    lua.pushFunction(hexe_mux_tabs_add_segment);
    lua.setField(-2, "add_segment");
    lua.pushFunction(hexe_mux_tabs_set_status);
    lua.setField(-2, "set_status");
    lua.setField(-2, "tabs");

    // hexe.mux.splits = { setup = fn }
    lua.createTable(0, 1);
    lua.pushFunction(hexe_mux_splits_setup);
    lua.setField(-2, "setup");
    lua.setField(-2, "splits");

    lua.setField(-2, "mux");

    // hexe.ses = { layout = {}, session = {} }
    lua.createTable(0, 2);

    // hexe.ses.layout = { define = fn }
    lua.createTable(0, 1);
    lua.pushFunction(hexe_ses_layout_define);
    lua.setField(-2, "define");
    lua.setField(-2, "layout");

    // hexe.ses.session = { setup = fn }
    lua.createTable(0, 1);
    lua.pushFunction(hexe_ses_session_setup);
    lua.setField(-2, "setup");
    lua.setField(-2, "session");

    // hexe.ses.isolation = { set = fn }
    lua.createTable(0, 1);
    lua.pushFunction(hexe_ses_isolation_set);
    lua.setField(-2, "set");
    lua.setField(-2, "isolation");

    lua.setField(-2, "ses");

    // hexe.shp = { prompt = {}, segment = {} }
    lua.createTable(0, 2);

    // hexe.shp.prompt = { left = fn, right = fn, add = fn }
    lua.createTable(0, 3);
    lua.pushFunction(hexe_shp_prompt_left);
    lua.setField(-2, "left");
    lua.pushFunction(hexe_shp_prompt_right);
    lua.setField(-2, "right");
    lua.pushFunction(hexe_shp_prompt_add);
    lua.setField(-2, "add");
    lua.setField(-2, "prompt");

    lua.createTable(0, 0); // hexe.shp.segment (TODO: builder pattern)
    lua.setField(-2, "segment");
    lua.setField(-2, "shp");

    // hexe.pop = { notify = {}, confirm = {}, choose = {}, widgets = {} }
    lua.createTable(0, 4);

    // hexe.pop.notify = { setup = fn }
    lua.createTable(0, 1);
    lua.pushFunction(hexe_pop_notify_setup);
    lua.setField(-2, "setup");
    lua.setField(-2, "notify");

    // hexe.pop.confirm = { setup = fn }
    lua.createTable(0, 1);
    lua.pushFunction(hexe_pop_confirm_setup);
    lua.setField(-2, "setup");
    lua.setField(-2, "confirm");

    // hexe.pop.choose = { setup = fn }
    lua.createTable(0, 1);
    lua.pushFunction(hexe_pop_choose_setup);
    lua.setField(-2, "setup");
    lua.setField(-2, "choose");

    // hexe.pop.widgets = { pokemon = fn, keycast = fn, digits = fn }
    lua.createTable(0, 3);
    lua.pushFunction(hexe_pop_widgets_pokemon);
    lua.setField(-2, "pokemon");
    lua.pushFunction(hexe_pop_widgets_keycast);
    lua.setField(-2, "keycast");
    lua.pushFunction(hexe_pop_widgets_digits);
    lua.setField(-2, "digits");
    lua.setField(-2, "widgets");

    lua.setField(-2, "pop");

    // hexe.record = { start = fn, stop = fn, toggle = fn, status = fn }
    lua.createTable(0, 4);
    lua.pushFunction(hexe_record_start);
    lua.setField(-2, "start");
    lua.pushFunction(hexe_record_stop);
    lua.setField(-2, "stop");
    lua.pushFunction(hexe_record_toggle);
    lua.setField(-2, "toggle");
    lua.pushFunction(hexe_record_status);
    lua.setField(-2, "status");
    lua.setField(-2, "record");

    // Internal storage table for event handlers.
    // Public API is injected as hx.events.* in injectStatusHelpers().
    lua.createTable(0, 1);
    lua.pushFunction(hexe_autocmd_on);
    lua.setField(-2, "on");
    lua.setField(-2, "autocmd");

    // hexe.api = { exec = fn }
    lua.createTable(0, 1);
    lua.pushFunction(hexe_api_exec);
    lua.setField(-2, "exec");
    lua.setField(-2, "api");

    // hexe.color = { fg = fn, bg = fn }
    lua.createTable(0, 2);
    lua.pushFunction(hexe_color_fg);
    lua.setField(-2, "fg");
    lua.pushFunction(hexe_color_bg);
    lua.setField(-2, "bg");
    lua.setField(-2, "color");

    // hexe.segment = { <builtin_name> = fn(ctx) -> marker }
    lua.createTable(0, 23);
    lua.pushFunction(hexe_segment_tabs);
    lua.setField(-2, "tabs");
    lua.pushFunction(hexe_segment_session);
    lua.setField(-2, "session");
    lua.pushFunction(hexe_segment_directory);
    lua.setField(-2, "directory");
    lua.pushFunction(hexe_segment_git_branch);
    lua.setField(-2, "git_branch");
    lua.pushFunction(hexe_segment_git_status);
    lua.setField(-2, "git_status");
    lua.pushFunction(hexe_segment_jobs);
    lua.setField(-2, "jobs");
    lua.pushFunction(hexe_segment_duration);
    lua.setField(-2, "duration");
    lua.pushFunction(hexe_segment_status);
    lua.setField(-2, "status");
    lua.pushFunction(hexe_segment_sudo);
    lua.setField(-2, "sudo");
    lua.pushFunction(hexe_segment_pod_name);
    lua.setField(-2, "pod_name");
    lua.pushFunction(hexe_segment_hostname);
    lua.setField(-2, "hostname");
    lua.pushFunction(hexe_segment_username);
    lua.setField(-2, "username");
    lua.pushFunction(hexe_segment_time);
    lua.setField(-2, "time");
    lua.pushFunction(hexe_segment_cpu);
    lua.setField(-2, "cpu");
    lua.pushFunction(hexe_segment_memory);
    lua.setField(-2, "memory");
    lua.pushFunction(hexe_segment_mem);
    lua.setField(-2, "mem");
    lua.pushFunction(hexe_segment_netspeed);
    lua.setField(-2, "netspeed");
    lua.pushFunction(hexe_segment_battery);
    lua.setField(-2, "battery");
    lua.pushFunction(hexe_segment_uptime);
    lua.setField(-2, "uptime");
    lua.pushFunction(hexe_segment_last_command);
    lua.setField(-2, "last_command");
    lua.pushFunction(hexe_segment_randomdo);
    lua.setField(-2, "randomdo");
    lua.pushFunction(hexe_segment_spinner);
    lua.setField(-2, "spinner");
    lua.pushFunction(hexe_segment_title);
    lua.setField(-2, "title");

    // hx.segment.builtin.<name>({ ...settings... }) -> descriptor table
    lua.createTable(0, 23);
    lua.pushFunction(hexe_segment_builtin_tabs);
    lua.setField(-2, "tabs");
    lua.pushFunction(hexe_segment_builtin_session);
    lua.setField(-2, "session");
    lua.pushFunction(hexe_segment_builtin_directory);
    lua.setField(-2, "directory");
    lua.pushFunction(hexe_segment_builtin_git_branch);
    lua.setField(-2, "git_branch");
    lua.pushFunction(hexe_segment_builtin_git_status);
    lua.setField(-2, "git_status");
    lua.pushFunction(hexe_segment_builtin_jobs);
    lua.setField(-2, "jobs");
    lua.pushFunction(hexe_segment_builtin_duration);
    lua.setField(-2, "duration");
    lua.pushFunction(hexe_segment_builtin_status);
    lua.setField(-2, "status");
    lua.pushFunction(hexe_segment_builtin_sudo);
    lua.setField(-2, "sudo");
    lua.pushFunction(hexe_segment_builtin_pod_name);
    lua.setField(-2, "pod_name");
    lua.pushFunction(hexe_segment_builtin_hostname);
    lua.setField(-2, "hostname");
    lua.pushFunction(hexe_segment_builtin_username);
    lua.setField(-2, "username");
    lua.pushFunction(hexe_segment_builtin_time);
    lua.setField(-2, "time");
    lua.pushFunction(hexe_segment_builtin_cpu);
    lua.setField(-2, "cpu");
    lua.pushFunction(hexe_segment_builtin_memory);
    lua.setField(-2, "memory");
    lua.pushFunction(hexe_segment_builtin_mem);
    lua.setField(-2, "mem");
    lua.pushFunction(hexe_segment_builtin_netspeed);
    lua.setField(-2, "netspeed");
    lua.pushFunction(hexe_segment_builtin_battery);
    lua.setField(-2, "battery");
    lua.pushFunction(hexe_segment_builtin_uptime);
    lua.setField(-2, "uptime");
    lua.pushFunction(hexe_segment_builtin_last_command);
    lua.setField(-2, "last_command");
    lua.pushFunction(hexe_segment_builtin_randomdo);
    lua.setField(-2, "randomdo");
    lua.pushFunction(hexe_segment_builtin_spinner);
    lua.setField(-2, "spinner");
    lua.pushFunction(hexe_segment_builtin_title);
    lua.setField(-2, "title");
    lua.setField(-2, "builtin");

    lua.setField(-2, "segment");

    // hexe.plugin = {}
    lua.createTable(0, 0);
    lua.setField(-2, "plugin");

    // hx.version
    _ = lua.pushString("0.1.0");
    lua.setField(-2, "version");

    // Store in registry for safe require
    lua.pushValue(-1); // duplicate
    lua.setField(zlua.registry_index, "_hexe_module");

    // Also expose as global for callback runtime convenience.
    lua.pushValue(-1); // duplicate
    lua.setGlobal("hexe");
    lua.pushValue(-1); // duplicate
    lua.setGlobal("hx");

    // hexe.record(target).start/stop/toggle helper (target = uuid or opts table)
    injectRecordTargetHelper(lua);
    injectStatusHelpers(lua);
}

fn hexeLoader(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    // Return the hexe module from registry
    _ = lua.getField(zlua.registry_index, "_hexe_module");
    return 1;
}

fn pushSegmentMarker(lua: *Lua, name: []const u8) c_int {
    const marker = std.fmt.allocPrint(std.heap.page_allocator, "__hexe_builtin:{s}", .{name}) catch {
        lua.pushNil();
        return 1;
    };
    defer std.heap.page_allocator.free(marker);
    _ = lua.pushString(marker);
    return 1;
}

fn pushBuiltinDescriptor(lua: *Lua, name: []const u8) c_int {
    lua.createTable(0, 12);
    _ = lua.pushString(name);
    lua.setField(-2, "name");

    if (lua.typeOf(1) != .table) return 1;

    const keys = [_][:0]const u8{
        "style",
        "prefix",
        "suffix",
        "kind",
        "width",
        "step",
        "step_ms",
        "hold",
        "hold_frames",
        "colors",
        "bg",
        "bg_color",
        "placeholder",
        "placeholder_color",
    };

    for (keys) |key| {
        _ = lua.getField(1, key);
        if (lua.typeOf(-1) != .nil) {
            lua.setField(-2, key);
        } else {
            lua.pop(1);
        }
    }

    return 1;
}

fn hexe_segment_tabs(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushSegmentMarker(lua, "tabs");
}
fn hexe_segment_session(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushSegmentMarker(lua, "session");
}
fn hexe_segment_directory(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushSegmentMarker(lua, "directory");
}
fn hexe_segment_git_branch(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushSegmentMarker(lua, "git_branch");
}
fn hexe_segment_git_status(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushSegmentMarker(lua, "git_status");
}
fn hexe_segment_jobs(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushSegmentMarker(lua, "jobs");
}
fn hexe_segment_duration(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushSegmentMarker(lua, "duration");
}
fn hexe_segment_status(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushSegmentMarker(lua, "status");
}
fn hexe_segment_sudo(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushSegmentMarker(lua, "sudo");
}
fn hexe_segment_pod_name(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushSegmentMarker(lua, "pod_name");
}
fn hexe_segment_hostname(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushSegmentMarker(lua, "hostname");
}
fn hexe_segment_username(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushSegmentMarker(lua, "username");
}
fn hexe_segment_time(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushSegmentMarker(lua, "time");
}
fn hexe_segment_cpu(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushSegmentMarker(lua, "cpu");
}
fn hexe_segment_memory(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushSegmentMarker(lua, "memory");
}
fn hexe_segment_mem(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushSegmentMarker(lua, "mem");
}
fn hexe_segment_netspeed(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushSegmentMarker(lua, "netspeed");
}
fn hexe_segment_battery(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushSegmentMarker(lua, "battery");
}
fn hexe_segment_uptime(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushSegmentMarker(lua, "uptime");
}
fn hexe_segment_last_command(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushSegmentMarker(lua, "last_command");
}
fn hexe_segment_randomdo(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushSegmentMarker(lua, "randomdo");
}
fn hexe_segment_spinner(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushSegmentMarker(lua, "spinner");
}
fn hexe_segment_title(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushSegmentMarker(lua, "title");
}

fn hexe_segment_builtin_tabs(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushBuiltinDescriptor(lua, "tabs");
}
fn hexe_segment_builtin_session(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushBuiltinDescriptor(lua, "session");
}
fn hexe_segment_builtin_directory(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushBuiltinDescriptor(lua, "directory");
}
fn hexe_segment_builtin_git_branch(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushBuiltinDescriptor(lua, "git_branch");
}
fn hexe_segment_builtin_git_status(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushBuiltinDescriptor(lua, "git_status");
}
fn hexe_segment_builtin_jobs(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushBuiltinDescriptor(lua, "jobs");
}
fn hexe_segment_builtin_duration(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushBuiltinDescriptor(lua, "duration");
}
fn hexe_segment_builtin_status(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushBuiltinDescriptor(lua, "status");
}
fn hexe_segment_builtin_sudo(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushBuiltinDescriptor(lua, "sudo");
}
fn hexe_segment_builtin_pod_name(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushBuiltinDescriptor(lua, "pod_name");
}
fn hexe_segment_builtin_hostname(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushBuiltinDescriptor(lua, "hostname");
}
fn hexe_segment_builtin_username(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushBuiltinDescriptor(lua, "username");
}
fn hexe_segment_builtin_time(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushBuiltinDescriptor(lua, "time");
}
fn hexe_segment_builtin_cpu(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushBuiltinDescriptor(lua, "cpu");
}
fn hexe_segment_builtin_memory(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushBuiltinDescriptor(lua, "memory");
}
fn hexe_segment_builtin_mem(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushBuiltinDescriptor(lua, "mem");
}
fn hexe_segment_builtin_netspeed(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushBuiltinDescriptor(lua, "netspeed");
}
fn hexe_segment_builtin_battery(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushBuiltinDescriptor(lua, "battery");
}
fn hexe_segment_builtin_uptime(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushBuiltinDescriptor(lua, "uptime");
}
fn hexe_segment_builtin_last_command(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushBuiltinDescriptor(lua, "last_command");
}
fn hexe_segment_builtin_randomdo(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushBuiltinDescriptor(lua, "randomdo");
}
fn hexe_segment_builtin_spinner(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushBuiltinDescriptor(lua, "spinner");
}
fn hexe_segment_builtin_title(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    return pushBuiltinDescriptor(lua, "title");
}

fn hexe_color_fg(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    const n = lua.toInteger(1) catch {
        lua.pushNil();
        return 1;
    };
    const s = std.fmt.allocPrint(std.heap.page_allocator, "fg:{d}", .{n}) catch {
        lua.pushNil();
        return 1;
    };
    defer std.heap.page_allocator.free(s);
    _ = lua.pushString(s);
    return 1;
}

fn hexe_color_bg(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    const n = lua.toInteger(1) catch {
        lua.pushNil();
        return 1;
    };
    const s = std.fmt.allocPrint(std.heap.page_allocator, "bg:{d}", .{n}) catch {
        lua.pushNil();
        return 1;
    };
    defer std.heap.page_allocator.free(s);
    _ = lua.pushString(s);
    return 1;
}

// ===== Parsing helpers for configs =====

/// Parse a Unicode character from a Lua string field
pub fn parseUnicodeChar(runtime: *LuaRuntime, table_idx: i32, key: [:0]const u8, default: u21) u21 {
    const str = runtime.getString(table_idx, key) orelse return default;
    if (str.len == 0) return default;
    return std.unicode.utf8Decode(str) catch default;
}

/// Parse a constrained integer (with min/max bounds)
pub fn parseConstrainedInt(runtime: *LuaRuntime, comptime T: type, table_idx: i32, key: [:0]const u8, min: T, max: T, default: T) T {
    const val = runtime.getInt(i64, table_idx, key) orelse return default;
    if (val < min) return min;
    if (val > max) return max;
    return @intCast(val);
}
