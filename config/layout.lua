return {
  keybingings = {
    { key = { hx.key.ctrl, hx.key.alt, hx.key["1"] }, action = { type = hx.action.float_toggle, float = "1" } },
    { key = { hx.key.ctrl, hx.key.alt, hx.key["2"] }, action = { type = hx.action.float_toggle, float = "2" } },
    { key = { hx.key.ctrl, hx.key.alt, hx.key["3"] }, action = { type = hx.action.float_toggle, float = "3" } },
    { key = { hx.key.ctrl, hx.key.alt, hx.key["0"] }, action = { type = hx.action.float_toggle, float = "0" } },
  },

  layout = {
    name = "default",
    enabled = true,
    tabs = {
      {
        name = "main",
        enabled = true,
        root = { cwd = "." },
      },
    },
    floats = {
      {
        key = "1",
        enabled = true,
        title = "opencode",
        attributes = { per_cwd = true, inherit_env = true },
        command = "opencode",
      },
      {
        key = "2",
        enabled = true,
        attributes = { per_cwd = true, inherit_env = true },
        title = "opencode",
        command = "opencode",
      },
      {
        key = "3",
        enabled = true,
        attributes = { per_cwd = true, inherit_env = true },
        title = "claude",
        -- command = "/env/bin/bun x --package @anthropic-ai/claude-code claude",
        command = "codex",
      },
      {
        key = "p",
        enabled = true,
        title = "explorer",
        position = { x = 100, y = 50 },
        size = { width = 40, height = 80 },
        attributes = { global = false, navigatable = true, inherit_env = true },
      },
      {
        key = "0",
        enabled = true,
        title = "sandbox",
        isolation = {
          profile = "sandbox",
          memory = "512M",
          pids = 100,
          cpu = "50000 100000",
        },
      },
    },
  },
}
