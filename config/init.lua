local hexe = require("hexe")
local default_keys = require("keys.default")
local default_layout = require("layouts.default")
local default_mux = require("mux.default")
local default_pop = require("pop.default")
local default_prompt = require("prompt.default")
local default_status = require("status.default")
local default_theme = require("themes.default")

-- events API is provided by runtime: hexe.events.on/off/once/debounce/throttle

return hexe.setup({
  theme = default_theme,
  keys = default_keys,
  mux = default_mux,
  status = default_status,
  prompt = default_prompt,
  pop = default_pop,
  ses = {
    layouts = {
      default_layout,
    },
  },
})
