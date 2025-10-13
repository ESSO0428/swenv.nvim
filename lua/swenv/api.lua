local M = {}

local Path = require('plenary.path')
local scan_dir = require('plenary.scandir').scan_dir
local best_match = require('swenv.match').best_match
local read_venv_name = require('swenv.project').read_venv_name

local settings = require('swenv.config').settings

local ORIGINAL_PATH = vim.fn.getenv('PATH')

local current_venv = nil

local update_path = function(path)
  vim.fn.setenv('PATH', path .. '/bin' .. ':' .. ORIGINAL_PATH)
end

local set_venv = function(venv)
  if venv.source == 'conda' then
    vim.fn.setenv('CONDA_PREFIX', venv.path)
    vim.fn.setenv('CONDA_DEFAULT_ENV', venv.name)
    vim.fn.setenv('CONDA_PROMPT_MODIFIER', '(' .. venv.name .. ')')
  else
    vim.fn.setenv('VIRTUAL_ENV', venv.path)
    update_path(venv.path)
  end

  current_venv = venv
  -- TODO: remove old path
  update_path(venv.path)

  if settings.post_set_venv then
    settings.post_set_venv(venv)
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
  -- vim.list_extend(venvs, get_venvs_for(get_conda_base_path(), 'conda'))
  vim.list_extend(venvs, get_venvs_for(get_pyenv_base_path(), 'pyenv'))
  vim.list_extend(venvs, get_venvs_for(get_pyenv_base_path(), 'pyenv', { only_dirs = false }))
  return venvs
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
    local project_venv_name = read_venv_name(project_dir)
    if not project_venv_name then
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
