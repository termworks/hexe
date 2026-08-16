#!/usr/bin/env python3
"""Live check: a keybinding condition is a plain Lua function over live state.

Two runs of the SAME keypress sequence, differing only in the config:

  control:     ctrl+t -> tab.new(), no condition        -> 3 tabs
  conditional: ctrl+t -> tab.new(), when count < 2      -> 2 tabs

The control run is not decoration. Without it, "the third tab did not appear"
is equally explained by the action having failed for its own reasons, and the
test would pass against a predicate that is never evaluated at all. Only the
pair shows the predicate is what stopped it.
"""
import atexit
import fcntl, os, pty, signal, struct, subprocess, sys, termios, time, json

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)

CONDITIONAL = """
local hexe = require("hexe")
return hexe.setup({
  keys = {
    -- Ordinary Lua over live state: no token language, no DSL.
    hexe.key({ hexe.key.ctrl, hexe.key.t }, hexe.action.tab.new(), {
      when = function() return hexe.live.count("tabs") < 2 end,
    }),
  },
})
"""

ACTION = """
local hexe = require("hexe")
return hexe.setup({
  keys = {
    -- The action itself is a Lua function: the binding is not limited to the
    -- built-in action list, and the callback can read live state while it runs.
    hexe.key({ hexe.key.ctrl, hexe.key.t }, function(ctx)
      local f = io.open("MARKER_PATH", "w")
      if f then
        f:write(string.format("tabs=%d panes=%d floats=%d",
          ctx.count("tabs"), ctx.count("panes"), ctx.count("visible_floats")))
        f:close()
      end
    end),
  },
})
"""

# Breaking-change guard: the pre-rewrite names must be GONE, not aliased, and
# the replacements must all be present. If either half is wrong the predicate
# errors, which reads as false, and the tab is never created.
NO_ALIASES = """
local hexe = require("hexe")
return hexe.setup({
  keys = {
    hexe.key({ hexe.key.ctrl, hexe.key.t }, hexe.action.tab.new(), {
      when = function(ctx)
        local p = ctx.pane()
        local removed = { "process_name", "focus_split", "focus_float", "floating",
                          "float_sticky", "float_exclusive", "float_per_cwd",
                          "float_global", "float_isolated", "float_destroyable",
                          "tab_index", "pane_index" }
        for _, name in ipairs(removed) do
          if p[name] ~= nil then error("alias still present: " .. name) end
        end
        assert(type(p.is_split) == "boolean")
        assert(type(p.is_float) == "boolean")
        assert(type(p.sticky) == "boolean")
        assert(type(p.index) == "number")
        assert(type(p.exclusive) == "boolean")
        return true
      end,
    }),
  },
})
"""

# The imperative half: a keybinding whose action is Lua that DOES things —
# dispatches a real action, focuses a pane by selector, and notifies. If any of
# these are not callable the tab is never created and the marker never appears.
PLUGIN = """
local hexe = require("hexe")
return hexe.setup({
  keys = {
    hexe.key({ hexe.key.ctrl, hexe.key.t }, function(ctx)
      -- 1. dispatch a built-in action through the universal entry point
      ctx.act(hexe.action.tab.new())
      -- 2. act on what we can see
      local before = ctx.count("tabs")
      ctx.notify(string.format("tabs now %d", before), 500)
      -- 3. focus a pane by selector and type into it
      local p = ctx.pane()
      ctx.focus(p.uuid)
      ctx.send(p.uuid, "")
      -- 4. the rest of the imperative surface. Order matters: these run AFTER
      -- ctx.focus(), which emits an event that itself binds the live API. If
      -- that nesting restores instead of clears, these still work; if it
      -- clears, every one of them silently returns nothing.
      ctx.scroll(0)
      local exec_ok = type(ctx.exec) == "function"
      local ok_rename = ctx.rename_tab("renamed-by-plugin")
      local named = "rc=" .. tostring(ok_rename) .. " names="
      for _, t in ipairs(ctx.tabs()) do
        named = named .. "[" .. tostring(t.name) .. "]"
      end
      local f = io.open("MARKER_PATH", "w")
      if f then
        f:write(string.format("tabs=%d focused=%s exec=%s renamed=%s",
          before, tostring(p.uuid ~= nil), tostring(exec_ok), named))
        f:close()
      end
    end),
  },
})
"""

