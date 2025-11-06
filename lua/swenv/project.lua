local M = {}

-- Get the name from a `.venv` file in the project root directory.
M.read_venv_name = function(project_dir)
  local abs_venv_path = project_dir .. '/.venv'
  local file = io.open(abs_venv_path, 'r') -- r read mode
  if not file then
    return nil
  end
  local pyenv_cfg = io.open(abs_venv_path .. '/pyvenv.cfg')
  if not pyenv_cfg then
    return nil
  end
  for line in pyenv_cfg:lines() do
    local match = line:match('^prompt%s*=%s*(.*)')
    if match then
      local env_name = match
      pyenv_cfg:close()
      return env_name
    end
  end
end

return M
