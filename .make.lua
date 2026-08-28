-- hexe's build, as recipes. This file replaced the Makefile; there is no other.
--
--   make                 the recipes, with what each of them says it does
--   make build           the static release binary
--   make install         that binary, everywhere hexe is on $PATH
--   make smoke           the live end-to-end suite
--
-- At an oslo prompt in this directory `make` is the builtin and reads this file. Anywhere else,
-- `oslo make <recipe>` does the same thing, and the two commands a checkout needs without oslo at
-- all are `scripts/vendor-*.sh` and `zig build` — which is exactly what CI runs, so nothing
-- here is on the release path.
--
-- The parts worth reading are the ones the Makefile could not say plainly: the smoke runner is a
-- loop with a tally instead of a `define` full of `$$` and backslashes, and `install` covers every
-- copy of hexe rather than one.

local make = oslo.make

---------------------------------------------------------------------------- what the build is

-- Static musl by default. Zig links its bundled musl STATICALLY for any *-linux-musl target, so
-- this needs no extra linkage flag — the result has no dynamic loader and no glibc dependency.
--
-- CPU stays at the target default (baseline) rather than `native`: a static binary exists to be
-- portable, and the SIMD-heavy VT paths dispatch on the CPU at runtime anyway.
-- What this checkout calls itself, from the one file that declares it.
local VERSION = (function()
  local f = io.open("build.zig.zon", "r")
  if not f then return "?" end
  local text = f:read("a") or ""
  f:close()
  return text:match('%.version%s*=%s*"([^"]+)"') or "?"
end)()

local NAME = "hexe"
local TARGET = os.getenv("TARGET") or "x86_64-linux-musl"
local PREFIX = os.getenv("PREFIX") or "/usr"
local BIN = "zig-out/bin/hexe"

-- Where the vendored, patched ghostty lands. The revision and the fetch live in
-- scripts/vendor-*.sh, which CI runs too -- CI has no oslo, so a pin kept
-- here as well would be a second copy that goes stale without anyone noticing.
local GHOSTTY_DIR = "vendor/ghostty"

---------------------------------------------------------------------------- helpers

local function dim(text)
  return oslo.ui.style(text, { dim = true })
end

-- `7188680` -> `7,188,680`. A number this long is read in groups or not at all.
local function grouped(n)
  local text = tostring(math.floor(n))
  local out = text:sub(-3)
  local at = #text - 3
  while at > 0 do
    out = text:sub(math.max(1, at - 2), at) .. "," .. out
    at = at - 3
  end
  return out
end

local function line(label, value)
  print(dim(oslo.ui.pad(label, 8)) .. value)
end

