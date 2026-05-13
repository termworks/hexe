local hexe = require("hexe")

local border = {
  chars = {
    top_left = "╔",
    top_right = "╗",
    bottom_left = "╚",
    bottom_right = "╝",
    horizontal = "═",
    vertical = "║",
    left_t = "╠",
    right_t = "╣",
    top_t = "╦",
    bottom_t = "╩",
    cross = "╬",
  },
}

return {
  confirm = {
    exit = true,
    detach = true,
    disown = true,
    close = true,
  },

  selection_color = 238,

  mouse = {
    selection_override = { "ctrl", "alt" },
  },

  floats = {
    defaults = {
      size = { width = 80, height = 70 },
      attrs = {
        exclusive = true,
        sticky = true,
        global = true,
        destroy = false,
      },
      color = { active = 1, passive = 237 },
      style = {
        border = border,
        title = {
          name = "title",
          render = function(ctx)
            local t = hexe.segment.title(ctx)
            return {
              { text = " ", style = "bg:1 fg:1" },
              { text = t, style = "bg:1 fg:0" },
              { text = " ", style = "bg:1 fg:1" },
            }
          end,
          position = "bottomright",
        },
      },
    },

    adhoc = {
      size = { width = 82, height = 72 },
      color = { active = 4, passive = 237 },
    },

    match = {
      ["^container$"] = {
        color = { active = 1, passive = 237 },
        padding = { x = 2, y = 1 },
        style = {
          shadow = { color = 236 },
          border = border,
          title = {
            name = "title",
            render = function(ctx)
              local t = hexe.segment.title(ctx)
              return {
                { text = " ", style = "bg:0 fg:1" },
                { text = t, style = "bg:1 fg:0" },
                { text = " ", style = "bg:0 fg:1" },
              }
            end,
            position = "topright",
          },
        },
      },
    },
  },

  splits = {
    color = { active = 1, passive = 237 },
    chars = {
      vertical = "│",
      horizontal = "─",
    },
  },
}