# Events. `hexe.events.on` stored handlers in one table while the emitter read
# another, so registration raised and no event was ever delivered — silently,
# because a config that registers a handler simply failed to load.
EVENTS = """
local hexe = require("hexe")
local seen = {}
hexe.events.on("tab_created", function(ev)
  seen[#seen+1] = "created:" .. tostring(ev.tab) .. "/" .. tostring(ev.tab_count)
  local f = io.open("MARKER_PATH", "w"); f:write(table.concat(seen, " ")); f:close()
end)
hexe.events.on("pane_focus_changed", function(ev)
  seen[#seen+1] = "focus"
  local f = io.open("MARKER_PATH", "w"); f:write(table.concat(seen, " ")); f:close()
end)
-- tab_changed used to be emitted only from nextTab/prevTab, which the
-- tab_next/tab_prev binds do not call — so it effectively never fired.
hexe.events.on("tab_changed", function(ev)
  seen[#seen+1] = "changed:" .. tostring(ev.previous_tab) .. "->" .. tostring(ev.active_tab)
  local f = io.open("MARKER_PATH", "w"); f:write(table.concat(seen, " ")); f:close()
end)
return hexe.setup({
  keys = { hexe.key({ hexe.key.ctrl, hexe.key.t }, hexe.action.tab.new()) },
})
"""

# Bounded content reads. Every one of these is capped by construction; the
# assertion below is that they return the pane's ACTUAL text, since a read that
# silently returns "" is indistinguishable from a working one that found nothing.
CONTENT = """
local hexe = require("hexe")
return hexe.setup({
  keys = {
    hexe.key({ hexe.key.ctrl, hexe.key.t }, function(ctx)
      local out = {}
      out[#out+1] = "line0=" .. tostring(ctx.line(0))
      out[#out+1] = "cursor=" .. tostring(ctx.cursor_line())
      out[#out+1] = "find=" .. tostring(ctx.find("HEXEMARK"))
      out[#out+1] = "absent=" .. tostring(ctx.find("zzzznope"))
      local full = ctx.screen_text() or ""
      local capped = ctx.screen_text{ max_bytes = 2048 } or ""
      out[#out+1] = "full_mark=" .. tostring(full:find("HEXEMARK") ~= nil)
      out[#out+1] = "capped_mark=" .. tostring(capped:find("HEXEMARK") ~= nil)
      out[#out+1] = "capped_len_ok=" .. tostring(#capped <= 2048)
      -- SES-side facts. These ride the pane_info response, which can arrive on
      -- either of two reader paths; both must keep them or the fields flicker.
      local p = ctx.pane()
      out[#out+1] = "pid_ok=" .. tostring(type(p.pid) == "number" and p.pid > 0)
      out[#out+1] = "ses_state=" .. tostring(p.ses_state)
      out[#out+1] = "age_ok=" .. tostring(type(p.age_ms) == "number")
      out[#out+1] = "pw=" .. tostring(p.password_input)
      local f = io.open("MARKER_PATH", "w"); f:write(table.concat(out, " ")); f:close()
    end),
  },
})
"""

CONTROL = """
local hexe = require("hexe")
return hexe.setup({
  keys = {
    hexe.key({ hexe.key.ctrl, hexe.key.t }, hexe.action.tab.new()),
  },
})
"""

env = os.environ.copy()
env.update({"XDG_STATE_HOME": os.path.join(SCRATCH, "smoke-state"),
            "TERM": "xterm-256color", "SHELL": "/bin/sh"})
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME"):
    env.pop(_k, None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
procs = []
instances = []


def pgrep(pat):
    r = subprocess.run(["pgrep", "-f", "--", pat], capture_output=True, text=True)
    return [int(x) for x in r.stdout.split()] if r.returncode == 0 else []


def kill_instance(inst):
    for pid in pgrep(f"daemon --instance {inst}"):
        try: os.kill(pid, signal.SIGKILL)
        except ProcessLookupError: pass


def cleanup():
    for p in procs:
        if p.poll() is None:
            p.terminate()
            try: p.wait(timeout=3)
            except subprocess.TimeoutExpired: p.kill()
    for inst in instances:
        kill_instance(inst)


atexit.register(cleanup)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))


