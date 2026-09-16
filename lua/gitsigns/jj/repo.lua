local cmd = require('gitsigns.jj.cmd')
local Path = require('gitsigns.util').Path
local Watcher = require('gitsigns.git.repo.watcher')

local uv = vim.uv or vim.loop ---@diagnostic disable-line: deprecated

--- A read-only view of a Jujutsu workspace. The comparison revision is the
--- working-copy parent; `latest()` makes merge working copies deterministic.
--- @class Gitsigns.JjRepo : Gitsigns.Repo
--- @field backend 'jj'
--- @field gitdir string
--- @field commondir string
--- @field toplevel string
--- @field detached boolean
--- @field abbrev_head string
--- @field head_oid? string
--- @field username? string
--- @field private _refs integer
--- @field private _watcher? Gitsigns.Repo.Watcher
--- @field private _git_repo? Gitsigns.Repo
local M = {}
M.__index = M

local cache = setmetatable({}, { __mode = 'v' })

--- @param root string
--- @return Gitsigns.JjRepo
local function new(root)
  --- @type Gitsigns.JjRepo
  local self = setmetatable({
    backend = 'jj',
    gitdir = Path.join(root, '.jj'),
    commondir = Path.join(root, '.jj'),
    toplevel = root,
    detached = false,
    abbrev_head = '@',
    _refs = 0,
  }, M)
  if require('gitsigns.config').config.watch_gitdir.enable then
    --- @diagnostic disable-next-line: access-invisible
    self._watcher = Watcher.new(self.gitdir, nil, {
      Path.join(self.gitdir, 'repo', 'op_heads', 'heads'),
      Path.join(self.gitdir, 'working_copy'),
    })
  end
  return self
end

--- @async
--- @param cwd? string
--- @return Gitsigns.JjRepo? repo
--- @return string? err
function M.get(cwd)
  if not cwd or vim.fn.executable('jj') ~= 1 then
    return
  end
  local stdout, stderr, code = cmd({ 'root' }, { cwd = cwd, ignore_error = true })
  if code ~= 0 or not stdout[1] then
    return nil, stderr
  end
  local root = vim.fs.normalize(vim.trim(stdout[1]))
  local repo = cache[root]
  if not repo then
    repo = new(root)
    cache[root] = repo
  end
  repo:ref()
  return repo
end

function M:ref()
  self._refs = self._refs + 1
  return self
end

function M:unref()
  self._refs = math.max(self._refs - 1, 0)
  if self._refs == 0 then
    if self._watcher then
      self._watcher:close()
      self._watcher = nil
    end
    if self._git_repo then
      self._git_repo:unref()
      self._git_repo = nil
    end
    cache[self.toplevel] = nil
  end
end

function M:close()
  self:unref()
end

function M:has_watcher()
  return self._watcher ~= nil
end

function M:on_update(callback)
  return assert(self._watcher, 'Watcher not initialized'):on_update(callback)
end

function M:lock(fn)
  return fn()
end

--- @async
--- @param args string[]
--- @param spec? Gitsigns.Jj.JobSpec
function M:command(args, spec)
  spec = spec or {}
  spec.cwd = self.toplevel
  return cmd(args, spec)
end

--- Return a companion Git repository when Git HEAD represents the same commit
--- as jj's selected working-copy parent.
--- @async
--- @return Gitsigns.Repo? repo
--- @return string? err
function M:get_blame_repo()
  local gitdir = Path.join(self.toplevel, '.git')
  if not Path.exists(gitdir) then
    return nil, 'Blame is unsupported in this Jujutsu workspace: no colocated Git repository'
  end

  if not self._git_repo then
    local GitRepo = require('gitsigns.git.repo')
    local repo = GitRepo.get(self.toplevel, gitdir, self.toplevel)
    if not repo then
      return nil,
        'Blame is unsupported in this Jujutsu workspace: cannot open colocated Git repository'
    end
    self._git_repo = repo
    self.username = repo.username
  end

  local jj_parent, _, jj_code = self:command({
    'log',
    '--no-graph',
    '--revision',
    'latest(@-, 1)',
    '--template',
    'commit_id',
  }, { ignore_error = true })
  local git_head, _, git_code = self._git_repo:command(
    { 'rev-parse', 'HEAD' },
    { ignore_error = true }
  )

  if
    jj_code ~= 0
    or git_code ~= 0
    or not jj_parent[1]
    or not git_head[1]
    or vim.trim(jj_parent[1]) ~= vim.trim(git_head[1])
  then
    return nil,
      'Blame is unsupported in this Jujutsu workspace: Git HEAD does not match the jj working-copy parent'
  end

  return self._git_repo
end

--- @async
--- @param file string
--- @return string[] stdout, string? stderr, integer code
function M:get_show_text(file)
  local preserve_eol = require('gitsigns.config').config.jj.show_parent_on_empty
  return self:command(
    { 'file', 'show', '--revision', 'latest(@-, 1)', '--', file },
    { ignore_error = true, text = not preserve_eol }
  )
end

--- Get the parent normally, or its parent when the working-copy change is empty.
--- @async
--- @param file string
--- @return string[] stdout, string? stderr, integer code
function M:get_show_text_parent_on_empty(file)
  return self:command({
    'file',
    'show',
    '--revision',
    'latest((@ & ~empty())- | (@ & empty())--, 1)',
    '--',
    file,
  }, { ignore_error = true, text = false })
end

--- @async
function M:file_info(file)
  local root = vim.fs.normalize(self.toplevel)
  local normalized = vim.fs.normalize(file)
  local relpath = vim.startswith(normalized, root .. '/') and normalized:sub(#root + 2) or file
  local _, stderr, code = self:get_show_text(relpath)
  local stat = uv.fs_stat(file)
  if stderr and not stat then
    -- A deleted file is still attachable when it exists in the parent.
    if code ~= 0 then
      return nil, stderr
    end
  end
  --- @type Gitsigns.Repo.LsFiles.Result
  local result = {
    relpath = relpath,
    mode_bits = '100644',
    object_name = code == 0 and relpath or nil,
    object_missing = code == 0 and not stat and true or nil,
  }
  return result
end

--- @async
--- @param _base string?
--- @param include_untracked? boolean
--- @return {path:string, deleted?:boolean}[]
function M:files_changed(_base, include_untracked)
  local output = self:command({ 'diff', '--summary', '--revision', '@' }, { ignore_error = true })
  local ret = {}
  for _, line in ipairs(output) do
    local status, path = line:match('^([MADRC?%!])%s+(.+)$')
    if status and path and (include_untracked or status ~= '?') then
      ret[#ret + 1] = { path = path, deleted = status == 'D' and true or nil }
    end
  end
  return ret
end

function M:check_attr(_, files)
  local ret = {}
  for _, file in ipairs(files) do
    ret[file] = 'unspecified'
  end
  return ret
end

return M
