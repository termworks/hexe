local hexe = require("hexe")

return hexe.layout("default", {
  enabled = true,
  tabs = {
    hexe.tab("main", {
      enabled = true,
      root = hexe.pane({ cwd = "." }),
    }),
  },
  floats = {
    hexe.float("opencode", {
      key = "1",
      enabled = true,
      title = "opencode",
      attrs = { per_cwd = true, inherit_env = true },
      command = "opencode",
    }),
    hexe.float("claude", {
      key = "2",
      enabled = true,
      attrs = { per_cwd = true, inherit_env = true },
      title = "claude",
      command = "bun x --package @anthropic-ai/claude-code claude",
    }),
    hexe.float("codex", {
      key = "3",
      enabled = true,
      attrs = { per_cwd = true, inherit_env = true },
      title = "codex",
      command = "codex",
    }),
    hexe.float("explorer", {
      key = "p",
      enabled = true,
      title = "explorer",
      position = { x = 100, y = 50 },
      size = { width = 40, height = 80 },
      attrs = { global = false, navigatable = true, inherit_env = true },
    }),
    hexe.float("sandbox", {
      key = "0",
      enabled = true,
      title = "sandbox",
      isolation = {
        profile = "sandbox",
        memory = "512M",
        pids = 100,
        cpu = "50000 100000",
      },
    }),
  },
})
