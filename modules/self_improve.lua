--[[
  modules/self_improve.lua — AI self-improvement orchestration.
  AI-rewritable (but be careful — this module rewrites other modules).

  Three entry points:

  1. run_targeted(model, reason, context)
       Called after a task failure or persistent compile errors.

  2. run_proactive(model, session_summary)
       Called once at the end of every session.

  3. suggest_kernel_improvements(model, context)
       Called after a task failure. Appends to KERNEL_SUGGESTIONS.md only.
       Never writes run_automation.lua.
]]

local M = {}

local cfg        = require("config")
local logging    = require("logging")
local hot_reload = require("hot_reload")
local opencode   = require("opencode")
local prompts    = require("prompts")

-- ---------------------------------------------------------------------------
-- Helper: resolve the orchestrator's modules directory.
-- Prefer the kernel global set by run_automation.lua; fall back to deriving
-- it from package.path so the module works in test contexts too.
-- ---------------------------------------------------------------------------
local function modules_dir()
  if _G.KERNEL_MODULES_DIR then return _G.KERNEL_MODULES_DIR end
  -- Derive from package.path: find the first template that resolves a known module
  for template in package.path:gmatch("[^;]+") do
    local candidate = template:gsub("%?", "config")
    local fh = io.open(candidate, "r")
    if fh then
      fh:close()
      -- Strip "config.lua" to get the directory
      return candidate:match("(.+)/config%.lua$") or "."
    end
  end
  return "."
end

local function module_path(mod_name)
  return modules_dir() .. "/" .. mod_name .. ".lua"
end

-- ---------------------------------------------------------------------------
-- Helper: read a file
-- ---------------------------------------------------------------------------
local function read_file(path)
  local f = io.open(path, "r")
  if not f then return "(file not found: " .. path .. ")" end
  local s = f:read("*a"); f:close()
  return s
end

local function read_progress()
  return read_file(cfg.PROJECT_PATH .. "/" .. cfg.PROGRESS_FILE)
end

