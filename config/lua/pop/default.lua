return {
  notify = {
    mux = {
      fg = 232,
      bg = 1,
      bold = true,
      padding_x = 3,
      padding_y = 1,
      offset = 3,
      alignment = "center",
      duration_ms = 3000,
    },
    pane = {
      fg = 232,
      bg = 1,
      bold = true,
      padding_x = 3,
      padding_y = 1,
      offset = 2,
      alignment = "center",
      duration_ms = 3000,
    },
  },

  confirm = {
    mux = {
      fg = 232,
      bg = 1,
      bold = true,
      padding_x = 3,
      padding_y = 1,
    },
    pane = {
      fg = 232,
      bg = 1,
      bold = true,
      padding_x = 3,
      padding_y = 1,
    },
  },

  choose = {
    mux = {
      fg = 232,
      bg = 1,
      highlight_fg = 1,
      highlight_bg = 232,
      visible_count = 10,
    },
    pane = {
      fg = 232,
      bg = 1,
      highlight_fg = 1,
      highlight_bg = 232,
      visible_count = 10,
    },
  },

  widgets = {
    pokemon = {
      enabled = false,
      position = "topright",
      shiny_chance = 0.01,
    },
    keycast = {
      enabled = false,
      position = "bottomright",
      duration_ms = 2000,
      max_entries = 8,
      grouping_timeout_ms = 700,
    },
    digits = {
      enabled = false,
      position = "topleft",
      size = "small",
    },
  },
}
