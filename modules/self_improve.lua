--[[
  modules/self_improve.lua — AI self-improvement orchestration.
  AI-rewritable (but be careful — this module rewrites other modules).

  Three entry points called by the kernel:

  1. run_targeted(model, reason, context)
       Called after a task failure or persistent compile errors.
       The AI reviews the relevant module(s) and rewrites them.

  2. run_proactive(model, session_summary)
       Called once at the end of every session.
       The AI reviews progress.txt + all module sources and proposes
       improvements across the whole suite, then rewrites modules it judges
       worth changing.

  3. suggest_kernel_improvements(model, context)
       Called after a task failure.
       The AI READS the kernel source but appends suggestions only to
       KERNEL_SUGGESTIONS.md. It never writes run_automation.lua.

  Hot-reload workflow (for all rewrites):
    hot_reload.write_and_reload(name, new_source)
      → validates syntax in temp file
      → writes to disk
      → calls __reload_module(name) via kernel-exposed global
      → rolls back if load fails
    Then __refresh_modules() is called by the kernel to update all refs.

  Rewrite prompt design:
    - The AI is shown the current source of the module
    - The AI is shown progress.txt (cross-task learnings)
    - The AI is shown the reason/context for the improvement pass
    - The AI must return ONLY valid Lua source, nothing else
    - A wrapper checks it loads cleanly before committing it to disk
]]

local M = {}

local cfg       = require("config")
local logging   = require("logging")
local hot_reload= require("hot_reload")
local opencode  = require("opencode")

-- ---------------------------------------------------------------------------
-- Helper: read a file
-- ---------------------------------------------------------------------------
local function read_file(path)
  local f = io.open(path, "r")
  if not f then return "(file not found: " .. path .. ")" end
  local s = f:read("*a"); f:close()
  return s
end

-- ---------------------------------------------------------------------------
-- Helper: read progress.txt
-- ---------------------------------------------------------------------------
local function read_progress()
  return read_file(cfg.PROJECT_PATH .. "/" .. cfg.PROGRESS_FILE)
end

-- ---------------------------------------------------------------------------
-- Helper: run a self-improvement opencode call and return the new Lua source.
-- The prompt instructs the AI to respond with ONLY the new Lua source,
-- starting with "--[[" and ending with "return M".
-- ---------------------------------------------------------------------------
local function run_improve_call(model, prompt, log_path)
  local f = io.open(log_path, "w"); if f then f:close() end
  opencode.run_fresh(log_path, prompt, model)

  -- Extract Lua source from log: everything between first "--[[" and last "return M"
  local log_content = read_file(log_path)

  -- Try to find a clean Lua block
  local src = log_content:match("(%-%-[^\n]*\n.+return%s+M[^\n]*)")
  if not src then
    -- Fallback: return everything after the first "--"
    src = log_content:match("(%-%-[^\n]*\n.+)")
  end
  return src
end