def fail(msg):
    print(f"FAIL: {msg}"); cleanup(); sys.exit(1)


def tab_count(inst):
    """Panes the daemon records. Each `tab.new()` adds exactly one, and unlike
    a split it can never be refused for want of screen space — which is what
    made an earlier version of this test pass for the wrong reason."""
    path = os.path.join(SCRATCH, "smoke-state", "hexe", inst, "ses_state.json")
    try:
        return len(json.load(open(path)).get("panes", []))
    except (OSError, ValueError):
        return 0


def run_case(name, config, presses, pretype=None):
    """Boot a frontend with `config`, send ctrl+t `presses` times, return tabs."""
    inst = f"smk{os.getpid()}{name}"
    instances.append(inst)
    cfgdir = os.path.join(SCRATCH, f"cfg{os.getpid()}{name}")
    os.makedirs(os.path.join(cfgdir, "hexe"), exist_ok=True)
    open(os.path.join(cfgdir, "hexe", "init.lua"), "w").write(config)

    e = dict(env)
    e["HEXE_INSTANCE"] = inst
    e["XDG_CONFIG_HOME"] = cfgdir

    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    fe = subprocess.Popen([HEXE, "mux", "new", "-n", f"lua{name}"], stdin=slave, stdout=slave,
                          stderr=slave, env=e, cwd=SCRATCH, start_new_session=True)
    os.close(slave); procs.append(fe)
    time.sleep(3.0)
    if fe.poll() is not None:
        fail(f"[{name}] frontend exited rc={fe.returncode} — config did not load")

    deadline = time.time() + 10
    while time.time() < deadline and tab_count(inst) < 1:
        time.sleep(0.3)
    if tab_count(inst) != 1:
        fail(f"[{name}] expected 1 tab at startup, saw {tab_count(inst)}")

    # Poll for the effect rather than sleeping a fixed amount. `make smoke`
    # runs a Debug build alongside two dozen other frontends, and a fixed sleep
    # made this report "the action did not fire" when the machine was merely
    # busy.
    if pretype:
        os.write(master, pretype)
        time.sleep(2.0)

    for _ in range(presses):
        before_n = tab_count(inst)
        os.write(master, b"\x14")  # ctrl+t
        deadline = time.time() + 15
        while time.time() < deadline and tab_count(inst) == before_n:
            time.sleep(0.2)
        # A press that is SUPPOSED to be blocked never changes the count, so
        # give it a settle window before believing it.
        if tab_count(inst) == before_n:
            time.sleep(2.0)

    if fe.poll() is not None:
        fail(f"[{name}] frontend died while evaluating the binding")
    n = tab_count(inst)
    fe.terminate()
    try: fe.wait(timeout=3)
    except subprocess.TimeoutExpired: fe.kill()
    kill_instance(inst)
    return n


# Control first: prove the action itself can reach 3 tabs from this key.
# If it cannot, the conditional result below would be meaningless.
control = run_case("c", CONTROL, 2)
print(f"control:     no condition, 2x ctrl+t -> {control} tabs")
if control != 3:
    fail(f"control did not reach 3 tabs (got {control}); the observable is broken, "
         f"so nothing can be concluded about the predicate")

conditional = run_case("p", CONDITIONAL, 2)
print(f"conditional: when count<2,  2x ctrl+t -> {conditional} tabs")
if conditional == control:
    fail(f"the predicate changed nothing ({conditional} tabs either way) — "
         f"it is not being evaluated")
if conditional != 2:
    fail(f"expected the predicate to stop the second tab (2 tabs), got {conditional}")

print("phase: same key, same action; the only difference is a Lua predicate "
      "reading live state, and it decided the outcome")