-- ---------------------------------------------------------------------------
-- Helper: validate Lua syntax via luac (preferred) or loadstring fallback.
-- Returns nil on success, error string on failure.
-- ---------------------------------------------------------------------------
local function check_lua_syntax(source, label)
  -- Strategy 1: luac -p (catches more than loadstring — detects upvalue issues etc.)
  local tmp = os.tmpname() .. ".lua"
  local f = io.open(tmp, "w")
  if f then
    f:write(source); f:close()
    local handle = io.popen(string.format('luac -p "%s" 2>&1', tmp))
    local out = handle and handle:read("*a") or ""
    if handle then handle:close() end
    os.remove(tmp)
    if out:match("%S") then
      -- luac found errors
      return "luac: " .. out:gsub("%s+$", "")
    end
    return nil   -- clean
  end

  -- Strategy 2: loadstring fallback (luac unavailable)
  local chunk, err = load(source, label or "rewrite")
  if not chunk then
    return "syntax: " .. tostring(err)
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Helper: extract Lua source from a completed opencode log.
--
-- Extraction order (most → least reliable):
--   1. Fenced block:  ```lua … ``` (proactive prompt uses this format)
--   2. Marker block:  REWRITE_MODULE: name … END_REWRITE  (same format)
--   3. Bare source:   first --[[ or "-- " header through last "return M"
--      This is the targeted-pass format (model returns raw Lua).
--
-- After extraction the source is validated:
--   • Must contain "return M" (basic module shape)
--   • Must pass luac -p / loadstring syntax check
-- ---------------------------------------------------------------------------
local function extract_lua_source(log_content, mod_name)
  local source = nil

  -- 1. Fenced ```lua block (look for the LAST occurrence so we skip preamble)
  local last_fence = nil
  for block in log_content:gmatch("```lua\n(.-)\n```") do
    last_fence = block
  end
  if last_fence and last_fence:find("return%s+M") then
    source = last_fence
  end

  -- 2. REWRITE_MODULE marker block (mod_name optional — take the last one)
  if not source then
    local pattern = mod_name
      and ("REWRITE_MODULE:%s*" .. mod_name .. "%s*\n```lua\n(.-)\n```\nEND_REWRITE")
      or  "REWRITE_MODULE:%s*[%w_]+%s*\n```lua\n(.-)\n```\nEND_REWRITE"
    local last_marker = nil
    for block in log_content:gmatch(pattern) do last_marker = block end
    if last_marker and last_marker:find("return%s+M") then
      source = last_marker
    end
  end

  -- 3. Bare-source fallback: header comment → last "return M"
  if not source then
    local lines = {}
    for line in (log_content .. "\n"):gmatch("([^\n]*)\n") do
      lines[#lines+1] = line
    end
    local start_idx, end_idx = nil, nil
    for i, line in ipairs(lines) do
      if not start_idx and (line:match("^%-%-%[%[") or line:match("^%-%-%s+modules/")) then
        start_idx = i
      end
      if line:match("^return%s+M%s*$") then
        end_idx = i   -- keep updating → last occurrence
      end
    end
    if start_idx and end_idx and end_idx > start_idx then
      local extracted = {}
      for i = start_idx, end_idx do extracted[#extracted+1] = lines[i] end
      local candidate = table.concat(extracted, "\n")
      -- Sanity: candidate must be at least 100 chars (not a stub)
      if #candidate >= 100 then source = candidate end
    end
  end

  if not source then
    logging.warn(string.format("[self_improve] %s: could not extract Lua source from log.", mod_name or "?"))
    return nil
  end

  -- Structural checks (cheap, before the luac call)
  if not source:find("return%s+M") then
    logging.warn(string.format("[self_improve] %s: extracted source missing 'return M'.", mod_name or "?"))
    return nil
  end
  if #source < 100 then
    logging.warn(string.format("[self_improve] %s: extracted source suspiciously short (%d chars).", mod_name or "?", #source))
    return nil
  end

  -- Syntax check
  local syn_err = check_lua_syntax(source, mod_name)
  if syn_err then
    logging.warn(string.format("[self_improve] %s: syntax check FAILED — %s", mod_name or "?", syn_err))
    return nil
  end

  logging.log(string.format("[self_improve] %s: extracted %d bytes, syntax OK.", mod_name or "?", #source))
  return source
end

-- ---------------------------------------------------------------------------
-- Helper: run an improvement call and extract Lua source from log
-- ---------------------------------------------------------------------------
local function run_improve_call(model, prompt, log_path, mod_name)
  local f = io.open(log_path, "w"); if f then f:close() end
  opencode.run_fresh(log_path, prompt, model)
  local log_content = read_file(log_path)
  return extract_lua_source(log_content, mod_name)
end

-- ---------------------------------------------------------------------------
-- Helper: attempt to apply a rewritten module
-- ---------------------------------------------------------------------------
local function apply_rewrite(mod_name, new_source, reason)
  if not new_source or new_source:match("^%s*$") then
    logging.warn(string.format("[self_improve] %s: AI returned empty source — skipping.", mod_name))
    return false
  end

  -- Syntax must be clean before we touch disk (extract_lua_source already
  -- checks, but run_proactive feeds source directly here so check again).
  local syn_err = check_lua_syntax(new_source, mod_name)
  if syn_err then
    logging.warn(string.format("[self_improve] %s: apply_rewrite syntax gate FAILED — %s", mod_name, syn_err))
    return false
  end

  logging.log(string.format("[self_improve] Applying rewrite to %s (%s)...", mod_name, reason))
  local ok, err = hot_reload.write_and_reload(mod_name, new_source)
  if ok then
    logging.ok(string.format("[self_improve] %s successfully rewritten and hot-reloaded.", mod_name))
    os.execute(string.format(
      'cd "%s" && git add -A && git commit -m "self-improve: rewrite %s [%s]" 2>/dev/null',
      cfg.PROJECT_PATH, mod_name, reason))
    return true
  else
    logging.warn(string.format("[self_improve] %s rewrite FAILED (rolled back): %s", mod_name, err))
    return false
  end
end

-- ---------------------------------------------------------------------------
-- Targeted improvement — called after task failure or compile errors
-- ---------------------------------------------------------------------------
function M.run_targeted(model, reason, context)
  if not cfg.SELF_IMPROVE_ENABLED or not cfg.SELF_IMPROVE_TARGETED then
    logging.log("[self_improve] Targeted pass disabled in config — skipping.")
    return
  end

  logging.log("[self_improve] Targeted pass — reason: " .. reason)

  -- Decide which modules are most relevant to the failure
  local targets = {}
  if context.target_override then
    -- Caller specified exact module(s) — honour it directly
    targets = context.target_override
  elseif reason == "user_request" then
    -- User typed something like "improve yourself" with no specific module.
    -- Default to the two highest-value modules for general improvement.
    targets = { "prompts", "self_improve" }
  elseif reason == "task_failure" then
    targets = { "prompts", "opencode" }
    if (context.iterations or 0) >= 3 then
      targets[#targets+1] = "session"
    end
  elseif reason == "compile_failure" then
    targets = { "compile", "prompts" }
  elseif reason == "project_type" then
    targets = { "project_type", "compile" }
  else
    targets = { "prompts" }
  end

  local progress = read_progress()
  local run_ts   = os.date("%Y%m%d-%H%M%S")

  for _, mod_name in ipairs(targets) do
    -- Prefer the live source tracked by hot_reload; fall back to reading from
    -- disk by resolving through package.path (same mechanism hot_reload uses).
    local current_source = hot_reload.source(mod_name)
    if not current_source then
      for template in package.path:gmatch("[^;]+") do
        local candidate = template:gsub("%?", mod_name)
        local fh = io.open(candidate, "r")
        if fh then
          current_source = fh:read("*a"); fh:close()
          break
        end
      end
    end
    current_source = current_source or "(source not found)"

    local prompt_text = prompts.build_self_improve_prompt({
      mod_name       = mod_name,
      mod_path       = module_path(mod_name),
      current_source = current_source,
      reason         = reason,
      context_str    = tostring(context.task_num or "") .. ": " ..
                       tostring(context.task_text or "") .. " — " ..
                       tostring(context.prior_note or ""),
      progress       = progress,
    })

    os.execute('mkdir -p "' .. cfg.PROJECT_PATH .. '/logs"')
    local log_path = string.format("%s/logs/self-improve-%s-%s-%s.log",
      cfg.PROJECT_PATH, mod_name, reason, run_ts)

    local new_source = run_improve_call(model, prompt_text, log_path, mod_name)
    apply_rewrite(mod_name, new_source, reason)
  end
end

-- ---------------------------------------------------------------------------
-- Proactive end-of-session improvement pass
-- ---------------------------------------------------------------------------
function M.run_proactive(model, session_summary)
  if not cfg.SELF_IMPROVE_ENABLED or not cfg.SELF_IMPROVE_PROACTIVE then
    logging.log("[self_improve] Proactive pass disabled in config — skipping.")
    return
  end

  logging.log("[self_improve] Proactive session-end pass...")

  local progress     = read_progress()
  local module_names = hot_reload.list()
  local run_ts       = os.date("%Y%m%d-%H%M%S")

  local sources_block = {}
  for _, name in ipairs(module_names) do
    local src  = hot_reload.source(name) or ""
    local path = module_path(name)
    sources_block[#sources_block+1] = string.format(
      "=== %s ===\nPath: %s\n%s\n", name, path, src:sub(1, 3000))
  end

  local mdir = modules_dir()

  local user_note = session_summary.user_request
    and ("User request: " .. session_summary.user_request .. "\n")
    or  ""

  local prompt = string.format([[
You are an expert Lua developer improving a programming automation orchestration system.
This is %s.

## IMPORTANT — file locations
This is an orchestration system, NOT the project being built.
Module files are in: %s
Entry point: %s
Do NOT look in src/, scripts/, or PROJECT_PATH for these files.
Each module block below includes its exact path.

## Session summary
%sTasks done   : %d
Tasks failed : %d
Failed tasks : %s
Project type : %s

## Recent progress
%s

## All module sources
%s

## Your task
Review the session results and module sources.
Choose UP TO 2 modules that would most benefit from improvement.
For each module you choose to rewrite, output a block in this exact format:

REWRITE_MODULE: <module_name>
```lua
<complete new Lua source>
```
END_REWRITE

Rules:
  1. Only output REWRITE_MODULE blocks for modules you are actually improving.
  2. Each module source must be complete, valid Lua 5.4, returning table M.
  3. Do not remove functionality — only improve.
  4. Keep all existing function signatures compatible.
  5. Only call functions that actually exist on required modules.
     NEVER invent function names (e.g. opencode.run_targeted does not exist —
     only run_fresh, run_continue, run_classify, log_says_done exist).
  6. Each rewritten module MUST include a M.validate() function that asserts
     the external module functions it calls actually exist. Example:
       function M.validate()
         local oc = require("opencode")
         assert(type(oc.run_fresh) == "function", "opencode.run_fresh missing")
       end
  7. If no improvements are warranted, output: NO_IMPROVEMENTS_NEEDED

After all rewrites (or NO_IMPROVEMENTS_NEEDED), output: DONE
]],
    session_summary.user_request and "a user-initiated improvement pass" or "the end-of-session proactive improvement pass",
    mdir,
    _G.KERNEL_SOURCE_PATH or "(run_automation.lua)",
    user_note,
    session_summary.tasks_done   or 0,
    session_summary.tasks_failed or 0,
    table.concat(session_summary.failed_nums or {}, ", "),
    cfg.PROJECT_TYPE,
    progress,
    table.concat(sources_block, "\n"))

  os.execute('mkdir -p "' .. cfg.PROJECT_PATH .. '/logs"')
  local log_path = string.format("%s/logs/self-improve-proactive-%s.log",
    cfg.PROJECT_PATH, run_ts)

  local f = io.open(log_path, "w"); if f then f:close() end
  opencode.run_fresh(log_path, prompt, model)

  local log_content = read_file(log_path)
  for mod_name, new_source in log_content:gmatch(
    "REWRITE_MODULE:%s*([%w_]+)\n```lua\n(.-)\n```\nEND_REWRITE") do
    apply_rewrite(mod_name, new_source, "proactive_session_end")
  end
end

-- ---------------------------------------------------------------------------
-- Kernel suggestion pass — read-only analysis, writes to KERNEL_SUGGESTIONS.md
-- ---------------------------------------------------------------------------
function M.suggest_kernel_improvements(model, context)
  logging.log("[self_improve] Kernel suggestion pass (read-only)...")

  -- These globals are set by run_automation.lua (the kernel). Access via _G
  -- explicitly so any missing-global errors are loud rather than silent nils.
  local kernel_src_path = _G.KERNEL_SOURCE_PATH
  local kernel_version  = _G.KERNEL_VERSION

  if not kernel_src_path then
    logging.warn("[self_improve] KERNEL_SOURCE_PATH not set — skipping kernel suggestion pass.")
    return
  end

  local kernel_source = read_file(kernel_src_path)
  local progress      = read_progress()
  local run_ts        = os.date("%Y%m%d-%H%M%S")

  local prompt = string.format([[
You are an expert Lua developer reviewing an orchestration system kernel.

## IMPORTANT — file locations
This is an orchestration system, NOT the project being built.
Kernel entry point : %s
Modules directory  : %s
Do NOT look in src/, scripts/, or PROJECT_PATH for these files.

IMPORTANT: You are NOT rewriting this file. You are writing SUGGESTIONS ONLY
for the human developer to review and apply manually.

## Task failure context
Task #%s: %s
What went wrong: %s
Project type: %s

## Recent progress
%s

## Kernel source (run_automation.lua) — current version: %s
```lua
%s
```

## Your task
Analyze the kernel and suggest concrete, specific improvements.

Format each suggestion as:

### Suggestion: <short title>
**Problem:** <what you observed>
**Proposed change:** <specific code change or architectural improvement>
**Benefit:** <why this would help>

After all suggestions, output: DONE
]],
    kernel_src_path,
    modules_dir(),
    context.task_num   or "?",
    context.task_text  or "?",
    context.prior_note or "unknown",
    cfg.PROJECT_TYPE,
    progress,
    kernel_version or "unknown",
    kernel_source)

  os.execute('mkdir -p "' .. cfg.PROJECT_PATH .. '/logs"')
  local log_path = string.format("%s/logs/kernel-suggestions-%s.log",
    cfg.PROJECT_PATH, run_ts)

  local f = io.open(log_path, "w"); if f then f:close() end
  opencode.run_fresh(log_path, prompt, model)

  local log_content = read_file(log_path)
  local suggestions = log_content:match("(###.-)DONE") or
                      log_content:match("(###.+)")

  if suggestions and not suggestions:match("^%s*$") then
    local ts = os.date("%Y-%m-%d %H:%M")
    local ks_path = cfg.PROJECT_PATH .. "/" .. cfg.KERNEL_SUGGESTIONS
    local fa = io.open(ks_path, "a")
    if fa then
      fa:write(string.format(
        "\n\n---\n## Session: %s | Kernel v%s | Task #%s | Type: %s\n%s\n",
        ts, kernel_version or "unknown", context.task_num or "?", cfg.PROJECT_TYPE, suggestions))
      fa:close()
      logging.ok("[self_improve] Kernel suggestions written to " .. cfg.KERNEL_SUGGESTIONS)
    end
  else
    logging.log("[self_improve] No kernel suggestions generated.")
  end
end

-- ---------------------------------------------------------------------------
-- validate — called by hot_reload after a rewrite to verify dependencies.
-- Returns nothing on success; errors with assert() on failure.
-- This catches AI rewrites that call non-existent functions on other modules.
-- ---------------------------------------------------------------------------
function M.validate()
  local oc = require("opencode")
  assert(type(oc.run_fresh)    == "function", "opencode.run_fresh missing")
  assert(type(oc.run_classify) == "function", "opencode.run_classify missing")
  local pr = require("prompts")
  assert(type(pr.build_self_improve_prompt) == "function", "prompts.build_self_improve_prompt missing")
  local hr = require("hot_reload")
  assert(type(hr.write_and_reload) == "function", "hot_reload.write_and_reload missing")
  assert(type(hr.source)           == "function", "hot_reload.source missing")
  assert(type(hr.list)             == "function", "hot_reload.list missing")
end

return M