-- Every `hexe` $PATH would find, in the order it would find them.
--
-- Which one answers decides which binary starts the daemon, so a half-finished install is not a
-- tidiness problem: the old copy wins and the new frontend cannot talk to what it started.
local function hexe_on_path()
  local found, seen = {}, {}
  for entry in ((os.getenv("PATH") or "") .. ":"):gmatch("([^:]*):") do
    if entry ~= "" then
      local path = entry .. "/hexe"
      if oslo.fs.stat(path) then
        -- Resolved, because /bin is a symlink to usr/bin on most systems and
        -- reporting one file under two names reads as two problems.
        local real = oslo.run{ "readlink", "-f", path, capture = true }
        local key = real.ok and (real.out or ""):match("^%s*(.-)%s*$") or path
        if not seen[key] then
          seen[key] = true
          found[#found + 1] = path
        end
      end
    end
  end
  return found
end

-- Whether the running daemon will actually talk to this build.
--
-- `session status` is not the question: it reports the socket as "running" whenever it can be
-- connected to, and says nothing about the handshake -- so it answers "reachable" for exactly the
-- daemon this is meant to catch. `session list` performs the handshake, so it is what gets asked.
local function daemon_state()
  local r = oslo.run{ BIN, "session", "list", capture = true }
  local said = (r.out or "") .. (r.err or "")
  if said:find("RuntimeEpochMismatch") then return "mismatch" end
  if said:find("Instance:") then return "ok" end
  return "absent"
end

local function sha256(path)
  local r = oslo.run{ "sha256sum", path, capture = true }
  if not r.ok then return nil end
  return (r.out or ""):match("^(%x+)")
end

-- Install one copy, asking for root only when the destination needs it.
local function install_to(dest)
  local dir = oslo.path.parent(dest)
  if oslo.run{ "test", "-w", dir }.ok or oslo.run{ "test", "-w", dest }.ok then
    sh.install("-Dm755", BIN, dest)
  else
    print("installing " .. dest .. dim("  (needs root)"))
    sh.sudo("install", "-Dm755", BIN, dest)
  end
  print("installed " .. dest)
end

-- Where the binary is, what it weighs, and which hexe you actually get.
--
-- The last row is the one that earns its place here. hexe is usually installed in more than one
-- place, and a daemon belongs to whichever copy $PATH answered with -- so a build that succeeded
-- and a $PATH that reaches an older copy look identical until the new frontend refuses to talk to
-- the daemon the old one started.
local function report()
  local stat = oslo.fs.stat(BIN)
  if not stat then return end
  local megabytes = ("%.2f MB"):format(stat.size / 1048576)

  print("")
  print(oslo.ui.title(("%s %s   %s"):format(NAME, VERSION, megabytes)))
  line("binary", BIN)
  -- Bytes beside megabytes: `6.86 MB` cannot be subtracted from last week's `6.83 MB` to get one.
  line("size", megabytes .. dim("   " .. grouped(stat.size) .. " bytes"))

  local mine = sha256(BIN)
  local answers = hexe_on_path()[1]
  if not answers then
    line("path", oslo.ui.style("✗ no hexe on $PATH", { fg = "yellow" }))
  elseif sha256(answers) == mine then
    line("path", oslo.ui.style("✓ this build", { fg = "green" }) .. dim("  " .. answers))
  else
    line("path", oslo.ui.style("✗ an older build answers", { fg = "yellow" }) .. dim("  " .. answers))
    print(oslo.ui.subtitle("         make install   to put this build there"))
  end

  -- A daemon outlives the binary that started it, and it is the half people forget.
  local daemon = daemon_state()
  if daemon == "mismatch" then
    line("daemon", oslo.ui.style("✗ from another build", { fg = "yellow" }))
    print(oslo.ui.subtitle("         hexe session kill   panes survive and are re-adopted"))
  elseif daemon == "ok" then
    line("daemon", oslo.ui.style("✓ talks to this build", { fg = "green" }))
  end
  print("")
end

-- The processes a smoke run owns, and nothing else.
--
-- A blanket `pkill -f zig-out/bin/hexe` killed the developer's OWN running hexe too, since a dev
-- runs the same binary from this tree — `make smoke` silently destroyed live sessions. Every smoke
-- tags its processes with HEXE_INSTANCE=smk<pid>, so that is what is matched, on a whole entry
-- rather than a substring.
local function smoke_pids()
  local r = oslo.run{ "pgrep", "-f", "[z]ig-out/bin/hexe", capture = true }
  local pids = {}
  for pid in (r.out or ""):gmatch("%d+") do
    local f = io.open("/proc/" .. pid .. "/environ", "rb")
    if f then
      local blob = f:read("a") or ""
      f:close()
      for entry in (blob .. "\0"):gmatch("([^%z]*)%z") do
        if entry:match("^HEXE_INSTANCE=smk%d*$") then
          pids[#pids + 1] = pid
          break
        end
      end
    end
  end
  return pids
end

-- One smoke per line, all of them, then the tally.
--
-- One recipe line per smoke made `make` stop at the first failure, so a single flake hid every test
-- after it: a 25-minute run reported one result and left ~20 unknown. This runs the list to
-- completion and lets the tally decide the exit status. SMOKE_FAILFAST=1 stops at the first
-- failure instead, for bisecting.
local function run_smokes(list)
  local passed, failures = 0, {}
  for _, script in ipairs(list) do
    print("")
    print("=== " .. script)
    if oslo.run{ "python3", "-u", "scripts/" .. script }.ok then
      passed = passed + 1
    else
      failures[#failures + 1] = script
      assert(not os.getenv("SMOKE_FAILFAST"), "SMOKE FAILFAST after " .. script)
    end
  end
  print("")
  print(("%d passed, %d failed"):format(passed, #failures))
  assert(#failures == 0, "FAILED: " .. table.concat(failures, " "))
end

---------------------------------------------------------------------------- vendor

make.recipe{
  name = "vendor",
  desc = "fetch the pinned dependencies and apply hexe's patches",
  run = function() sh.bash("scripts/vendor-ghostty.sh"); sh.bash("scripts/vendor-yazap.sh") end,
}

-- Fail with an instruction rather than a compile error a reader cannot place.
--
-- The .git check is not cosmetic. ghostty's build derives its version from git, and the vendor
-- directory lives inside this repo — without a repo of its own, git walks up and finds OUR tags.
-- That is fine until this repo is tagged, and then ghostty's build panics with "tagged releases
-- must be in vX.Y.Z format", forty lines deep in a build runner and nowhere near the cause.
make.recipe{
  name = "vendor-check",
  desc = "fail early if a vendored dependency is missing or has no .git",
  quiet = true,
  run = function()
    assert(oslo.fs.stat(GHOSTTY_DIR .. "/src/terminal/style.zig"),
           GHOSTTY_DIR .. " is missing. Run: make vendor")
    assert(oslo.fs.stat(GHOSTTY_DIR .. "/.git"),
           GHOSTTY_DIR .. " has no .git, so ghostty's build will read THIS repo's tags and " ..
           "panic. Run: make vendor")
    -- yazap is vendored for its examplesStep patch; without the directory there
    -- is simply no dependency to resolve.
    assert(oslo.fs.stat("vendor/yazap/build.zig"),
           "vendor/yazap is missing. Run: make vendor")
  end,
}

---------------------------------------------------------------------------- building

make.recipe{
  name = "build",
  desc = "the static release binary",
  deps = { "vendor-check" },
  run = function()
    sh.zig("build", "-Doptimize=ReleaseFast", "-Dstrip=true", "-Dtarget=" .. TARGET)
    report()
  end,
}

make.alias("b", "build")

-- Escape hatch: link against the host's glibc instead.
make.recipe{
  name = "build-gnu",
  desc = "release binary against the host glibc",
  deps = { "vendor-check" },
  run = function() sh.zig("build", "-Doptimize=ReleaseFast", "-Dstrip=true") end,
}

make.recipe{
  name = "test",
  desc = "the Zig unit tests",
  run = function() sh.zig("build", "test", "-Doptimize=ReleaseFast") end,
}

make.alias("t", "test")

---------------------------------------------------------------------------- installing

make.recipe{
  name = "install",
  desc = "install this build everywhere hexe is on $PATH, and config/ where it reads it",
  deps = { "build" },
  run = function()
    -- Both, always. A daemon is started by whichever copy $PATH found first, so updating one and
    -- not the other leaves an old daemon that the new frontend refuses to talk to — which reads as
    -- "hexe is broken" rather than as an install that did not finish.
    install_to(os.getenv("HOME") .. "/.local/bin/hexe")
    install_to(PREFIX .. "/bin/hexe")
    make.run("install-check")
    -- Last, and part of the install rather than a step to remember: a binary newer than the config
    -- it reads is how a setting that shipped together with it silently does nothing. Run alone,
    -- `configs` still installs only the config.
    make.run("configs")
  end,
}

make.recipe{
  name = "install-check",
  desc = "report any hexe on $PATH, or any daemon, still from an older build",
  run = function()
    local want = sha256(BIN)
    local stale = {}
    for _, path in ipairs(hexe_on_path()) do
      if sha256(path) ~= want then stale[#stale + 1] = path end
    end
    if #stale > 0 then
      print(oslo.ui.style("warning: still an older build: " .. table.concat(stale, " "),
                          { fg = "yellow" }))
    else
      print("every hexe on $PATH is this build")
    end

    if daemon_state() == "mismatch" then
      print(oslo.ui.style("the running daemon is from an older build", { fg = "yellow" }))
      print(dim("  panes survive a restart and are re-adopted:  hexe session kill"))
    end
  end,
}

make.recipe{
  name = "uninstall",
  desc = "remove the installed copies",
  run = function()
    for _, dest in ipairs({ os.getenv("HOME") .. "/.local/bin/hexe", PREFIX .. "/bin/hexe" }) do
      if oslo.fs.stat(dest) then
        if oslo.run{ "test", "-w", dest }.ok then sh.rm("-f", dest) else sh.sudo("rm", "-f", dest) end
        print("removed " .. dest)
      end
    end
  end,
}

---------------------------------------------------------------------------- the smokes

-- Live end-to-end smokes: a real frontend under a pty, isolated by HEXE_INSTANCE.
local SMOKES = {
  "smoke_reconnect.py", "smoke_detach_reattach.py", "smoke_fullscreen_reattach.py",
  "smoke_paste.py", "smoke_input_batch.py", "smoke_terminal_protocol.py",
  "smoke_kill.py", "smoke_pane_info.py", "smoke_lua_api.py",
  "smoke_config_reload.py", "smoke_recording.py", "smoke_cli_waiter_release.py",
  "smoke_stalled_peer.py", "smoke_stalled_pod_peer.py", "smoke_rate_limit_attach.py",
  "smoke_log_not_in_tmp.py", "smoke_pod_attach.py", "smoke_wedged_ctl_reader.py",
  "smoke_bighistory.py", "smoke_dot_attach.py", "smoke_attach_stress.py",
  "smoke_attach_chaos.py", "smoke_slow_exec.py", "smoke_region_painter.py",
  "smoke_startup_chooser.py", "smoke_bad_config.py", "smoke_session_env.py",
  "smoke_float_concurrent.py", "smoke_pod_record_input.py", "smoke_exit_intent_concurrent.py",
  "smoke_float_destroy.py", "smoke_keypad.py", "smoke_painter_showcase.py",
  "smoke_profiles.py", "smoke_palette.py", "smoke_palette_persist.py",
  "smoke_palette_fuzz.py", "smoke_palette_cells.py", "smoke_names.py",
  "smoke_decor.py", "smoke_float_state.py", "smoke_float_per_git.py", "smoke_float_navigatable.py", "smoke_painter_exec.py", "smoke_api_socket.py",
  "smoke_api_events.py", "smoke_stale_daemon.py", "smoke_api_geometry.py",
  "smoke_inherit_env.py", "smoke_access.py", "smoke_capture.py", "smoke_lua_client.py", "smoke_pane_socket.py", "smoke_plugin_pkg.py", "smoke_popup.py", "smoke_plugin_stream.py", "smoke_share_indicator.py", "smoke_stream_attach.py", "smoke_status_zones.py",
}

-- Heavy-load scenario: splits + floats + fullscreen apps + huge buffers + pastes, then chaos
-- rounds. Needs a ReleaseFast build (Debug VT parsing is ~50x slower and cannot keep up with a
-- 5-pod session).
local HEAVY_SMOKES = {
  "smoke_heavy.py", "smoke_heavy2.py", "smoke_multi_bighistory.py",
  "smoke_input_flood.py", "smoke_wedged.py", "smoke_input_exactly_once.py",
  "smoke_float.py", "smoke_float_session.py", "smoke_float_content.py",
  "smoke_float_tui.py", "smoke_input_after_float.py", "smoke_float_toggle.py",
}

-- Kill anything the suite leaked and clear its scratch state.
--
-- Leaked processes slow everything down until later smokes fail in ways that look exactly like
-- product bugs. Measured directly: smoke_heavy2 failed 2/2 on untouched develop with 39 leaked
-- processes present, and passed once they were cleared, with no code change in between.
make.recipe{
  name = "smoke-clean",
  desc = "kill leaked smoke processes and clear their scratch state",
  run = function()
    local pids = smoke_pids()
    for _, pid in ipairs(pids) do oslo.run{ "kill", "-9", pid } end
    oslo.run{ "rm", "-rf", os.getenv("HEXE_SMOKE_TMP") or "/tmp/hexe-smoke" }
    local runtime = os.getenv("XDG_RUNTIME_DIR") or "/tmp"
    for _, dir in ipairs(oslo.fs.glob(runtime .. "/hexe/smk*")) do
      oslo.run{ "rm", "-rf", dir }
    end
    if #pids > 0 then print(("cleared %d leaked smoke process(es)"):format(#pids)) end
  end,
}

make.recipe{
  name = "smoke",
  desc = "the live end-to-end suite",
  deps = { "smoke-clean" },
  run = function()
    sh.zig("build")
    run_smokes(SMOKES)
  end,
}

make.recipe{
  name = "smoke-protocol",
  desc = "the terminal protocol smoke alone",
  run = function()
    sh.zig("build")
    run_smokes({ "smoke_terminal_protocol.py" })
  end,
}

make.recipe{
  name = "smoke-heavy",
  desc = "the heavy-load suite (needs a release build)",
  deps = { "smoke-clean" },
  run = function()
    sh.zig("build", "-Doptimize=ReleaseFast")
    run_smokes(HEAVY_SMOKES)
  end,
}

-- One smoke by name, without editing the list: `make smoke-one --name smoke_decor.py`
make.recipe{
  name = "smoke-one",
  desc = "one smoke by name",
  params = { { "--name", desc = "script under scripts/" } },
  run = function(a)
    assert(type(a.name) == "string", "which one? make smoke-one --name smoke_decor.py")
    sh.zig("build")
    run_smokes({ (a.name:match("%.py$") and a.name) or (a.name .. ".py") })
  end,
}

---------------------------------------------------------------------------- feature demos

-- One recording per document in docs/. Each is a script in scripts/demo, driven into a real
-- frontend by record.py, so any of them can be made again after the code changes — and a film that
-- stops matching hexe is a bug in one or the other.
--
-- Needs a ReleaseFast build: Debug VT parsing cannot keep up with a session being typed at.

make.recipe{
  name = "demo-fixture",
  desc = "stage the config a recording is shot with",
  run = function() sh.bash("scripts/demo/fixture.sh") end,
}

-- Kill anything a demo left behind. A frontend whose recorder died does NOT exit when its pty
-- closes — it spins at 100% of a core — so this is not tidiness, it is the difference between a
-- usable machine and a hot one.
make.recipe{
  name = "demo-clean",
  desc = "kill anything a recording left running",
  run = function()
    -- Bracketed so the pattern cannot match this process itself.
    oslo.run{ "pkill", "-9", "-f", "[i]nstance dem" }
    oslo.run{ "pkill", "-9", "-f", "[h]exe-demo-work" }
  end,
}

make.recipe{
  name = "demo-record",
  desc = "record the films (--name one of them)",
  deps = { "build", "demo-fixture", "demo-clean" },
  params = { { "--name", desc = "one demo, without .demo" } },
  run = function(a)
    -- `nice`, because a recording is seventeen hexe stacks in a row and the author is using the
    -- machine while it runs — their shell prompt has a 10ms budget.
    local function record(path)
      sh.nice("-n", "10", "python3", "-u", "scripts/demo/record.py", path)
    end
    if type(a.name) == "string" then
      record("scripts/demo/" .. a.name .. ".demo")
    else
      for _, path in ipairs(oslo.fs.glob("scripts/demo/*.demo")) do record(path) end
    end
    make.run("demo-clean")
  end,
}

make.recipe{
  name = "demo-publish",
  desc = "upload the films",
  params = { { "--name", desc = "one demo, without .demo" } },
  run = function(a) sh.bash("scripts/demo/publish.sh", a.name or "") end,
}

make.recipe{
  name = "demo-embed",
  desc = "put the links back into docs/",
  run = function() sh.bash("scripts/demo/embed.sh") end,
}

make.recipe{ name = "demos", desc = "record, publish and embed",
             deps = { "demo-record", "demo-publish", "demo-embed" } }

---------------------------------------------------------------------------- configuration

-- hexe's own configuration lives in `config/`, and this installs it: `config/*` becomes
-- `~/.config/hexe/*`. The frontend reads `init.lua` from there at startup, so this is how a
-- checkout's configuration becomes the one a running mux uses.
make.recipe{
  name = "configs",
  desc = "install config/ into $XDG_CONFIG_HOME/hexe",
  params = { { "--dest", desc = "somewhere other than the config directory" } },
  run = function(a)
    assert(oslo.run{ "sh", "-c", "command -v rsync", capture = true }.ok,
           "rsync is not installed; install it first")
    -- Asked of git rather than assumed from the working directory, so this works from anywhere in
    -- the tree. Outside a repository, where the command was run is the best answer available.
    local top = oslo.run{ "git", "rev-parse", "--show-toplevel", capture = true }
    local root = top.ok and (top.out or ""):match("^%s*(.-)%s*$") or ""
    if root == "" then root = oslo.sys.pwd() end
    local source = root .. "/config"
    assert(oslo.fs.stat(source .. "/"), "there is no config/ directory in " .. root)

    local dest = a.dest
    if not dest then
      local config = os.getenv("XDG_CONFIG_HOME")
      if not config or config == "" then config = os.getenv("HOME") .. "/.config" end
      dest = config .. "/" .. NAME
    end
    sh.mkdir("-p", dest)

    -- One entry at a time, each mirrored with --delete, rather than one --delete over the whole
    -- tree: the destination is where anything else you keep beside init.lua lives, and a tree-wide
    -- mirror would take it with it.
    -- **Plugins do not live with the config.** hexe reads them from the data directory, so
    -- syncing `config/plugins` into `~/.config/hexe` would put them somewhere nothing looks. They
    -- go to their own destination below, and are skipped here.
    local synced = 0
    for _, path in ipairs(oslo.fs.glob(source .. "/*")) do
      local name = oslo.path.name(path)
      if name == "plugins" then
        goto continue
      elseif oslo.fs.stat(path .. "/") then
        sh.mkdir("-p", dest .. "/" .. name)
        sh.rsync("-a", "--delete", path .. "/", dest .. "/" .. name .. "/")
      else
        sh.rsync("-a", path, dest .. "/" .. name)
      end
      synced = synced + 1
      ::continue::
    end
    print(oslo.ui.style("✓ ", { fg = "green" }) ..
          ("%d entr%s -> %s"):format(synced, synced == 1 and "y" or "ies", dest))

    -- The plugins hexe ships, into the directory hexe reads them from.
    --
    -- **Installed is not approved**, and deliberately: nothing here has run, and `hexe plugin
    -- allow <name>` is the separate step that lets it. Copying a plugin in and enabling it in one
    -- move would make "see what it asks for before running any of it" impossible.
    local plugin_src = source .. "/plugins"
    if oslo.fs.stat(plugin_src .. "/") then
      -- `--dest` redirects everything, plugins included: a run pointed somewhere else must not
      -- reach into the real plugin directory.
      local plugin_dest
      if a.dest then
        plugin_dest = a.dest .. "/plugins"
      else
        local data = os.getenv("XDG_DATA_HOME")
        if not data or data == "" then data = os.getenv("HOME") .. "/.local/share" end
        plugin_dest = data .. "/" .. NAME .. "/plugins"
      end
      sh.mkdir("-p", plugin_dest)
      local names = {}
      for _, path in ipairs(oslo.fs.glob(plugin_src .. "/*")) do
        local name = oslo.path.name(path)
        sh.mkdir("-p", plugin_dest .. "/" .. name)
        sh.rsync("-a", "--delete", path .. "/", plugin_dest .. "/" .. name .. "/")
        names[#names + 1] = name
      end
      if #names > 0 then
        print(oslo.ui.style("✓ ", { fg = "green" }) ..
              ("%d plugin%s -> %s"):format(#names, #names == 1 and "" or "s", plugin_dest))
        print(oslo.ui.subtitle("  not approved yet:  hexe plugin allow " .. table.concat(names, " ")))
      end
    end

    -- Installed, then checked. hexe can read its own config back, so a file that will not load is
    -- worth knowing about now rather than the next time a mux starts and degrades to defaults.
    -- `validate` reads whatever `$XDG_CONFIG_HOME` points at and takes no path, so the variable is
    -- set for the child by a shell rather than passed as an option: `oslo.run` has no `env` key and
    -- ignores one silently, which validated the developer's own config and called it a pass.
    if oslo.fs.stat(BIN) then
      local home = dest:gsub("/" .. NAME .. "$", "")
      local r = oslo.run{ "sh", "-c",
        ("XDG_CONFIG_HOME=%q %q config validate 2>&1"):format(home, BIN), capture = true }
      if r.ok then
        print(oslo.ui.style("✓ ", { fg = "green" }) .. "it loads")
      else
        print(oslo.ui.style("✗ ", { fg = "yellow" }) .. "installed, but it does not load:")
        print(dim("  " .. ((r.out or ""):match("[^\n]*") or "")))
      end
    end
    print(oslo.ui.subtitle("  anything else in that directory is left alone"))
  end,
}

---------------------------------------------------------------------------- releasing

make.recipe{
  name = "release",
  desc = "cut a version: --type patch | minor | major | M.m.p",
  params = { { "--type", desc = "patch | minor | major | M.m.p", default = "patch" } },
  run = function(a)
    assert(oslo.run{ "sh", "-c", "command -v git-rel" }.ok,
           "git-rel is not installed. Please install it first.")
    sh.git("rel", a.type)
  end,
}
