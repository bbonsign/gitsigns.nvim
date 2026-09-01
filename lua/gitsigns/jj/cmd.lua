local async = require('gitsigns.async')
local log = require('gitsigns.debug.log')
local util = require('gitsigns.util')

local asystem = async.wrap(3, require('gitsigns.system').system)

--- @class Gitsigns.Jj.JobSpec : vim.SystemOpts
--- @field ignore_error? boolean

--- @async
--- @param args string[]
--- @param spec? Gitsigns.Jj.JobSpec
--- @return string[] stdout, string? stderr, integer code
return function(args, spec)
  spec = spec or {}
  if spec.cwd then
    spec.cwd = util.cygpath(spec.cwd)
  end
  spec.text = true

  local cmd = { 'jj', '--no-pager', '--color=never' }
  vim.list_extend(cmd, args)
  log.dprint(unpack(cmd))

  local obj = asystem(cmd, spec)
  async.schedule()

  if not spec.ignore_error and obj.code > 0 then
    log.eprintf(
      "Received exit code %d when running command '%s':\n%s",
      obj.code,
      table.concat(cmd, ' '),
      obj.stderr
    )
  end

  local stdout = vim.split(obj.stdout or '', '\n')
  if stdout[#stdout] == '' then
    stdout[#stdout] = nil
  end
  return stdout, obj.stderr ~= '' and obj.stderr or nil, obj.code
end
