-- Press a key, hand the pane to a backend, show where it went.
--
-- hexe never learns what the address is. It hands the backend the pane as
-- asciicast v2 and draws whatever block of text comes back -- a URL, an id, a
-- QR code already rendered into block characters. The moment hexe knows what a
-- QR is, it owns a QR library and a set of opinions about them.

local root = ...

-- The helper hexe starts alongside the session, declared here rather than in a
-- separate manifest: a plugin is a fragment of config, so it asks through the
-- registrar the config already had.
--
-- `stream` to be handed the pane's bytes, `popup` to show whatever address the
-- backend gives back. Notably NOT `typing`: this is view-only sharing, and the
-- absence of that word is what makes it so. Add it and the far end can type.
--
-- `dir` is the root, so the command can name a file the plugin ships without
-- knowing where it was installed.
hexe.plugin("share", {
  command = "./backend.sh",
  dir     = root,
  access  = { "stream", "popup" },
})

local BACKEND = os.getenv("HEXE_SHARE_BACKEND") or (root .. "/backend.sh")

-- Where the backend leaves the address it published to. A file rather than a
-- pipe because the backend is started by hexe and outlives this callback.
local ADDRESS = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/hexe-share-address"

hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.s }, function(ctx)
  local st = ctx.stream("share")
  if not st or not st.attached then
    ctx.popup("could not start sharing\n\n" .. ((st and st.error) or "no backend"))
    return
  end

  -- The backend needs a moment to publish before it has an address to report.
  -- Showing "sharing" first and the address when it exists beats blocking the
  -- key press on a network round trip.
  local f = io.open(ADDRESS, "r")
  local addr = f and f:read("*a") or nil
  if f then f:close() end

  if addr and #addr > 0 then
    ctx.popup("sharing this pane\n\n" .. addr .. "\n\npress any key to hide")
  else
    ctx.popup("sharing this pane\n\nwaiting for " .. BACKEND ..
              " to publish\npress " .. "ctrl+alt+s" .. " again for the address")
  end
end)

hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.x }, function(ctx)
  ctx.stream("share", false)
  ctx.popup("sharing stopped")
end)
