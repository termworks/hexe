local hexe = require("hexe")

local function focused_process_is_editor(ctx)
  local p = ctx.pane(0)
  return p and (p.process_name == "nvim" or p.process_name == "vim")
end

local function focused_split(ctx)
  local p = ctx.pane(0)
  return p and p.focus_split
end

return {
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.q }, hexe.action.quit()),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.d }, hexe.action.detach()),

  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.z }, hexe.action.pane.disown()),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.a }, hexe.action.pane.adopt()),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.c }, hexe.action.clipboard.copy()),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.v }, hexe.action.clipboard.request()),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.n }, hexe.action.system.notify()),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.k }, hexe.action.overlay.keycast_toggle()),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.o }, hexe.action.pane.select()),

  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.h }, hexe.action.split.horizontal(), { when = focused_split }),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.v }, hexe.action.split.vertical(), { when = focused_split }),

  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.t }, hexe.action.tab.new()),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.x }, hexe.action.tab.close()),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.dot }, hexe.action.tab.next()),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.comma }, hexe.action.tab.prev()),

  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.up }, nil, { when = focused_process_is_editor, mode = hexe.mode.passthrough_only }),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.down }, nil, { when = focused_process_is_editor, mode = hexe.mode.passthrough_only }),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.left }, nil, { when = focused_process_is_editor, mode = hexe.mode.passthrough_only }),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.right }, nil, { when = focused_process_is_editor, mode = hexe.mode.passthrough_only }),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.up }, hexe.action.focus.move("up")),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.down }, hexe.action.focus.move("down")),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.left }, hexe.action.focus.move("left")),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.right }, hexe.action.focus.move("right")),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.s }, hexe.action.layout.save()),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.l }, hexe.action.layout.load()),

  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.p }, hexe.action.overlay.sprite_toggle(), { mode = hexe.mode.act_and_consume }),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.shift, hexe.key.p }, hexe.action.overlay.sprite_toggle(), { mode = hexe.mode.act_and_consume }),

  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key["1"] }, hexe.action.float.toggle("1")),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key["2"] }, hexe.action.float.toggle("2")),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key["3"] }, hexe.action.float.toggle("3")),
  hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key["0"] }, hexe.action.float.toggle("0")),
}
