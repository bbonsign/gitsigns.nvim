local helpers = require('test.gs_helpers')

local clear = helpers.clear
local command = helpers.api.nvim_command
local eq = helpers.eq
local exec_lua = helpers.exec_lua
local fn = helpers.fn
local mkdir = helpers.mkdir
local setup_gitsigns = helpers.setup_gitsigns
local wait_for_attach = helpers.wait_for_attach
local write_to_file = helpers.write_to_file
local scratch --- @type string

local blame_unsupported =
  'Blame is unsupported in this Jujutsu workspace: no colocated Git repository'

helpers.env()

local function require_jj()
  if fn.executable('jj') ~= 1 then
    pending('requires jj')
  end
end

--- @param ... string
local function jj(...)
  local output = fn.system(vim.list_extend({ 'jj', '--no-pager', '-R', scratch }, { ... }))
  eq(0, exec_lua('return vim.v.shell_error'), output)
end

--- @param colocate? boolean
local function setup_jj_repo(colocate)
  require_jj()
  scratch = helpers.scratch
  helpers.cleanup()
  mkdir(scratch)
  local output = fn.system({
    'jj',
    '--no-pager',
    'git',
    'init',
    colocate and '--colocate' or '--no-colocate',
    scratch,
  })
  eq(0, exec_lua('return vim.v.shell_error'), output)
  write_to_file(scratch .. '/file.txt', { 'base', 'unchanged' })
  jj('new')
end

