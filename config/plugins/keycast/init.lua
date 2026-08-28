-- Show the keys you are pressing.
--
-- This used to live in hexe: an overlay type, a widget config, a toggle action,
-- a ring buffer in the frontend and a renderer, spread over ten files. None of
-- it was terminal-multiplexer work. hexe knows which keys were pressed and
-- which of them are safe to show; drawing a list of them in a corner is
-- something anything can do, given that.
--
-- So hexe reports `key_pressed` and this draws. Turning it off is uninstalling
-- it, or not allowing it -- there is no toggle to carry.
--
-- **It draws itself.** `draw` also takes a `view` for the painter to render,
-- which keeps styling with the rest of a theme -- but it makes the plugin need
-- a painter, and a painter's config, to show you a keystroke. This ships its
-- own bytes instead: what it needs is a background, a foreground and some text,
-- and that is three escape codes. Change them here.

local KEEP = 8            -- chords kept on screen
local LINGER_MS = 2500    -- how long after the last key the panel stays
local WIDTH = 34
local CORNER = "bottomright"

local FG = 15             -- 256-colour foreground
local BG = 237            -- 256-colour background
local BOLD = true

local ESC = string.char(27)

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

hexe.on.key_pressed(function(ev)
  local key = ev and ev.key
  if not key or key == "" then return end

  recent[#recent + 1] = key
  while #recent > KEEP do
    table.remove(recent, 1)
  end
  show()
end)
