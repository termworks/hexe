-- hexe's client library: what another program requires to talk to a running session.
--
--   local hexe = load(src)(my_transport)
--   local mux  = hexe.connect()
--   for _, pane in ipairs(mux.panes()) do print(pane.name, pane.cwd) end
--
-- Three ways to get `src`, and a sandboxed host can only use the first two: the `client` verb on
-- an already-open connection, a sibling's own stub (the framing and reply shape are shared), or
-- `io.popen("hexe lua-api"):read("a")` where the host permits `io`.
--
-- Plain Lua on purpose. It runs unchanged in hexe's own VM, in oslo's, in PUC Lua and in whatever
-- the next sibling embeds, so it is *copied* between tools rather than ported — and a fix to the
-- framing reaches every one of them. It is a sibling of oslo's `client.lua` and deliberately the
-- same shape; read that one and this one holds no surprises.
--
-- The only thing it cannot do itself is open a socket. That arrives as the chunk's argument:
--
--   load(src)(transport)     transport.connect(path, timeout_ms) -> handle
--                            handle:send(bytes) / handle:recv(n) / handle:close()
--
-- Inside hexe that is `hexe.stream`, and it is found automatically when nothing is passed.
--
-- **The surface is small on purpose.** It is not a mirror of `hexe.live`; it is the handful of
-- things another program has a real reason to ask a mux, and every one answers a question the
-- asker cannot answer for itself — a pane list scraped from CLI output is a guess, this is not.
--
-- What a session will actually let you do is decided at the far end, per call, by the access the
-- caller was granted (see docs/access.md). This file describes the vocabulary; it does not grant
-- anything.

local transport = ...

-- Where the socket primitive comes from when the caller did not say. Inside hexe the whole library
-- is already there; elsewhere a host that named its own `__stream` is honoured too.
if not transport then
  transport = (_G.hexe and _G.hexe.stream) or _G.__stream
end

local M = { _NAME = "hexe", _VERSION = 1 }

-- ---------------------------------------------------------------- JSON, in Lua

-- Carried rather than required. The library runs inside somebody else's VM, so it cannot reach
-- hexe's own JSON — and a client that depended on the host having a JSON module would be a client
-- most hosts could not load.

local ESCAPES = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b',
  ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function quote(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return ESCAPES[c] or string.format('\\u%04x', c:byte())
  end) .. '"'
end

local encode