describe('jj backend', function()
  before_each(function()
    clear()
    helpers.setup_path()
  end)

  after_each(function()
    helpers.cleanup()
  end)

  it('prefers jj in colocated workspaces and provides hunks, navigation, and preview', function()
    setup_jj_repo(true)
    write_to_file(scratch .. '/file.txt', { 'changed', 'unchanged', 'added' })

    local config = vim.tbl_deep_extend('force', helpers.test_config, {
      watch_gitdir = { enable = true },
    })
    setup_gitsigns(config)
    helpers.edit(scratch .. '/file.txt')
    wait_for_attach()

    helpers.expectf(function()
      local backend, hunks = exec_lua(function()
        local bcache = assert(require('gitsigns.cache').cache[vim.api.nvim_get_current_buf()])
        return bcache.git_obj.repo.backend, bcache.hunks
      end)
      eq('jj', backend)
      eq(1, #hunks)
    end)

    exec_lua(function()
      require('gitsigns').nav_hunk('next', { wrap = false })
    end)
    eq(1, fn.line('.'))

    exec_lua(function()
      require('gitsigns').preview_hunk()
    end)
    eq(true, exec_lua("return require('gitsigns.popup').is_open('hunk') ~= nil"))

    exec_lua("require('gitsigns.popup').close('hunk')")

    exec_lua(function()
      require('gitsigns').reset_hunk({ 1, 1 })
    end)
    helpers.expectf(function()
      eq({ 'base', 'unchanged', 'added' }, helpers.api.nvim_buf_get_lines(0, 0, -1, false))
    end)

    exec_lua(function()
      require('gitsigns').reset_buffer()
    end)
    helpers.expectf(function()
      eq({ 'base', 'unchanged' }, helpers.api.nvim_buf_get_lines(0, 0, -1, false))
    end)

    command('write')
    jj('new')
    helpers.expectf(function()
      eq(
        0,
        exec_lua(function()
          local bcache = assert(require('gitsigns.cache').cache[vim.api.nvim_get_current_buf()])
          return #(bcache.hunks or {})
        end)
      )
    end)
  end)

  it('shows the parent change while the working-copy change is empty', function()
    setup_jj_repo()

    write_to_file(scratch .. '/file.txt', { 'changed', 'unchanged' })
    jj('new')

    local config = vim.tbl_deep_extend('force', helpers.test_config, {
      jj = { show_parent_on_empty = true },
    })
    setup_gitsigns(config)
    helpers.edit(scratch .. '/file.txt')
    wait_for_attach()

    helpers.check({
      status = { head = '@', added = 0, changed = 1, removed = 0 },
      signs = { changed = 1 },
    })

    local preview = exec_lua(function()
      require('gitsigns').preview_hunk()
      local win = assert(require('gitsigns.popup').is_open('hunk'))
      return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
    end)
    eq({ 'Hunk 1 of 1', '-base', '+changed' }, preview)

    exec_lua("require('gitsigns.popup').close('hunk')")

    helpers.api.nvim_buf_set_lines(0, 0, 1, false, { 'edited' })
    helpers.check({
      status = { head = '@', added = 0, changed = 1, removed = 0 },
      signs = { changed = 1 },
    })
    helpers.expectf(function()
      eq({ 'changed' }, exec_lua("return require('gitsigns').get_hunks()[1].removed.lines"))
    end)

    helpers.api.nvim_buf_set_lines(0, 0, 1, false, { 'changed' })
    helpers.check({
      status = { head = '@', added = 0, changed = 1, removed = 0 },
      signs = { changed = 1 },
    })
    helpers.expectf(function()
      eq({ 'base' }, exec_lua("return require('gitsigns').get_hunks()[1].removed.lines"))
    end)
  end)

  it('does not show the parent change when the working-copy change is non-empty', function()
    setup_jj_repo()
    write_to_file(scratch .. '/new.txt', { 'new change' })
    jj('status')

    local config = vim.tbl_deep_extend('force', helpers.test_config, {
      jj = { show_parent_on_empty = true },
    })
    setup_gitsigns(config)
    helpers.edit(scratch .. '/file.txt')
    wait_for_attach()

    helpers.check({
      status = { head = '@', added = 0, changed = 0, removed = 0 },
      signs = {},
    })
  end)

  it('lists added and deleted files in quickfix and rejects staging', function()
    setup_jj_repo()
    os.remove(scratch .. '/file.txt')
    write_to_file(scratch .. '/new.txt', { 'new' })

    command('cd ' .. fn.fnameescape(scratch))
    setup_gitsigns(helpers.test_config)
    helpers.edit(scratch .. '/new.txt')
    wait_for_attach()

    exec_lua(function()
      require('gitsigns').setqflist('all', { open = false })
    end)

    helpers.expectf(function()
      local entries = fn.getqflist()
      eq(2, #entries)
      eq(true, entries[1].text:match('^Removed') ~= nil)
      eq(true, entries[2].text:match('^Added') ~= nil)
    end)

    eq(
      'Jujutsu backend is read-only; staging is unsupported',
      exec_lua(function()
        local bcache = assert(require('gitsigns.cache').cache[vim.api.nvim_get_current_buf()])
        return bcache.git_obj:stage_hunks({})
      end)
    )
  end)

  it('uses matching colocated Git for blame without changing the jj backend', function()
    setup_jj_repo(true)
    write_to_file(scratch .. '/file.txt', { 'changed', 'unchanged' })
    jj('new')
    setup_gitsigns(helpers.test_config)
    helpers.edit(scratch .. '/file.txt')
    wait_for_attach()
    helpers.api.nvim_buf_set_lines(0, 1, 2, false, { 'unsaved' })

    local result = exec_lua(function()
      local async = require('gitsigns.async')
      local cache = require('gitsigns.cache').cache
      local bcache = assert(cache[vim.api.nvim_get_current_buf()])
      local info, err = async.run(bcache.get_blame, bcache, 1):wait(5000)

      local source_win = vim.api.nvim_get_current_win()
      local commit_buf = async
        .run(require('gitsigns.actions.show_commit'), assert(info).commit.sha, 'vsplit')
        :wait(5000)
      local commit_filetype = commit_buf and vim.bo[commit_buf].filetype
      vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
      vim.api.nvim_set_current_win(source_win)

      async.run(require('gitsigns.actions.blame_line'), { full = true }):wait(5000)
      local popup_win = assert(require('gitsigns.popup').is_open('blame'))
      local popup_lines =
        vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(popup_win), 0, -1, false)
      require('gitsigns.popup').close('blame')

      async.run(require('gitsigns.actions.blame').blame):wait(5000)
      return {
        backend = bcache.git_obj.repo.backend,
        commit_filetype = commit_filetype,
        err = err,
        panel_filetype = vim.bo.filetype,
        panel_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false),
        popup_lines = popup_lines,
        reblame_map = vim.fn.maparg('r', 'n'),
        sha = info and info.commit.sha,
      }
    end)

    eq('jj', result.backend)
    eq('git', result.commit_filetype)
    eq(nil, result.err)
    eq('gitsigns-blame', result.panel_filetype)
    eq(2, #result.panel_lines)
    eq(false, result.popup_lines[1] == nil)
    eq('', result.reblame_map)
    eq(true, result.sha:match('^%x+$') ~= nil)
  end)

  it('warns without opening blame UI in a pure jj workspace', function()
    setup_jj_repo()
    setup_gitsigns(helpers.test_config)
    helpers.edit(scratch .. '/file.txt')
    wait_for_attach()

    local result = exec_lua(function()
      local async = require('gitsigns.async')
      local notifications = {}
      vim.notify = function(msg, level)
        notifications[#notifications + 1] = { msg, level }
      end

      local win_count = #vim.api.nvim_list_wins()
      local ok, err = pcall(function()
        async.run(require('gitsigns.actions.blame').blame):wait(5000)
      end)
      vim.wait(100, function()
        return #notifications > 0
      end)
      return {
        err = err,
        notification = notifications[1],
        ok = ok,
        opened_window = #vim.api.nvim_list_wins() ~= win_count,
      }
    end)

    eq(true, result.ok, result.err)
    eq(false, result.opened_window)
    eq(blame_unsupported, result.notification[1])
    eq(exec_lua('return vim.log.levels.WARN'), result.notification[2])
  end)

  it('rejects blame when Git HEAD does not match the selected jj parent', function()
    setup_jj_repo(true)
    setup_gitsigns(helpers.test_config)
    helpers.edit(scratch .. '/file.txt')
    wait_for_attach()

    local result = exec_lua(function()
      local async = require('gitsigns.async')
      local bcache = assert(require('gitsigns.cache').cache[vim.api.nvim_get_current_buf()])
      local repo = bcache.git_obj.repo
      local command0 = repo.command
      repo.command = function(self, args, spec)
        if args[1] == 'log' and args[2] == '--no-graph' then
          return { string.rep('0', 40) }, nil, 0
        end
        return command0(self, args, spec)
      end

      local notifications = {}
      vim.notify = function(msg)
        notifications[#notifications + 1] = msg
      end
      local win_count = #vim.api.nvim_list_wins()
      local ok, err = pcall(function()
        async.run(require('gitsigns.actions.blame_line'), { full = true }):wait(5000)
      end)
      vim.wait(100, function()
        return #notifications > 0
      end)
      return {
        err = err,
        notification = notifications[1],
        ok = ok,
        opened_window = #vim.api.nvim_list_wins() ~= win_count,
        popup = require('gitsigns.popup').is_open('blame'),
      }
    end)

    eq(true, result.ok, result.err)
    eq(false, result.opened_window)
    eq(nil, result.popup)
    eq(
      'Blame is unsupported in this Jujutsu workspace: Git HEAD does not match the jj working-copy parent',
      result.notification
    )
  end)
end)
