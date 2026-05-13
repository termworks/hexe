local hexe = require("hexe")
local system = require("segments.system")

local function segments(list)
  for i, segment in ipairs(list) do
    list[i] = hexe.segment(segment)
  end
  return list
end

local rec_opts = {
  scope = "pod",
  out = "/tmp/hexe-active-pod.cast",
  capture_input = false,
}

local function fish_style_truncate(path)
  if not path or path == "" then return "/" end

  local home = os and os.getenv("HOME") or ""
  local p = path
  if home and home ~= "" and p:sub(1, home:len()) == home then
    p = "~" .. p:sub(home:len() + 1)
  end

  local starts_with_tilde = p:sub(1, 1) == "~"
  local starts_with_slash = p:sub(1, 1) == "/"
  local base = p
  if starts_with_tilde then
    base = p:sub(2)
  elseif starts_with_slash then
    base = p:sub(2)
  end

  local components = {}
  for comp in base:gmatch("[^/]+") do
    table.insert(components, comp)
  end

  if #components == 0 then
    return p:sub(1, 1)
  end

  local result = {}
  for i, comp in ipairs(components) do
    if i < #components then
      if comp:sub(1, 1) == "." and comp:len() > 1 then
        table.insert(result, "." .. comp:sub(2, 2))
      else
        table.insert(result, comp:sub(1, 1))
      end
    else
      table.insert(result, comp)
    end
  end

  local prefix = ""
  if starts_with_tilde then
    prefix = "~"
  elseif starts_with_slash then
    prefix = "/"
  end

  return prefix .. table.concat(result, "/")
end

return {
  enabled = true,

  left = segments({
    {
      name = "time_lua",
      priority = 10,
      render = function(_)
        return {
          { text = " ", style = "bg:237 fg:250" },
          { text = os.date("%H:%M:%S"), style = "bold bg:237 fg:250" },
          { text = " ", style = "bg:237 fg:250" },
        }
      end,
    },
    system.session(),
    {
      name = "spinner",
      priority = 20,
      builtin = function(ctx)
        local p = ctx.pane(0)
        if p and ((p.shell_running and not p.alt_screen) or p.adhoc_float) then
          return hexe.segment.builtin.spinner({
            kind = "knight_rider",
            width = 10,
            step = 40,
            hold = 20,
            colors = { 243, 242, 241, 240, 239, 238, 237, 236 },
            bg = 0,
            prefix = " ",
            suffix = " ",
          })
        end
        return nil
      end,
    },
    {
      name = "randomdo",
      priority = 200000,
      builtin = function(ctx)
        local p = ctx.pane(0)
        if p and ((p.shell_running and not p.alt_screen) or p.adhoc_float) then
          return hexe.segment.builtin.randomdo({ style = "bg:0 fg:1", suffix = " " })
        end
        return nil
      end,
    },
  }),

  center = segments({
    {
      name = "tabs",
      priority = 1,
      render = function(ctx)
        return hexe.segment.tabs(ctx)
      end,
      tab_title = "basename",
      active_style = hexe.style("git.branch"),
      inactive_style = "bg:237 fg:250",
      separator = " | ",
      separator_style = "fg:7",
    },
  }),

  right = segments({
    {
      name = "rec",
      priority = 11,
      render = function(_)
        local st = hexe.status.recording(rec_opts.scope)
        if st and st.active then
          return { { text = " REC ", style = hexe.style("recording.active") } }
        end
        return { { text = " rec ", style = hexe.style("recording.active") } }
      end,
      button = {
        on_left_click = function(ctx)
          local rec = hexe.record.active(ctx, rec_opts)
          if not rec then return nil end
          return rec.switch()
        end,
        on_right_click = function(_)
          return hexe.record.stop({ scope = rec_opts.scope })
        end,
        active_when = function(_)
          local st = hexe.status.recording(rec_opts.scope)
          return st and st.active == true
        end,
        left_style = "bg:2 fg:0 bold",
        middle_style = "bg:3 fg:0 bold",
        right_style = hexe.style("recording.active"),
        inverse_on_hover = true,
      },
    },
    system.battery(),
    {
      name = "directory",
      priority = 50,
      render = function(ctx)
        local cwd = ctx and ctx.cwd and ctx.cwd ~= "" and ctx.cwd or nil
        if not cwd then
          cwd = os and os.getenv and os.getenv("PWD") or nil
        end
        if not cwd and ctx and ctx.pane then
          local p = ctx.pane(0)
          if p and p.cwd and p.cwd ~= "" then
            cwd = p.cwd
          end
        end
        if cwd and cwd ~= "" then
          local truncated = fish_style_truncate(cwd)
          return {
            { text = " " .. truncated, style = hexe.style("status.directory") },
            { text = " ", style = hexe.style("status.directory") },
          }
        end
        return nil
      end,
    },
  }),
}
