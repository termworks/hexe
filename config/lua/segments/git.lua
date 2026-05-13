local hexe = require("hexe")

local git = {}

function git.branch(opts)
  opts = opts or {}
  return hexe.segment.git_branch({
    priority = opts.priority or 4,
    style = opts.style or hexe.style("git.branch"),
    prefix = opts.prefix or " ",
    suffix = opts.suffix or " ",
  })
end

function git.status(opts)
  opts = opts or {}
  return hexe.segment.git_status({
    priority = opts.priority or 5,
    style = opts.style or hexe.style("git.branch"),
    prefix = opts.prefix or " ",
    suffix = opts.suffix or " ",
  })
end

return git
