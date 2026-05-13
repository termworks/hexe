local hexe = require("hexe")
local git = require("segments.git")
local system = require("segments.system")

local function segments(list)
  for i, segment in ipairs(list) do
    list[i] = hexe.segment(segment)
  end
  return list
end

return {
  left = segments({
    {
      name = "ssh",
      priority = 60,
      render = function(ctx)
        if not ctx.env.SSH_CONNECTION then
          return nil
        end
        return { { text = " //", style = hexe.style("prompt.host") } }
      end,
    },
    {
      name = "hostname",
      priority = 15,
      builtin = function(_)
        return hexe.segment.builtin.hostname({ style = hexe.style("prompt.host"), suffix = " " })
      end,
    },
    {
      name = "distro",
      priority = 10,
      render = function(_)
        local p = io.popen("~/.config/profile/functions/shell/distrologo")
        if not p then
          return nil
        end
        local raw = p:read("*a") or ""
        p:close()
        local t = raw:match("^%s*(.-)%s*$")
        if not t or t == "" then
          return nil
        end
        return { { text = " " .. t, style = hexe.style("git.branch") } }
      end,
    },
    {
      name = "username",
      priority = 1,
      builtin = function(_)
        return hexe.segment.builtin.username({ style = hexe.style("git.branch"), suffix = " " })
      end,
    },
    {
      name = "direnv",
      priority = 25,
      render = function(ctx)
        if not ctx.env.DIRENV_DIR then
          return nil
        end
        return { { text = "▓", style = hexe.style("git.branch") } }
      end,
    },
    {
      name = "sudo",
      priority = 6,
      builtin = function(_)
        return hexe.segment.builtin.sudo({ style = "bold bg:240 fg:171" })
      end,
    },
    {
      name = "tab",
      priority = 35,
      render = function(ctx)
        local tab = ((ctx and ctx.env and ctx.env.TAB) or ""):match("^%s*(.-)%s*$")
        if tab ~= "" and tab ~= ".reset-prompt" and tab ~= "reset-prompt" then
          return nil
        end

        local p = io.popen("tab -l 2> /dev/null | wc -l")
        if not p then
          return nil
        end
        local raw = p:read("*a") or ""
        p:close()
        local total = tonumber((raw:match("^%s*(.-)%s*$")) or "0") or 0
        local n = total - 1
        if n <= 0 then
          return nil
        end
        return {
          { text = "|", style = "fg:7" },
          { text = " " .. tostring(n) .. " ", style = hexe.style("prompt.host") },
        }
      end,
    },
    {
      name = "status",
      priority = 3,
      builtin = function(_)
        return hexe.segment.builtin.status({ style = "bg:0 fg:9", prefix = " ", suffix = " " })
      end,
    },
    {
      name = "container",
      priority = 50,
      render = function(_)
        local p = io.popen("systemd-detect-virt 2>/dev/null")
        if not p then
          return nil
        end
        local out = p:read("*a") or ""
        p:close()
        local virt = out:match("^%s*(.-)%s*$")
        if virt == "" or virt == "none" then
          return nil
        end
        if virt == "lxc" then
          return {
            { text = " ", style = "bg:0 fg:0" },
            { text = " >> ", style = "bg:5 fg:0" },
          }
        end
        return {
          { text = " ", style = "bg:0 fg:0" },
          { text = " :: ", style = "bg:5 fg:0" },
        }
      end,
    },
    {
      name = "separator",
      priority = 20,
      render = function(_)
        return { { text = "|", style = "fg:7" } }
      end,
    },
  }),

  right = segments({
    system.pod_name(),
    git.branch(),
    git.status(),
  }),
}
