-- What this plugin is and what it needs. Read before it is trusted, in an
-- interpreter with no `hexe` in it.
--
-- `typing` and nothing else: hexe types the transcript, so the tool never
-- touches the pane itself. It does not need `screen`, and asking for less than
-- you could is the point of declaring at all.
return {
  name        = "dictate",
  version     = "0.1.0",
  description = "Push-to-talk speech to text, via whisper.cpp",
  entry       = "init.lua",
  access      = { "typing" },
}
