--[[
  modules/hot_reload.lua — safe module hot-swap with rollback.

  Every module loaded through this system is:
    1. Tracked in a registry keyed by name
    2. Reloadable at runtime via hot_reload.reload(name)
    3. Protected by pcall — a broken reload rolls back to the last good version
    4. Validated against a function contract — a rewrite that drops required
       public functions is rejected and rolled back before it goes live

  Contract for reloadable modules:
    - Must return a plain table (no globals, no side effects at load time)
    - Module name == filename without path or .lua extension
      e.g.  modules/prompts.lua  →  name "prompts"
]]

local M = {}

-- Internal registry: name → { mod=table, path=string, source=string }
local _registry = {}

-- ---------------------------------------------------------------------------
-- Module contracts — required public functions for each known module.
-- A rewrite that omits any listed function is rejected with a clear error.
-- Add entries here when new public APIs are established.
-- ---------------------------------------------------------------------------
local CONTRACTS = {
  prompts = {
    "build_task_prompt", "build_fix_prompt", "build_self_improve_prompt",
    "build_query_prompt", "build_classify_prompt", "get_nudge",
  },
  opencode = {
    "run_fresh", "run_continue", "run_classify", "log_says_done",
  },
  compile = {
    "run_compile_check", "read_errors", "read_errors_raw",
  },
  session = {
    "get_project_version", "handle_session_archive", "ensure_state_files",
    "scaffold_project_dirs", "select_model", "append_progress",
  },
  self_improve = {
    "run_targeted", "run_proactive", "suggest_kernel_improvements",
  },
  hot_reload = {
    "load", "reload", "get", "source", "list", "write_and_reload",
  },
  tool_registry = {
    "bootstrap", "register", "describe_tools", "process_tool_calls",
  },
  project_type = {
    "resolve", "get_extensions", "get_tech", "get_src_dirs",
  },
  git_utils = {
    "git", "is_git_repo", "ensure_git_repo", "ensure_branch",
    "git_commit", "snapshot_files", "files_changed_since",
  },
  todo_parser = {
    "parse_sections", "parse_subsections", "parse_tasks",
    "mark_task_done", "build_section_context",
    "select_section", "select_tasks",
  },
  logging = {
    "log", "ok", "warn", "err", "header", "step",
  },
}

-- ---------------------------------------------------------------------------
-- check_contract — verify a loaded module table exports all required functions.
-- Returns nil on pass, or an error string listing what is missing/wrong.
-- ---------------------------------------------------------------------------
local function check_contract(name, mod)
  local required = CONTRACTS[name]
  if not required then return nil end  -- no contract defined — pass

  local missing = {}
  for _, fn_name in ipairs(required) do
    if type(mod[fn_name]) ~= "function" then
      missing[#missing+1] = fn_name
    end
  end

  if #missing > 0 then
    return "contract violation — missing functions: " .. table.concat(missing, ", ")
  end
  return nil
end

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

  -- Contract check: reject rewrites that drop required public functions
  local contract_err = check_contract(name, result)
  if contract_err then
    package.loaded[name] = nil
    package.loaded[name] = entry.mod
    return nil, "reload rejected (rolled back): " .. contract_err
  end

  -- validate() hook: module may export an optional M.validate() that checks
  -- its own dependencies (e.g. that sibling modules export expected functions).
  -- This catches rewrites that call non-existent APIs on other modules.
  if type(result.validate) == "function" then
    local vok, verr = pcall(result.validate)
    if not vok or verr then
      package.loaded[name] = nil
      package.loaded[name] = entry.mod
      local msg = (not vok) and tostring(verr) or tostring(verr)
      return nil, "reload rejected — validate() failed (rolled back): " .. msg
    end
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

  -- ── Stage 1: write to temp file ────────────────────────────────────────
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false, "cannot write temp file: " .. tmp end
  f:write(new_source); f:close()

  -- ── Stage 2: loadfile syntax/parse check (fast, pure Lua) ──────────────
  -- Catches: syntax errors, malformed control structures, bad escape sequences.
  -- Does NOT execute top-level code, so require() calls are not resolved here.
  local chunk, load_err = loadfile(tmp)
  if not chunk then
    os.remove(tmp)
    return false, "syntax error (loadfile): " .. tostring(load_err)
  end

  -- ── Stage 3: luac -p full compilation check (catches more than loadfile) ──
  -- luac validates: upvalue counts, constant folding, jump targets.
  -- Falls back silently if luac is not installed (loadfile already caught
  -- the common cases).
  local luac_handle = io.popen(string.format('luac -p "%s" 2>&1', tmp))
  if luac_handle then
    local luac_out = luac_handle:read("*a") or ""
    luac_handle:close()
    if luac_out:match("%S") then
      -- luac reported at least one error/warning line
      os.remove(tmp)
      return false, "syntax error (luac): " .. luac_out:gsub("%s+$", "")
    end
  end

  -- ── Stage 4: back up current file before overwriting ───────────────────
  local bak = path .. ".bak"
  local bak_f = io.open(path, "r")
  if bak_f then
    local old = bak_f:read("*a"); bak_f:close()
    local wbak = io.open(bak, "w")
    if wbak then wbak:write(old); wbak:close() end
  end

  -- ── Stage 5: atomic-ish write (rename tmp → path) ──────────────────────
  -- os.rename is atomic on POSIX when src/dst are on the same filesystem.
  local renamed = os.rename(tmp, path)
  if not renamed then
    -- Fallback: copy-then-delete (cross-device or Windows)
    local fw = io.open(path, "w")
    if not fw then os.remove(tmp); return false, "cannot write: " .. path end
    fw:write(new_source); fw:close()
    os.remove(tmp)
  end

  -- ── Stage 6: hot-reload with contract + validate() checks ──────────────
  local new_mod, reload_err = M.reload(name)
  if not new_mod then
    -- Restore from backup
    local rb = io.open(bak, "r")
    if rb then
      local old = rb:read("*a"); rb:close()
      local fw = io.open(path, "w")
      if fw then fw:write(old); fw:close() end
    end
    return false, reload_err
  end

  return true, nil
end

return M
