-- What this plugin is and what it needs. Read before it is trusted, in an
-- interpreter with no `hexe` in it -- so hexe can see what is being asked for
-- before any of the plugin runs.
return {
  name        = "share",
  version     = "0.1.0",
  description = "Hand a pane to a stream backend and show the link it gives back",
  entry       = "init.lua",
  access      = { "stream", "popup" },
}