-- ---------------------------------------------------------------------------
-- Helper: attempt to apply a rewritten module, with rollback
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
    -- Commit the change
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
  logging.log("[self_improve] Targeted pass — reason: " .. reason)

  -- Decide which modules are most relevant to the failure reason
  local targets = {}
  if reason == "task_failure" then
    targets = { "prompts", "opencode" }
    if (context.iterations or 0) >= 3 then
      targets[#targets+1] = "session"
    end
  elseif reason == "compile_failure" then
    targets = { "compile", "prompts" }
  else
    targets = { "prompts" }
  end

  local progress = read_progress()
  local run_ts   = os.date("%Y%m%d-%H%M%S")

  for _, mod_name in ipairs(targets) do
    local current_source = hot_reload.source(mod_name) or
                           read_file(cfg.PROJECT_PATH .. "/../modules/" .. mod_name .. ".lua")

    local prompt = string.format([[
You are an expert Lua developer improving a Unity automation orchestration system.

## Improvement trigger
Reason: %s
Context: %s

## Cross-task learnings (progress.txt)
%s

## Current source of module: %s
```lua
%s
```

## Your task
Rewrite this module to fix the problem described above.
Rules:
  1. Return ONLY valid Lua 5.4 source code — no markdown, no explanation, no backticks.
  2. The module must return a table named M.
  3. Do not remove existing functionality — only improve or fix.
  4. Keep all existing function signatures compatible.
  5. If nothing needs changing, return the source UNCHANGED.

Output the complete new Lua source now, starting with the module header comment.
]], reason, require("logging").dim and "" or tostring(context),
    progress, mod_name, current_source)

    local log_path = string.format("%s/logs/self-improve-%s-%s-%s.log",
      cfg.PROJECT_PATH, mod_name, reason, run_ts)

    local new_source = run_improve_call(model, prompt, log_path)
    apply_rewrite(mod_name, new_source, reason)
  end
end

-- ---------------------------------------------------------------------------
-- Proactive end-of-session improvement pass
-- ---------------------------------------------------------------------------
function M.run_proactive(model, session_summary)
  logging.log("[self_improve] Proactive session-end pass...")

  local progress     = read_progress()
  local module_names = hot_reload.list()
  local run_ts       = os.date("%Y%m%d-%H%M%S")

  -- Build a summary of all module sources for the AI to review
  local sources_block = {}
  for _, name in ipairs(module_names) do
    local src = hot_reload.source(name) or ""
    sources_block[#sources_block+1] = string.format(
      "=== %s ===\n%s\n", name, src:sub(1, 3000))  -- cap at 3k chars each
  end

  local prompt = string.format([[
You are an expert Lua developer improving a Unity automation orchestration system.
This is the end-of-session proactive improvement pass.

## Session summary
Tasks done   : %d
Tasks failed : %d
Failed tasks : %s

## Cross-task learnings (progress.txt)
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
  5. If no improvements are warranted, output: NO_IMPROVEMENTS_NEEDED

After all rewrites (or NO_IMPROVEMENTS_NEEDED), output: DONE
]],
    session_summary.tasks_done or 0,
    session_summary.tasks_failed or 0,
    table.concat(session_summary.failed_nums or {}, ", "),
    progress,
    table.concat(sources_block, "\n"))

  local log_path = string.format("%s/logs/self-improve-proactive-%s.log",
    cfg.PROJECT_PATH, run_ts)

  local f = io.open(log_path, "w"); if f then f:close() end
  opencode.run_fresh(log_path, prompt, model)

  -- Parse the response for REWRITE_MODULE blocks
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

  local kernel_source = read_file(KERNEL_SOURCE_PATH)  -- global set by kernel
  local progress      = read_progress()
  local run_ts        = os.date("%Y%m%d-%H%M%S")

  local prompt = string.format([[
You are an expert Lua developer reviewing an orchestration system kernel.

IMPORTANT: You are NOT rewriting this file. You are writing SUGGESTIONS ONLY
for the human developer to review. The kernel is intentionally immutable to
the AI agent — the human applies changes manually.

## Task failure context
Task #%s: %s
What went wrong: %s

## Cross-task learnings (progress.txt)
%s

## Kernel source (run_automation.lua) — current version: %s
```lua
%s
```

## Your task
Analyze the kernel and suggest concrete, specific improvements that would have
helped with this task failure or would improve the system in general.

Format each suggestion as:

### Suggestion: <short title>
**Problem:** <what you observed>
**Proposed change:** <specific code change or architectural improvement>
**Benefit:** <why this would help>

After all suggestions, output: DONE
]],
    context.task_num or "?",
    context.task_text or "?",
    context.prior_note or "unknown",
    progress,
    KERNEL_VERSION,
    kernel_source)

  local log_path = string.format("%s/logs/kernel-suggestions-%s.log",
    cfg.PROJECT_PATH, run_ts)

  local f = io.open(log_path, "w"); if f then f:close() end
  opencode.run_fresh(log_path, prompt, model)

  -- Extract suggestions (everything before DONE)
  local log_content = read_file(log_path)
  local suggestions = log_content:match("(###.-)DONE") or
                      log_content:match("(###.+)")

  if suggestions and not suggestions:match("^%s*$") then
    local ts = os.date("%Y-%m-%d %H:%M")
    local ks_path = cfg.PROJECT_PATH .. "/" .. cfg.KERNEL_SUGGESTIONS
    local fa = io.open(ks_path, "a")
    if fa then
      fa:write(string.format(
        "\n\n---\n## Session: %s | Kernel v%s | Task #%s\n%s\n",
        ts, KERNEL_VERSION, context.task_num or "?", suggestions))
      fa:close()
      logging.ok("[self_improve] Kernel suggestions written to " .. cfg.KERNEL_SUGGESTIONS)
    end
  else
    logging.log("[self_improve] No kernel suggestions generated.")
  end
end

return M