local function is_list(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n == #t
end

function encode(v, depth)
  depth = (depth or 0) + 1
  if depth > 24 then error("hexe: value nested too deeply to send", 0) end

  local kind = type(v)
  if v == nil then return "null" end
  if kind == "boolean" then return tostring(v) end
  if kind == "string" then return quote(v) end
  if kind == "number" then
    if v ~= v or v == math.huge or v == -math.huge then
      error("hexe: " .. tostring(v) .. " cannot be sent", 0)
    end
    return (math.type and math.type(v) == "integer") and string.format("%d", v) or tostring(v)
  end
  if kind ~= "table" then error("hexe: cannot send a " .. kind, 0) end

  local out = {}
  if is_list(v) then
    for i = 1, #v do out[#out + 1] = encode(v[i], depth) end
    return "[" .. table.concat(out, ",") .. "]"
  end
  for key, value in pairs(v) do
    if type(key) ~= "string" then error("hexe: only string keys can be sent", 0) end
    out[#out + 1] = quote(key) .. ":" .. encode(value, depth)
  end
  return "{" .. table.concat(out, ",") .. "}"
end

local function decode(s)
  local at = 1

  local function fail(why)
    error("hexe: bad reply at " .. at .. ": " .. why, 0)
  end

  local function skip()
    while true do
      local c = s:sub(at, at)
      if c == " " or c == "\t" or c == "\n" or c == "\r" then at = at + 1 else return end
    end
  end

  local function literal(word, value)
    if s:sub(at, at + #word - 1) == word then
      at = at + #word
      return value, true
    end
    return nil, false
  end

  local value

  local function str()
    at = at + 1
    local out = {}
    while true do
      local c = s:sub(at, at)
      if c == "" then fail("unterminated string") end
      if c == '"' then at = at + 1; return table.concat(out) end
      if c == "\\" then
        local e = s:sub(at + 1, at + 1)
        at = at + 2
        if e == "n" then out[#out + 1] = "\n"
        elseif e == "t" then out[#out + 1] = "\t"
        elseif e == "r" then out[#out + 1] = "\r"
        elseif e == "b" then out[#out + 1] = "\b"
        elseif e == "f" then out[#out + 1] = "\f"
        elseif e == "u" then
          local hex = s:sub(at, at + 3)
          at = at + 4
          local code = tonumber(hex, 16) or 0
          -- Enough for what this surface carries; a full UTF-16 pair decoder is not.
          out[#out + 1] = (code < 128) and string.char(code) or "?"
        else out[#out + 1] = e end
      else
        out[#out + 1] = c
        at = at + 1
      end
    end
  end

  function value()
    skip()
    local c = s:sub(at, at)
    if c == '"' then return str() end
    if c == "{" then
      at = at + 1
      local out = {}
      skip()
      if s:sub(at, at) == "}" then at = at + 1; return out end
      while true do
        skip()
        if s:sub(at, at) ~= '"' then fail("wanted a key") end
        local key = str()
        skip()
        if s:sub(at, at) ~= ":" then fail("wanted ':'") end
        at = at + 1
        out[key] = value()
        skip()
        local sep = s:sub(at, at)
        at = at + 1
        if sep == "}" then return out end
        if sep ~= "," then fail("wanted ',' or '}'") end
      end
    end
    if c == "[" then
      at = at + 1
      local out = {}
      skip()
      if s:sub(at, at) == "]" then at = at + 1; return out end
      while true do
        out[#out + 1] = value()
        skip()
        local sep = s:sub(at, at)
        at = at + 1
        if sep == "]" then return out end
        if sep ~= "," then fail("wanted ',' or ']'") end
      end
    end
    local got, found = literal("true", true)
    if found then return got end
    got, found = literal("false", false)
    if found then return got end
    got, found = literal("null", nil)
    if found then return got end

    local number = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", at)
    if number and #number > 0 then
      at = at + #number
      return tonumber(number) or fail("bad number")
    end
    fail("unexpected " .. (c == "" and "end of reply" or ("'" .. c .. "'")))
  end

  return value()
end

-- ---------------------------------------------------------------- the frame

-- Four bytes of big-endian length, then the body. Written by hand rather than with `string.pack`,
-- which Lua 5.1 and LuaJIT do not have and one of the siblings might be.
local function frame(body)
  local n = #body
  return string.char(
    math.floor(n / 16777216) % 256,
    math.floor(n / 65536) % 256,
    math.floor(n / 256) % 256,
    n % 256
  ) .. body
end

local function be32(s)
  return s:byte(1) * 16777216 + s:byte(2) * 65536 + s:byte(3) * 256 + s:byte(4)
end

--- Read exactly `n` bytes, however many reads that takes.
---
--- **A stream delivers what it likes.** One `recv` answering fewer bytes than asked for is
--- ordinary, not an error, and a client that treated it as the whole message would desynchronise
--- on the first reply large enough to be split.
local function exactly(handle, n)
  local parts, have = {}, 0
  while have < n do
    local chunk, why = handle:recv(n - have)
    if not chunk then return nil, why end
    if #chunk == 0 then return nil, "the session closed the connection" end
    parts[#parts + 1] = chunk
    have = have + #chunk
  end
  return table.concat(parts)
end

-- ---------------------------------------------------------------- the session

local Session = {}
Session.__index = Session

--- Send one call and wait for its answer.
---
--- hexe serves one request per connection, so this reconnects each time. That is the server's
--- contract, not an accident: a control socket that held connections open would need a slot per
--- idle caller, and it has eight.
function Session:call(name, ...)
  local args = { ... }
  local body = { call = name }
  if #args > 0 then body.args = args end

  local handle, why = transport.connect(self.path, self.timeout_ms)
  if not handle then return nil, why end

  local sent, gone = handle:send(frame(encode(body)))
  if not sent then handle:close(); return nil, gone end

  local head, cut = exactly(handle, 4)
  if not head then handle:close(); return nil, cut end
  local reply_body, trimmed = exactly(handle, be32(head))
  handle:close()
  if not reply_body then return nil, trimmed end

  local reply = decode(reply_body)
  if not reply.ok then return nil, reply.error or "the session refused the call" end
  -- `result` is a list of return values and `n` says how many, so one Lua call
  -- answers with what the remote one did. The same shape oslo's server uses:
  -- a client that unpacked hexe's old single value lost every record, string
  -- and number it was handed.
  local values = reply.result or {}
  return table.unpack(values, 1, reply.n or #values)
end

function Session:close()
  return true
end

-- The exposed surface, spelled out.
--
-- Written as a table rather than discovered at runtime so that reading this file tells you what a
-- peer can ask of your session. A surface you have to run something to learn is one nobody audits.
--
-- Chosen by asking what a sibling genuinely needs, not by listing what exists: the layout and the
-- pane list, because scraping them is a guess; typing and key presses, because only the mux can
-- deliver them; and the three ways to say something to the user. `act`, `close`, `geometry` and
-- the rest of the local API are reachable through `call` for anyone who means it, and are left out
-- of the vocabulary because a sibling reshaping your window layout is rarely what either of you
-- wanted.
local SURFACE = {
  "panes", "pane", "tabs", "session", "ui", "count",
  "screen_text", "line",
  "send", "keys",
  "notify", "popup", "capture",
  "focus",
}

local function attach(session)
  for _, verb in ipairs(SURFACE) do
    session[verb] = function(...) return session:call(verb, ...) end
  end
  return session
end

-- ---------------------------------------------------------------- connecting

--- Where a session's socket is, given what little the caller said.
---
--- `$HEXE_API_SOCKET` first, because a program hexe started inherits it and means *that* session —
--- a plugin never has to guess. A session name picks one exactly. With neither, the newest socket
--- wins, which is right for the common case of one session and honest about being a guess when
--- there are several.
---
--- Answers a *list* of candidates, newest first, because a socket file is not a running session:
--- one left behind by a frontend that was killed looks exactly like a live one until something
--- connects. Trying them in turn is the only staleness check that cannot be raced.
--- Every `api@*.sock` under `dir`, newest first. Empty when nothing can list it.
---
--- Plain Lua cannot list a directory, so this asks the host two ways and gives up rather than
--- guessing.
---
--- **`io.popen` is the fallback, not the first choice.** It shells out, and a sandboxed host may
--- refuse it outright, so a host that can list a directory itself is asked first and the shell-out
--- is wrapped where it might not exist at all.
---
--- Whichever sibling we are running inside: this file is meant to be copied between them, so it
--- looks for any of the family's globals rather than only its own. Inside oslo `_G.hexe` does not
--- exist, and checking only for that sent discovery straight to the `io.popen` oslo refuses —
--- which looked exactly like "no session is running".
local function list_candidates(dir)
  local host
  for _, name in ipairs({ "hexe", "oslo" }) do
    local candidate = _G[name]
    if candidate and candidate.fs and candidate.fs.ls then host = candidate; break end
  end

  if host then
    local found = {}
    for _, entry in ipairs(host.fs.ls(dir) or {}) do
      if entry.name:sub(1, 4) == "api@" and entry.name:sub(-5) == ".sock" then
        found[#found + 1] = { path = dir .. "/" .. entry.name, when = entry.mtime or 0 }
      end
    end
    table.sort(found, function(a, b) return a.when > b.when end)
    return found
  end

  local ok, found = pcall(function()
    local ls = io.popen("ls -t '" .. dir .. "'/api@*.sock 2>/dev/null")
    if not ls then return nil end
    local out = {}
    for line in ls:lines() do out[#out + 1] = { path = line } end
    ls:close()
    return out
  end)
  return (ok and found) or {}
end

--- The directory hexe binds its control sockets in.
---
--- Mirrors hexe's own `getSocketDir`: the default profile binds straight under `<runtime>/hexe`,
--- and only a NAMED instance gets a subdirectory. Appending "default" unconditionally looked
--- reasonable and found nothing at all.
local function socket_dir()
  local runtime = os.getenv("XDG_RUNTIME_DIR")
  local base = (runtime and runtime ~= "")
    and (runtime .. "/hexe")
    or ("/tmp/hexe-" .. (os.getenv("UID") or "0"))
  local instance = os.getenv("HEXE_INSTANCE")
  return (instance and instance ~= "") and (base .. "/" .. instance) or base
end

--- Where a session's socket is, given what little the caller said.
---
--- `$HEXE_API_SOCKET` first, because a program hexe started inherits it and means *that* session —
--- a plugin never has to guess. A name picks one. With neither, the newest socket wins, which is
--- right for the common case of one session and honest about being a guess when there are several.
---
--- Answers a *list*, newest first, because a socket file is not a running session: one left behind
--- by a frontend that was killed looks exactly like a live one until something connects. Trying
--- them in turn is the only staleness check that cannot be raced.
---
--- A name is tried as the file first, then against what each session CALLS itself. Those differ
--- more often than you would think: the file is named when the socket binds, and a session renamed
--- or reattached afterwards keeps the old file — so the name a caller read from `session().name`
--- may name no file at all.
local function find(where)
  if type(where) == "table" and where.path then return { { path = where.path } } end
  local named = type(where) == "string" and where or nil

  local env = os.getenv("HEXE_API_SOCKET")
  if not named and env and env ~= "" then return { { path = env } } end

  local dir = socket_dir()
  if not named then return list_candidates(dir) end

  local direct = dir .. "/api@" .. named .. ".sock"
  local out = { { path = direct } }
  for _, candidate in ipairs(list_candidates(dir)) do
    if candidate.path ~= direct then
      out[#out + 1] = { path = candidate.path, must_be_named = named }
    end
  end
  return out
end

--- Open a connection to a running hexe.
---
--- `where` is nothing (find it), a session name, or `{ path = "…", timeout_ms = 5000 }`.
function M.connect(where)
  if not transport then
    return nil, "no transport: pass one to the chunk, as load(src)(hexe.stream)"
  end
  local candidates = find(where)
  if not candidates or #candidates == 0 then
    return nil, "no hexe socket found — is a session attached?"
  end

  local timeout = type(where) == "table" and where.timeout_ms or nil

  -- Refuse our own session, when the host told us which that is.
  --
  -- A call to yourself from inside your own event loop cannot be answered: the
  -- frontend is busy running the caller. It looks like a hang and ends in a
  -- socket timeout, which says nothing about the cause. Inside hexe, `ctx.*`
  -- already reaches everything this library does, without a socket.
  local self_socket = _G.hexe and _G.hexe.__self_socket
  local last
  for _, candidate in ipairs(candidates) do
    if self_socket and candidate.path == self_socket then
      return nil, "that is this session; use ctx.* in here rather than connecting to yourself"
    end
    local handle, why = transport.connect(candidate.path, timeout)
    if handle then
      handle:close()
      local session = attach(setmetatable({ path = candidate.path, timeout_ms = timeout }, Session))
      -- A candidate reached by scanning has to prove it is the one asked for.
      -- Asking it its own name is the only way: the file name is a snapshot
      -- from when it bound, and this is what it answers to now.
      if candidate.must_be_named then
        local live = session.session()
        if not (live and live.name == candidate.must_be_named) then
          last = "no session answers to '" .. candidate.must_be_named .. "'"
          goto continue
        end
      end
      return session
    end
    last = why
    ::continue::
  end
  return nil, last or "nothing was listening"
end

--- The socket path that would be tried first, without connecting. For a diagnostic.
function M.where(name)
  local candidates = find(name)
  return candidates and candidates[1] and candidates[1].path
end

--- Every candidate, newest first, for a caller that wants to choose.
function M.sockets(name)
  local out = {}
  for _, candidate in ipairs(find(name) or {}) do out[#out + 1] = candidate.path end
  return out
end

return M