n = run_case("n", NO_ALIASES, 1)
if n != 2:
    fail("the alias-absence predicate did not pass: either a pre-rewrite field "
         "name is still aliased, or a replacement field is missing")
print("aliases:     pre-rewrite pane field names are gone; replacements present")

# An action that is itself a Lua function, reading live state as it runs.
marker = os.path.join(SCRATCH, f"luaaction{os.getpid()}.txt")
if os.path.exists(marker):
    os.unlink(marker)
run_case("a", ACTION.replace("MARKER_PATH", marker), 1)
if not os.path.exists(marker):
    fail("a Lua function used as the action never ran")
written = open(marker).read()
print(f"action:      action = function(ctx) ... -> wrote {written!r}")
if "tabs=1" not in written:
    fail(f"the action ran but read the wrong live state: {written!r}")
# Content reads. Type into the pane first so there is text to find.
cmarker = os.path.join(SCRATCH, f"luacontent{os.getpid()}.txt")
if os.path.exists(cmarker):
    os.unlink(cmarker)
run_case("t", CONTENT.replace("MARKER_PATH", cmarker), 1, pretype=b"echo HEXEMARK\r")
if not os.path.exists(cmarker):
    fail("the content-read callback never ran")
c_out = open(cmarker).read()
for needle, why in [
    ("find=1", "ctx.find did not locate text that is on screen"),
    ("absent=nil", "ctx.find matched a string that is not on screen"),
    ("full_mark=true", "ctx.screen_text did not return the pane's text"),
    ("capped_mark=true", "a capped ctx.screen_text returned the wrong window "
                         "(it must anchor at the cursor, not at the last row)"),
    ("capped_len_ok=true", "ctx.screen_text ignored max_bytes"),
    ("pid_ok=true", "pane.pid is missing — the SES pane_info fields are dropped "
                    "on one of the two reader paths"),
    ("ses_state=attached", "pane.ses_state did not come through from SES"),
    ("age_ok=true", "pane.age_ms is missing (created_at not carried)"),
    ("pw=false", "pane.password_input is missing"),
]:
    if needle not in c_out:
        fail(f"{why}; got {c_out!r}")
print(f"content:     line/cursor_line/find/screen_text read real text -> {c_out[:70]!r}")

# The imperative half.
pmarker = os.path.join(SCRATCH, f"luaplugin{os.getpid()}.txt")
if os.path.exists(pmarker):
    os.unlink(pmarker)
tabs = run_case("g", PLUGIN.replace("MARKER_PATH", pmarker), 1)
if not os.path.exists(pmarker):
    fail("the plugin-style action never ran")
print(f"plugin:      ctx.act/notify/focus/send -> {open(pmarker).read()!r}, {tabs} tabs")
if tabs != 2:
    fail(f"ctx.act(hexe.action.tab.new()) did not create a tab (saw {tabs})")
plugin_out = open(pmarker).read()
for needle, why in [
    ("exec=true", "ctx.exec is not callable"),
    ("rc=true", "ctx.rename_tab failed — accessors go dead after a mutation "
                "that emits an event (live-state scope must restore, not clear)"),
    ("renamed-by-plugin", "ctx.tabs() did not observe the rename"),
]:
    if needle not in plugin_out:
        fail(f"{why}; got {plugin_out!r}")

emarker = os.path.join(SCRATCH, f"luaevents{os.getpid()}.txt")
if os.path.exists(emarker):
    os.unlink(emarker)
run_case("e", EVENTS.replace("MARKER_PATH", emarker), 1)
if not os.path.exists(emarker):
    fail("no event was ever delivered — hexe.events.on registered nothing")
ev_out = open(emarker).read()
if "created:" not in ev_out:
    fail(f"tab_created never fired; got {ev_out!r}")
if "changed:" not in ev_out:
    fail(f"tab_changed never fired — it is emitted on a path the tab binds "
         f"do not take; got {ev_out!r}")
print(f"events:      hexe.events.on delivered -> {ev_out!r}")

cleanup()
print("SMOKE PASS: conditions, actions and events are live Lua over real state")
