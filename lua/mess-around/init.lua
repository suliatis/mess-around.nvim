local M = {}

local Split = require 'nui.split'
local Tree = require 'nui.tree'
local Line = require 'nui.line'
local Path = require 'plenary.path'

function M.setup()
  vim.keymap.set('n', '<leader>a', function()
    M.open()
  end)
end

local state = {
  winid = nil,
  bufnr = nil,
}

local icons = {
  closed = '▸',
  opened = '▾',
}

local split_options = {
  relative = 'win',
  position = 'top',
  size = '50%',
  buf_options = {
    modifiable = true,
    readonly = false,
    filetype = 'qf',
  },
  win_options = {
    number = false,
    relativenumber = false,
  },
}

local function remove_buffer(bufnr)
  if bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr) then
    local success, err = pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    if not success and err:match 'E523' then
      vim.schedule_wrap(function()
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end)()
    end
  end
end

local function is_window_exists()
  local window_exists
  local winid = state.winid or 0
  local bufnr = state.bufnr or 0

  if winid < 1 then
    window_exists = false
  else
    window_exists = vim.api.nvim_win_is_valid(winid)
      and vim.api.nvim_win_get_number(winid) > 0
      and vim.api.nvim_win_get_buf(winid) == bufnr
  end

  -- TODO: separate cleaning state and checking if the window is still exists
  if not window_exists then
    remove_buffer(bufnr)
    state.winid = nil
    state.bufnr = nil
  end
  return window_exists
end

local severity_levels = {
  [1] = {
    name = 'Error',
    default_sign = 'E:',
    default_sign_hl = 'DiagnosticSignError',
  },
  [2] = {
    name = 'Warn',
    default_sign = 'W:',
    default_sign_hl = 'DiagnosticSignWarn',
  },
  [3] = {
    name = 'Info',
    default_sign = 'I:',
    default_sign_hl = 'DiagnosticSignInfo',
  },
  [4] = {
    name = 'Hint',
    default_sign = 'H:',
    default_sign_hl = 'DiagnosticSignHint',
  },
  -- TODO: don't forget to add the deprecated severity
}

local function get_severity_label(severity)
  -- TODO: handle different naming conventions, see trouble for more
  -- TODO: default or nil if severity is undefined
  return 'DiagnosticSign' .. severity_levels[severity].name
end

local function get_default_sign_for_severity(severity)
  return severity_levels[severity].name:sub(1, 1) .. ': '
end

local function get_diagnostic_sign(severity)
  -- TODO: use pcall to catch errors
  local label = get_severity_label(severity)
  local sign = vim.fn.sign_getdefined(label)[1]

  local sign_text = get_default_sign_for_severity(severity)
  if sign.text then
    sign_text = sign.text
  end

  local sign_hl = label
  if sign.text_hl then
    sign_hl = sign.text_hl
  end

  return sign_text, sign_hl
end

local function jump_to(in_win, diagnostic)
  -- save position in jump list
  vim.cmd 'normal! m\''

  vim.api.nvim_set_current_win(in_win)

  if not vim.bo[diagnostic.bufnr].buflisted then
    vim.bo[diagnostic.bufnr].buflisted = true
  end
  if not vim.api.nvim_buf_is_loaded(diagnostic.bufnr) then
    vim.fn.bufload(diagnostic.bufnr)
  end

  vim.api.nvim_set_current_buf(diagnostic.bufnr)
  vim.api.nvim_win_set_cursor(in_win, { diagnostic.lnum + 1, diagnostic.col })
end

