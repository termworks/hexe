-- Bind a key, hand the pane to the backend, show whatever address comes back.
--
-- The keybinding lives HERE, in the plugin, not in your config: installing a
-- plugin should not mean pasting somebody's glue into your own file, and
-- removing one should not mean hunting for the lines to delete.

local BACKEND = os.getenv("HEXE_SHARE_BACKEND") or "drop cast"

hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.s }, function(ctx)
  local st = ctx.stream("share")
  if not st or not st.attached then
    ctx.popup("could not start sharing: " .. ((st and st.error) or "no backend"))
    return
  end
  -- The backend prints where it published to. hexe has no idea what that
  -- string is -- a URL, an id, a QR drawn in block characters -- it just draws
  -- the block until someone presses a key.
  ctx.popup("sharing this pane\n\nbackend: " .. BACKEND .. "\n\npress any key to hide")
end)

hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.x }, function(ctx)
  ctx.stream("share", false)
  ctx.popup("sharing stopped")
end)
