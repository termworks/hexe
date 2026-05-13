local hexe = require("hexe")

local system = {}

function system.session(opts)
  opts = opts or {}
  return hexe.segment.session({
    priority = opts.priority or 30,
    style = opts.style or hexe.style("git.branch"),
    prefix = opts.prefix or { output = "| " },
    suffix = opts.suffix or { output = " |" },
  })
end

function system.battery(opts)
  opts = opts or {}
  return hexe.segment.battery({
    priority = opts.priority or 40,
    style = opts.style or "bg:237 fg:250",
    suffix = opts.suffix or " ",
  })
end

function system.pod_name(opts)
  opts = opts or {}
  return hexe.segment.pod_name({
    priority = opts.priority or 1,
    style = opts.style or "bg:5 fg:0",
    prefix = opts.prefix or "| ",
    suffix = opts.suffix or " |",
  })
end

return system
