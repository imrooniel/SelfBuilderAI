--[[
  modules/hot_reload.lua — safe module hot-swap with rollback.

  Every module loaded through this system is:
    1. Tracked in a registry keyed by name
    2. Reloadable at runtime via hot_reload.reload(name)
    3. Protected by pcall — a broken reload rolls back to the last good version

  Contract for reloadable modules:
    - Must return a plain table (no globals, no side effects at load time)
    - Module name == filename without path or .lua extension
      e.g.  modules/prompts.lua  →  name "prompts"
]]

local M = {}

-- Internal registry: name → { mod=table, path=string, source=string }
local _registry = {}

-- ---------------------------------------------------------------------------
-- Resolve a module name to its file path
-- ---------------------------------------------------------------------------
local function resolve_path(name)
  for template in package.path:gmatch("[^;]+") do
    local path = template:gsub("%?", name)
    local f = io.open(path, "r")
    if f then f:close(); return path end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Load (first time) — wraps require() and registers the module
-- ---------------------------------------------------------------------------
function M.load(name)
  if _registry[name] then
    return _registry[name].mod, nil
  end

  local path = resolve_path(name)
  if not path then
    return nil, "module file not found for: " .. name
  end

  local ok, result = pcall(require, name)
  if not ok then
    return nil, result
  end

  local source = ""
  local f = io.open(path, "r")
  if f then source = f:read("*a"); f:close() end

  _registry[name] = { mod = result, path = path, source = source }
  return result, nil
end

-- ---------------------------------------------------------------------------
-- Reload — evict from package.loaded, re-require, rollback on failure
-- ---------------------------------------------------------------------------
function M.reload(name)
  local entry = _registry[name]
  if not entry then
    return M.load(name)
  end

  local path = entry.path

  local new_source = ""
  local f = io.open(path, "r")
  if f then new_source = f:read("*a"); f:close() end

  -- Clear the loader cache so require() will re-execute the file
  package.loaded[name] = nil

  local ok, result = pcall(require, name)
  if not ok then
    -- Rollback: clear any broken partial table Lua may have cached during the
    -- failed load, then restore the known-good module so future require() calls
    -- return the working version.
    package.loaded[name] = nil
    package.loaded[name] = entry.mod
    return nil, "reload failed (rolled back): " .. tostring(result)
  end

  _registry[name] = { mod = result, path = path, source = new_source }
  return result, nil
end

-- ---------------------------------------------------------------------------
-- get — retrieve the current live module table from the registry
-- ---------------------------------------------------------------------------
function M.get(name)
  local entry = _registry[name]
  return entry and entry.mod or nil
end

-- ---------------------------------------------------------------------------
-- source — return the source text of a registered module
-- ---------------------------------------------------------------------------
function M.source(name)
  local entry = _registry[name]
  return entry and entry.source or nil
end

-- ---------------------------------------------------------------------------
-- list — return list of all registered module names
-- ---------------------------------------------------------------------------
function M.list()
  local names = {}
  for k in pairs(_registry) do names[#names+1] = k end
  table.sort(names)
  return names
end

-- ---------------------------------------------------------------------------
-- write_and_reload — write new source to disk, then hot-reload.
-- Returns true on success, false + err_msg on failure.
-- ---------------------------------------------------------------------------
function M.write_and_reload(name, new_source)
  local entry = _registry[name]
  if not entry then
    return false, "module not registered: " .. name
  end

  local path = entry.path

  -- Validate syntax via temp file
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false, "cannot write temp file: " .. tmp end
  f:write(new_source); f:close()

  -- Validate syntax via temp file.
  -- NOTE: loadfile only catches parse/syntax errors. A module with a runtime
  -- error at the top level (e.g. a bad require()) will pass this check and then
  -- fail during reload below, which triggers the rollback path correctly.
  local chunk, load_err = loadfile(tmp)
  if not chunk then
    os.remove(tmp)
    return false, "syntax/load error in new source: " .. tostring(load_err)
  end

  local fw = io.open(path, "w")
  if not fw then os.remove(tmp); return false, "cannot write: " .. path end
  fw:write(new_source); fw:close()
  os.remove(tmp)

  local new_mod, reload_err = M.reload(name)
  if not new_mod then
    local fb = io.open(path, "w")
    if fb then fb:write(entry.source); fb:close() end
    return false, reload_err
  end

  return true, nil
end

return M
