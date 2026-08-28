-- Read before it is trusted, in an interpreter with no `hexe` in it.
--
-- `popup` is what `draw` needs: putting something on the screen is the same
-- authority as putting a notification there. Notably NOT `screen` and NOT
-- `typing` -- this shows the keys hexe hands it and nothing else. It never
-- reads a pane and never writes to one, and the absence of those two words is
-- what says so.
--
-- No `command`: there is no helper process. Everything happens in hexe's own
-- Lua, on an event hexe already emits.
return {
  name        = "keycast",
  version     = "0.1.0",
  description = "Show the keys you are pressing, in a corner",
  entry       = "init.lua",
  access      = { "popup" },
}
