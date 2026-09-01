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

  it('lists added and deleted files in quickfix and rejects modifying actions', function()
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
end)