local function get_diagnostics()
  local diagnostics = vim.diagnostic.get()
  for _, diagnostic in ipairs(diagnostics) do
    diagnostic.parent_id = 'bufnr:' .. diagnostic.bufnr
    diagnostic.id = 'pos:' .. diagnostic.lnum .. '_' .. diagnostic.col

    local sign, sign_hl = get_diagnostic_sign(diagnostic.severity)
    diagnostic.sign = sign
    diagnostic.sign_hl = sign_hl

    local file = vim.api.nvim_buf_get_name(diagnostic.bufnr)
    diagnostic.file = Path:new(file):make_relative()
  end

  table.sort(diagnostics, function(left, right)
    if left.file ~= right.file then
      return left.file < right.file
    end

    if left.lnum == right.lnum then
      return left.col < right.col
    end

    return left.lnum < right.lnum
  end)

  local grouped_diagnostics = {}
  for _, diagnostic in ipairs(diagnostics) do
    local group = grouped_diagnostics[diagnostic.bufnr]
    if group then
      table.insert(group, diagnostic)
    else
      table.insert(grouped_diagnostics, diagnostic.bufnr, { diagnostic })
    end
  end

  local nodes = {}
  for _, group in pairs(grouped_diagnostics) do
    local diagnostic_nodes = {}
    for _, diagnostic in ipairs(group) do
      table.insert(diagnostic_nodes, Tree.Node(diagnostic))
    end

    table.insert(
      nodes,
      Tree.Node({
        file = group[1].file,
        id = 'bufnr:' .. group[1].bufnr,
      }, diagnostic_nodes)
    )
  end

  return nodes
end

local function display_file_path(path)
  local file_name = vim.fn.fnamemodify(path, ':t')
  local path_to_file = vim.fn.fnamemodify(path, ':h')

  if file_name == 'init.lua' then
    local parent = vim.fn.fnamemodify(path, ':h:t')
    file_name = parent .. '/' .. file_name
    path_to_file = vim.fn.fnamemodify(path_to_file, ':h')
  end

  if path_to_file == '.' then
    return file_name
  end

  return string.format('%s - %s', file_name, path_to_file)
end

local function get_ids_of_expanded_nodes(tree)
  -- TODO: only works for nodes right below the root, implement a recursive filter
  local ids_of_expanded_nodes = {}

  for _, node in ipairs(tree:get_nodes()) do
    if node:is_expanded() then
      table.insert(ids_of_expanded_nodes, node:get_id())
    end
  end

  return ids_of_expanded_nodes
end

local function expand_all(tree, ids)
  for _, node in ipairs(tree:get_nodes()) do
    for _, id in ipairs(ids) do
      if node:get_id() == id then
        node:expand()
      end
    end
  end
end

local function refresh(tree)
  local ids_of_expanded = get_ids_of_expanded_nodes(tree)
  tree:set_nodes(get_diagnostics())
  expand_all(tree, ids_of_expanded)
  tree:render()
end

function M.open()
  if is_window_exists() then
    return
  end

  local from_winid = vim.api.nvim_get_current_win()

  local split = Split(split_options)
  split:mount()

  state.winid = split.winid
  state.bufnr = split.bufnr

  local title = Line()
  title:append('DIAGNOSTICS', 'Title')
  title:render(split.bufnr, -1, 1)

  local blank = Line()
  blank:render(split.bufnr, -1, 2)

  local tree = Tree {
    winid = split.winid,
    nodes = get_diagnostics(),
    prepare_node = function(node)
      local line = Line()

      line:append(string.rep(' ', node:get_depth() - 1))

      if node:has_children() then
        line:append(node:is_expanded() and icons.opened or icons.closed)
        line:append ' '
        line:append(display_file_path(node.file))
      else
        line:append(node.sign, node.sign_hl)
        line:append(node.message)
        line:append(' [' .. node.lnum .. ', ' .. node.col .. ']')
      end

      return line
    end,
  }
  tree:render(3)

  split:map('n', '=', function()
    local node = tree:get_node()

    if node:collapse() then
      tree:render()
      return
    end

    if node:expand() then
      tree:render()
      return
    end
  end)

  split:map('n', 'r', function()
    refresh(tree)
  end)

  split:map('n', '<CR>', function()
    local node = tree:get_node()
    if node:has_children() then
      -- TODO implement jump to file instead or first diagnostic in file
      return
    end

    jump_to(from_winid, node)
  end)

  vim.api.nvim_create_autocmd('DiagnosticChanged', {
    group = vim.api.nvim_create_augroup('BorzDiagnosticChanged', {
      clear = true,
    }),
    callback = function()
      if is_window_exists() then
        refresh(tree)
      end
    end,
  })
end

return M
