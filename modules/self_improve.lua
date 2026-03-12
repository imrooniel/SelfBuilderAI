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
-- Helper: run an improvement call and extract Lua source from log
-- ---------------------------------------------------------------------------
local function run_improve_call(model, prompt, log_path)
  local f = io.open(log_path, "w"); if f then f:close() end
  opencode.run_fresh(log_path, prompt, model)

  local log_content = read_file(log_path)

  -- Extract the Lua source block. The model is instructed to return raw Lua
  -- with no markdown fences, starting with a module header comment and ending
  -- with "return M". We look for:
  --   1. First line matching the canonical module header  ^--%[%[  (block comment open)
  --   2. Failing that, first ^local M = {}  line (handles bare rewrites)
  --   3. Last line matching ^return%s+M
  --
  -- We deliberately skip lines that begin with "-- " (single-line dash comments)
  -- as the model often emits preamble prose as Lua-style comments before the
  -- actual module source (e.g. "-- Here is the improved module:"). Anchoring on
  -- ^--%[%[ (block comment open) avoids latching onto those lines.
  local lines = {}
  for line in (log_content .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines+1] = line
  end

  local start_idx = nil
  local end_idx   = nil

  -- Pass 1: prefer the canonical block-comment module header
  for i, line in ipairs(lines) do
    if start_idx == nil and line:match("^%-%-%[%[") then
      start_idx = i
    end
    if line:match("^return%s+M") then
      end_idx = i
    end
  end

  -- Pass 2: fallback — accept the first "local M = {}" if no block header found
  if not start_idx then
    for i, line in ipairs(lines) do
      if line:match("^local%s+M%s*=%s*{}") then
        start_idx = i
        break
      end
    end
  end

  if not start_idx or not end_idx or end_idx < start_idx then
    return nil
  end

  local extracted = {}
  for i = start_idx, end_idx do
    extracted[#extracted+1] = lines[i]
  end
  return table.concat(extracted, "\n")
end

-- ---------------------------------------------------------------------------
-- Helper: attempt to apply a rewritten module
-- ---------------------------------------------------------------------------
local function apply_rewrite(mod_name, new_source, reason)
  if not new_source or new_source:match("^%s*$") then
    logging.warn(string.format("[self_improve] %s: AI returned empty source — skipping.", mod_name))
    return false
  end

  logging.log(string.format("[self_improve] Applying rewrite to %s (%s)...", mod_name, reason))
  local ok, err = hot_reload.write_and_reload(mod_name, new_source)
  if ok then
    logging.ok(string.format("[self_improve] %s successfully rewritten and hot-reloaded.", mod_name))
    -- Commit in the directory that actually contains the module files (the kernel
    -- directory), not cfg.PROJECT_PATH which may be a different repo entirely.
    local mdir = modules_dir()
    local commit_dir = mdir:match("^(.*)/[^/]+$") or mdir  -- parent of modules/
    os.execute(string.format(
      'cd "%s" && git add -A && git commit -m "self-improve: rewrite %s [%s]" 2>/dev/null',
      commit_dir, mod_name, reason))
    return true
  else
    logging.warn(string.format("[self_improve] %s rewrite FAILED (rolled back): %s", mod_name, err))
    return false
  end
end

-- ---------------------------------------------------------------------------
-- Targeted improvement — called after task failure or compile errors
-- ---------------------------------------------------------------------------
function M.run_targeted(model, opts)
  if not cfg.SELF_IMPROVE_ENABLED or not cfg.SELF_IMPROVE_TARGETED then
    logging.log("[self_improve] Targeted pass disabled in config — skipping.")
    return
  end

  -- Extract reason and use opts as context
  local reason = opts.reason or "unspecified"
  local context = opts
  
  logging.log("[self_improve] Targeted pass — reason: " .. reason)

  -- Decide which modules are most relevant to the failure
  local targets = {}
  if context.target_module then
    -- Caller specified exact module — use it directly
    targets = { context.target_module }
  elseif context.target_override then
    -- Caller specified exact module(s) list — honour it directly
    targets = context.target_override
  elseif reason == "user_request" or reason:match("^improve") then
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
  local run_ts   = opts.run_ts or os.date("%Y%m%d-%H%M%S")

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

    local new_source = run_improve_call(model, prompt_text, log_path)
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

  -- Minimum task threshold: don't burn a full model call after a one-liner session
  -- Minimum task threshold only applies to automatic end-of-session passes.
  -- User-initiated requests always run regardless of task count.
  local min_tasks   = cfg.SELF_IMPROVE_MIN_TASKS or 3
  local total_tasks = (session_summary.tasks_done or 0) + (session_summary.tasks_failed or 0)
  if not session_summary.user_request and total_tasks < min_tasks then
    logging.log(string.format(
      "[self_improve] Proactive pass skipped: %d task(s) < minimum %d.", total_tasks, min_tasks))
    return
  end

  logging.log("[self_improve] Proactive session-end pass...")

  local progress     = read_progress()
  local module_names = hot_reload.list()
  local run_ts       = os.date("%Y%m%d-%H%M%S")

  -- Rank modules: prioritise by failure relevance then source size.
  -- Only send the top N modules with full source; list the rest by name only
  -- to keep the prompt within a reasonable token budget.
  local MAX_FULL_SOURCES = 3
  local scores = {}
  for _, name in ipairs(module_names) do
    local src = hot_reload.source(name) or ""
    scores[name] = #src  -- base score = source size (more code = more to improve)
  end
  if (session_summary.tasks_failed or 0) > 0 then
    scores["prompts"]      = (scores["prompts"]      or 0) + 5000
    scores["opencode"]     = (scores["opencode"]     or 0) + 3000
    scores["self_improve"] = (scores["self_improve"] or 0) + 2000
    scores["compile"]      = (scores["compile"]      or 0) + 1000
  end
  if session_summary.user_request then
    -- User explicitly asked for improvement — boost self_improve and prompts
    scores["self_improve"] = (scores["self_improve"] or 0) + 8000
    scores["prompts"]      = (scores["prompts"]      or 0) + 4000
  end
  table.sort(module_names, function(a, b) return (scores[a] or 0) > (scores[b] or 0) end)

  local sources_block = {}
  local remaining_names = {}
  -- Total source budget: leave room for the prompt skeleton, progress, and session data.
  -- cfg.CTX_PROMPT_HARD_CAP governs task prompts; self-improve prompts are larger, so
  -- we use a dedicated budget: ~18k chars for source blocks ≈ 4.5k tokens.
  local SOURCE_BUDGET   = 18000
  local used_source     = 0
  for i, name in ipairs(module_names) do
    local src  = hot_reload.source(name) or ""
    local path = module_path(name)
    if i <= MAX_FULL_SOURCES and used_source < SOURCE_BUDGET then
      local avail    = SOURCE_BUDGET - used_source
      local src_clip = src:sub(1, avail)
      -- Trim to a line boundary
      if #src_clip < #src then
        local lb = src_clip:match("^(.*)\n[^\n]*$")
        if lb then src_clip = lb end
      end
      sources_block[#sources_block+1] = string.format(
        "=== %s ===\nPath: %s\n%s%s\n",
        name, path, src_clip,
        (#src_clip < #src) and ("\n-- [...truncated, " .. #src .. " chars total]") or "")
      used_source = used_source + #src_clip
    else
      remaining_names[#remaining_names+1] = name
    end
  end
  local remaining_note = #remaining_names > 0
    and ("\n## Other available modules (full source not shown)\n" .. table.concat(remaining_names, ", ") .. "\n")
    or  ""

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
%s
## Top candidate module sources
%s

## Your task
Review the session results and module sources above.
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

Output constraints:
  - Maximum 2 REWRITE_MODULE blocks total.
  - Each rewritten module: complete and valid, but no filler comments or padding.
  - Keep each rewrite under 500 lines. If a module needs more changes than that,
    focus on the highest-value improvements only.
  - Total output should fit within 6000 tokens.

After all rewrites (or NO_IMPROVEMENTS_NEEDED), output: DONE
]],
    session_summary.user_request and "a user-initiated improvement pass" or "the end-of-session proactive improvement pass",
    mdir,
    cfg.KERNEL_SOURCE_PATH or _G.KERNEL_SOURCE_PATH or "(run_automation.lua)",
    user_note,
    session_summary.tasks_done   or 0,
    session_summary.tasks_failed or 0,
    table.concat(session_summary.failed_nums or {}, ", "),
    cfg.PROJECT_TYPE,
    progress,
    remaining_note,
    table.concat(sources_block, "\n"))

  os.execute('mkdir -p "' .. cfg.PROJECT_PATH .. '/logs"')
  local log_path = string.format("%s/logs/self-improve-proactive-%s.log",
    cfg.PROJECT_PATH, run_ts)

  local f = io.open(log_path, "w"); if f then f:close() end
  opencode.run_fresh(log_path, prompt, model)

  local log_content = read_file(log_path)
  local rewrites_applied = 0
  for mod_name, new_source in log_content:gmatch(
    "REWRITE_MODULE:%s*([%w_]+)\n```lua\n(.-)\n```\nEND_REWRITE") do
    local old_size = #(hot_reload.source(mod_name) or "")
    local applied = apply_rewrite(mod_name, new_source, "proactive_session_end")
    if applied then
      rewrites_applied = rewrites_applied + 1
      -- Log outcome to SELF_IMPROVE_LOG.md
      local log_entry = string.format(
        "\n## %s | proactive | %s | %d→%d chars\n",
        os.date("!%Y-%m-%d %H:%M"), mod_name, old_size, #new_source)
      local lf = io.open(cfg.PROJECT_PATH .. "/SELF_IMPROVE_LOG.md", "a")
      if lf then lf:write(log_entry); lf:close() end
    end
  end

  if rewrites_applied > 0 then
    logging.ok(string.format("[self_improve] Proactive pass applied %d rewrite(s).", rewrites_applied))
  else
    logging.log("[self_improve] Proactive pass: no rewrites applied.")
  end
end

-- ---------------------------------------------------------------------------
-- Kernel suggestion pass — read-only analysis, writes to KERNEL_SUGGESTIONS.md
-- ---------------------------------------------------------------------------
function M.suggest_kernel_improvements(model, context)
  logging.log("[self_improve] Kernel suggestion pass (read-only)...")

  -- These globals are set by run_automation.lua (the kernel). Access via _G
  -- explicitly so any missing-global errors are loud rather than silent nils.
  local kernel_src_path = cfg.KERNEL_SOURCE_PATH or _G.KERNEL_SOURCE_PATH
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
  -- run_proactive calls hr.list() — verify it returns a table
  local names = hr.list()
  assert(type(names) == "table", "hot_reload.list() did not return a table")
end

return M
