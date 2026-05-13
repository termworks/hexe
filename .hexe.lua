local hexe = require("hexe")

return hexe.setup({
  ses = {
    layouts = {
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
      }),
    },
  },
})
