-- Read before it is trusted, in an interpreter with no `hexe` in it.
--
-- `stream` to be handed the pane's bytes, `popup` to show whatever address the
-- backend gives back. Notably NOT `typing`: this is view-only sharing, and the
-- absence of that word is what makes it so. Add it and the far end can type.
return {
  name        = "share",
  version     = "0.1.0",
  description = "Hand a pane to a stream backend and show the link it returns",
  entry       = "init.lua",
  access      = { "stream", "popup" },
  -- Started with the package as its working directory, so this can name a file
  -- it ships without knowing where it was installed.
  command     = "./backend.sh",
}
