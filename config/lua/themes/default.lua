local hexe = require("hexe")

return hexe.theme({
  colors = {
    bg = 237,
    fg = 250,
    accent = 1,
    good = 2,
    warn = 3,
  },

  styles = {
    ["status.active"] = "bg:1 fg:0 bold",
    ["status.inactive"] = "bg:237 fg:250",
    ["status.directory"] = "bg:237 fg:15",
    ["recording.active"] = "bg:1 fg:15 bold",
    ["prompt.host"] = "bg:237 italic fg:15",
    ["git.branch"] = "bg:1 fg:0",
  },

  chars = {
    split_vertical = "│",
    split_horizontal = "─",
  },
})
