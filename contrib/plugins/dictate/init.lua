-- Push-to-talk: hold the chord, speak, release.
--
-- The keybindings are HERE, in the plugin, which is the whole reason a plugin
-- is a package. Installing this does not mean pasting two `hexe.key` lines into
-- your own config, and removing it does not mean finding them again.
--
-- hexe contributes two general things and no dictation code at all: `typing`
-- access, so the transcript can be typed into a pane, and `capture`, so the
-- pane shows three bars while a microphone is open. Swap whisper for anything
-- else and hexe does not change.

local here = ...                       -- where this package was installed
local recorder = here .. "/record.sh"

local CHORD = { hexe.key.ctrl, hexe.key.alt, hexe.key.d }

hexe.key(CHORD, function(ctx)
  -- Remember the pane NOW. Transcription takes a moment and it is easy to
  -- change panes in that moment; typing into whatever is focused when the tool
  -- finishes puts a sentence in the wrong shell.
  local pane = ctx.pane()
  ctx.exec(recorder .. " start " .. (pane and pane.uuid or ""))
end, { on = hexe.when.press })

hexe.key(CHORD, function(ctx)
  ctx.exec(recorder .. " stop")
end, { on = hexe.when.release })

-- Give up on a stuck recording without typing anything.
hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.c }, function(ctx)
  ctx.exec(recorder .. " cancel")
end)
