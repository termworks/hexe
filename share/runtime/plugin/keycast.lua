-- Show the keys you are pressing.
--
-- This used to live in hexe: an overlay type, a widget config, a toggle action,
-- a ring buffer in the frontend and a renderer, spread over ten files. None of
-- it was terminal-multiplexer work. hexe knows which keys were pressed and
-- which of them are safe to show; drawing a list of them in a corner is
-- something anything can do, given that.
--
-- So hexe reports `key_pressed` and this draws, with its own chord to turn it
-- on and off.
--
-- **It draws itself**, rather than naming a view for a painter to render: what
-- it needs is a background, a foreground and some text, and that is three
-- escape codes. Change them below. Needing a painter configured before hexe
-- could show you a keystroke was the wrong trade.
--
-- Shipped in hexe's own runtime root, on the same runtimepath your config is
-- on and by the same rules -- so `after/plugin/keycast.lua` in your own config
-- directory overrides anything here, and `--noplugin` turns it off with
-- everything else.

-- The chord that turns it on and off. `act_and_consume` so the toggle itself
-- does not also reach the pane underneath.
local TOGGLE = { hexe.key.ctrl, hexe.key.alt, hexe.key.k }

local KEEP = 8            -- chords kept on screen
local LINGER_MS = 2500    -- how long after the last key the panel stays
local WIDTH = 34
local CORNER = "bottomright"

local FG = 15             -- 256-colour foreground
local BG = 237            -- 256-colour background
local BOLD = true

local ESC = string.char(27)

-- Off until asked for. A plugin that starts drawing the moment it is allowed
-- gives you no way to look at it first.
local on = false
local recent = {}

-- Padded to the full width so the panel is a solid block rather than a ragged
-- one that changes shape with every key.
local function panel(text)
  if #text > WIDTH - 2 then
    text = text:sub(#text - (WIDTH - 3))
  end
  local body = " " .. text
  body = body .. string.rep(" ", WIDTH - #body)

  local style = ESC .. "[" .. (BOLD and "1;" or "") .. "38;5;" .. FG .. ";48;5;" .. BG .. "m"
  return style .. body .. ESC .. "[0m"
end

-- **The panel expires itself.**
--
-- A plugin has no timer, and does not need one here: every redraw carries a
-- `ttl_ms`, so the last keypress leaves a drawing that removes itself once the
-- typing stops. The same mechanism covers this plugin crashing -- what it left
-- on the screen goes away on its own rather than staying until hexe restarts.
local function show()
  hexe.live.draw("keycast", {
    content = panel(table.concat(recent, " ")),
    corner = CORNER,
    width = WIDTH,
    height = 1,
    ttl_ms = LINGER_MS,
  })
end

hexe.key(TOGGLE, function()
  on = not on
  if on then
    -- Say so immediately: a toggle whose only feedback is the next keystroke
    -- leaves you pressing keys to find out whether it worked.
    recent = {}
    show()
  else
    recent = {}
    hexe.live.undraw("keycast")
  end
end, { mode = hexe.mode.act_and_consume })

hexe.on.key_pressed(function(ev)
  if not on then return end
  local key = ev and ev.key
  if not key or key == "" then return end

  recent[#recent + 1] = key
  while #recent > KEEP do
    table.remove(recent, 1)
  end
  show()
end)
