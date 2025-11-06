local M = {}

local Path = require('plenary.path')
local scan_dir = require('plenary.scandir').scan_dir
local best_match = require('swenv.match').best_match
local read_venv_name = require('swenv.project').read_venv_name

local settings = require('swenv.config').settings

local ORIGINAL_PATH = vim.fn.getenv('PATH')

local current_venv = nil

local function is_venv_dir(dir)
  local p = Path:new(dir)
  return
      p:joinpath('pyvenv.cfg'):exists()
end

local function dedup_by_path(list)
  local seen, out = {}, {}
  for _, v in ipairs(list) do
    if v.path and not seen[v.path] then
      seen[v.path] = true
      table.insert(out, v)
    end
  end
  return out
end

---- load prompt of pyvenv.cfg
local function read_pyvenv_prompt(dir)
  local cfg = tostring(Path:new(dir):joinpath('pyvenv.cfg'))
  local f = io.open(cfg, "r")
  if not f then return nil end
  for line in f:lines() do
    local key, value = line:match("^%s*(%w+)%s*=%s*(.+)%s*$")
    if key == "prompt" then
      f:close()
      return vim.trim(value)
    end
  end
  f:close()
  return nil
end

local function find_local_venvs(start_dir)
  local venvs, seen = {}, {}
  local function push(dir_path, display_name)
    if seen[dir_path] then return end
    if not is_venv_dir(dir_path) then return end

    -- load  prompt of pyvenv.cfg or use .venv dir name
    local name = read_pyvenv_prompt(dir_path)
        or display_name
        or vim.fs.basename(dir_path)

    table.insert(venvs, { name = name, path = dir_path, source = 'local' })
    seen[dir_path] = true
  end

  local cur = Path:new(start_dir or vim.loop.cwd())
  for _, dir in ipairs(scan_dir(tostring(cur), { depth = 1, only_dirs = true, hidden = true, silent = true })) do
    local venv_dir_name = vim.fs.basename(dir)
    push(dir, venv_dir_name)
  end
  return venvs
end

local update_path = function(path)
  vim.fn.setenv('PATH', path .. '/bin' .. ':' .. ORIGINAL_PATH)
end

local set_venv = function(venv)
  if not venv or not venv.path then
    return
  end

  local venv_path = tostring(venv.path)
  local venv_name = venv.name or vim.fs.basename(venv_path)

  if venv.source == 'conda' then
    -- Switch to conda environment
    vim.fn.setenv('CONDA_PREFIX', venv_path)
    vim.fn.setenv('CONDA_DEFAULT_ENV', venv_name)
    vim.fn.setenv('CONDA_PROMPT_MODIFIER', '(' .. venv_name .. ')')
    vim.fn.setenv('CONDA_SHLVL', 1)

    -- Clear venv but don't use nil to avoid unexpected behavior in some plugins/scripts
    vim.fn.setenv('VIRTUAL_ENV', '')

    update_path(venv_path)
  else
    -- Switch to venv / local / pyenv
    vim.fn.setenv('VIRTUAL_ENV', venv_path)

    -- Keep conda in stable state: return to base (if conda detected), otherwise set to empty string
    local conda_exe = vim.fn.getenv('CONDA_EXE')
    if conda_exe ~= vim.NIL and conda_exe ~= '' then
      local base = tostring(Path:new(conda_exe):parent():parent())
      vim.fn.setenv('CONDA_PREFIX', base)
      vim.fn.setenv('CONDA_DEFAULT_ENV', 'base')
    else
      vim.fn.setenv('CONDA_PREFIX', '')
      vim.fn.setenv('CONDA_DEFAULT_ENV', '')
    end
    vim.fn.setenv('CONDA_SHLVL', 0)
    vim.fn.setenv('CONDA_PROMPT_MODIFIER', '')

    update_path(venv_path)
  end

  current_venv = {
    name = venv_name,
    path = venv_path,
    source = venv.source,
  }

  if settings.post_set_venv then
    -- Don't let post_set_venv errors interrupt the entire switching process
    pcall(settings.post_set_venv, current_venv)
  end
end

local normalize_env = function(value)
  if value == vim.NIL or value == '' then
    return nil
  end
  return value
end

local safe_find = function(target)
  if not target then
    return nil
  end
  return string.find(ORIGINAL_PATH, target, 1, true)
end

---
---Checks who appears first in PATH. Returns `true` if `first` appears first and `false` otherwise
---
---@param first string|nil
---@param second string|nil
---@return boolean
local has_high_priority_in_path = function(first, second)
  first = normalize_env(first)
  second = normalize_env(second)

  local first_idx = safe_find(first)
  if not first_idx then
    return false
  end

  local second_idx = safe_find(second)
  if not second_idx then
    return true
  end

  return first_idx < second_idx
