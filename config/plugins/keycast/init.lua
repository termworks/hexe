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

local KEEP = 8            -- chords kept on screen
local LINGER_MS = 2500    -- how long after the last key the panel stays
local WIDTH = 34
local CORNER = "bottomright"

local recent = {}

-- **The panel expires itself.**
--
-- A plugin has no timer, and does not need one here: every redraw carries a
-- `ttl_ms`, so the last keypress leaves a drawing that removes itself once the
-- typing stops. The same mechanism covers this plugin crashing -- what it left
-- on the screen goes away on its own rather than staying until hexe restarts.
local function show()
  local text = table.concat(recent, " ")
  if #text > WIDTH - 2 then
    text = text:sub(#text - (WIDTH - 3))
  end
  hexe.live.draw("keycast", {
    -- Rendered by the painter, so the styling lives with the rest of the
    -- theme rather than as escape codes in here. A painter that does not
    -- define the view simply draws nothing, which is the right failure.
    view = "plug.keycast",
    values = { keys = text },
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
