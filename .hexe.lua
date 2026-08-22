-- hexe, in this checkout.
--
-- Settings are assigned and declarations register themselves; the file returns
-- nothing. Same shape as `.env.lua` and `.make.lua` beside it.

local hexe = require("hexe")

hexe.layout("hexe", {
  root = "/home/bresilla/data/code/tools/hexe",
  tabs = {
    hexe.tab("hexe-1", {
      root = hexe.split("horizontal", {
        hexe.pane({ size = 50 }),
        hexe.pane({ size = 50 }),
      }),
    }),
    hexe.tab("hexe-2", {
      root = hexe.pane(),
    }),
  },
})