end


M.init = function()
  local venv

  local venv_env = vim.fn.getenv('VIRTUAL_ENV')
  if venv_env ~= vim.NIL then
    venv = {
      name = Path:new(venv_env):make_relative(settings.venvs_path),
      path = venv_env,
      source = 'venv',
    }
  end

  local conda_env = vim.fn.getenv('CONDA_DEFAULT_ENV')
  if conda_env ~= vim.NIL and has_high_priority_in_path(conda_env, venv_env) then
    venv = {
      name = conda_env,
      path = vim.fn.getenv('CONDA_PREFIX'),
      source = 'conda',
    }
  end

  if venv then
    current_venv = venv
  end
end

M.get_current_venv = function()
  return current_venv
end

local get_venvs_for = function(base_path, source, opts)
  local venvs = {}
  if base_path == nil then
    return venvs
  end
  local paths = scan_dir(base_path, vim.tbl_extend('force', { depth = 1, only_dirs = true, silent = true }, opts or {}))
  for _, path in ipairs(paths) do
    table.insert(venvs, {
      name = Path:new(path):make_relative(base_path),
      path = path,
      source = source,
    })
  end
  return venvs
end

local get_conda_base_path = function()
  local conda_exe = vim.fn.getenv('CONDA_EXE')
  if conda_exe == vim.NIL then
    return nil
  else
    local envs_path = Path:new(conda_exe):parent():parent() .. '/envs'
    local base_path = Path:new(conda_exe):parent():parent()
    return { envs_path, base_path }
  end
end

local get_pyenv_base_path = function()
  local pyenv_root = vim.fn.getenv('PYENV_ROOT')
  if pyenv_root == vim.NIL then
    return nil
  else
    return Path:new(pyenv_root) .. '/versions'
  end
end

M.get_venvs = function(venvs_path)
  local venvs = {}

  -- 1) Search upward from project/path for .venv / venv (newly added)
  local project_root = nil
  local ok, project_mod = pcall(require, 'project_nvim.project')
  if ok then
    project_root = select(1, project_mod.get_project_root())
  end
  if project_root then
    vim.list_extend(venvs, find_local_venvs(project_root))
  end
  -- Also add local venv from current working directory (in case project root was not detected)
  vim.list_extend(venvs, find_local_venvs(vim.loop.cwd()))

  -- 2) Existing sources
  vim.list_extend(venvs, get_venvs_for(venvs_path, 'venv'))

  local conda_paths = get_conda_base_path()
  if conda_paths then
    local other_env_path = conda_paths[1]
    local base_env_path = conda_paths[2]
    base_env_path = tostring(Path:new(base_env_path))
    local base_env_path_table = {
      name = "base",
      path = base_env_path,
      source = "conda"
    }
    table.insert(venvs, base_env_path_table)
    vim.list_extend(venvs, get_venvs_for(other_env_path, 'conda'))
  end

  vim.list_extend(venvs, get_venvs_for(get_pyenv_base_path(), 'pyenv'))
  vim.list_extend(venvs, get_venvs_for(get_pyenv_base_path(), 'pyenv', { only_dirs = false }))

  -- de duplicate by path
  return dedup_by_path(venvs)
end

M.pick_venv = function()
  vim.ui.select(settings.get_venvs(settings.venvs_path), {
    prompt = 'Select python venv',
    format_item = function(item)
      return string.format('%s (%s) [%s]', item.name, item.path, item.source)
    end,
  }, function(choice)
    if not choice then
      return
    end
    set_venv(choice)
  end)
end

M.set_venv = function(name)
  local venvs = settings.get_venvs(settings.venvs_path)
  local closest_match = best_match(venvs, name)
  if not closest_match then
    return
  end
  set_venv(closest_match)
end

M.auto_venv = function()
  local loaded, project_nvim = pcall(require, 'project_nvim.project')
  local venvs = settings.get_venvs(settings.venvs_path)
  if not loaded then
    print('Error: failed to load the project_nvim.project module')
    return
  end

  local project_dir, _ = project_nvim.get_project_root()
  if project_dir then -- project_nvim.get_project_root might not always return a project path
    -- First, use swenv's name matching
    local project_venv_name = read_venv_name(project_dir)
    -- Not found swenv's name matching, prioritize using .<venv_dir>/pyvenv.cfg within the project (newly added)
    if not project_venv_name then
      local locals = find_local_venvs(project_dir)
      if #locals > 0 then
        set_venv(locals[1])
      end
      return
    end
    local closest_match = best_match(venvs, project_venv_name)
    if not closest_match then
      return
    end
    set_venv(closest_match)
  end
end

return M
