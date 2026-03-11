--[[
  modules/prompts.lua — task and fix prompt builders, nudge rotation.
  AI-rewritable — highest-value module for self-improvement.

  Prompts are project-type-aware: they inject the correct technology
  description, source directories, and language-specific context.

  CONTEXT BUDGET PHILOSOPHY
  ─────────────────────────
  Every piece of supplementary data injected into a prompt costs tokens that
  could otherwise be used by the model for reasoning and output. For local
  models with a 512k context window this matters: a large progress.txt or
  file listing can silently eat tens of thousands of tokens per prompt.

  Rules enforced here:
    • progress.txt  — tail only (cfg.CTX_PROGRESS_CHARS chars)
    • AGENTS.md     — tail only (cfg.CTX_AGENTS_CHARS chars)
    • File list     — capped at cfg.CTX_FILE_LIST_MAX paths
    • Section ctx   — capped at cfg.CTX_SECTION_TASKS sibling tasks
    • Session jnl   — capped at cfg.CTX_JOURNAL_ENTRIES recent entries
    • Self-improve  — source capped at MAX_SOURCE_CHARS
    • progress.txt  — injected inline; model does NOT make a tool call to read it
                      (saves one round-trip and makes the cap reliable)
]]

local M = {}

local cfg          = require("config")
local project_type = require("project_type")

-- ---------------------------------------------------------------------------
-- Defaults for context-budget fields (safe values if config is old/missing)
-- ---------------------------------------------------------------------------
local function ctx(field, default)
  local v = cfg[field]
  return (type(v) == "number" and v > 0) and v or default
end

-- ---------------------------------------------------------------------------
-- Helper: read a state file, returning at most `max_chars` from the TAIL.
-- Tail semantics: most recent entries in append-only files are at the bottom.
-- ---------------------------------------------------------------------------
local function read_tail(rel_path, max_chars)
  local f = io.open(cfg.PROJECT_PATH .. "/" .. rel_path, "r")
  if not f then return "(not found)" end
  local s = f:read("*a"); f:close()
  if #s <= max_chars then return s end
  -- Trim to a line boundary so we don't show half a line
  local tail = s:sub(#s - max_chars + 1)
  local newline = tail:find("\n")
  if newline then tail = tail:sub(newline + 1) end
  return "[... earlier entries omitted ...]\n" .. tail
end

-- ---------------------------------------------------------------------------
-- Helper: list existing source files, capped at max paths
-- ---------------------------------------------------------------------------
local function existing_sources_list()
  local max = ctx("CTX_FILE_LIST_MAX", 20)
  local src_dirs = project_type.get_src_dirs(cfg)
  local paths = {}
  for _, dir in ipairs(src_dirs) do
    local full = cfg.PROJECT_PATH .. "/" .. dir
    local handle = io.popen(string.format(
      'find "%s" -type f 2>/dev/null | grep -v "__pycache__" | grep -v ".pyc" | head -%d',
      full, max))
    if handle then
      for line in handle:lines() do
        paths[#paths+1] = line:gsub(cfg.PROJECT_PATH .. "/", "")
        if #paths >= max then break end
      end
      handle:close()
    end
    if #paths >= max then break end
  end
  if #paths == 0 then return "none yet — fresh project" end
  return table.concat(paths, "\n")
end

-- ---------------------------------------------------------------------------
-- Helper: build source directory layout string for prompts
-- ---------------------------------------------------------------------------
local function src_dir_listing()
  local src_dirs = project_type.get_src_dirs(cfg)
  local lines = {}
  for _, d in ipairs(src_dirs) do
    lines[#lines+1] = "- " .. cfg.PROJECT_PATH .. "/" .. d
  end
  return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Helper: cap a session journal to the most recent N entries
-- ---------------------------------------------------------------------------
local function cap_journal(session_context)
  if session_context == "" then return "" end
  local max = ctx("CTX_JOURNAL_ENTRIES", 10)
  local entries = {}
  for line in (session_context .. "\n"):gmatch("([^\n]+)\n?") do
    if line ~= "" then entries[#entries+1] = line end
  end
  if #entries <= max then return session_context end
  local trimmed = {}
  for i = #entries - max + 1, #entries do trimmed[#trimmed+1] = entries[i] end
  return "[... " .. (#entries - max) .. " earlier entries omitted ...]\n"
    .. table.concat(trimmed, "\n")
end

-- ---------------------------------------------------------------------------
-- Helper: cap section_context to the most recent N tasks
-- ---------------------------------------------------------------------------
local function cap_section_context(section_context)
  if section_context == "" then return "" end
  local max = ctx("CTX_SECTION_TASKS", 10)
  local lines = {}
  for line in (section_context .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines+1] = line
  end
  if #lines <= max then return section_context end
  local trimmed = {}
  for i = #lines - max + 1, #lines do trimmed[#trimmed+1] = lines[i] end
  return "[... " .. (#lines - max) .. " earlier tasks omitted ...]\n"
    .. table.concat(trimmed, "\n")
end

-- ---------------------------------------------------------------------------
-- build_task_prompt
-- ---------------------------------------------------------------------------
function M.build_task_prompt(opts)
  local task_num        = opts.task_num
  local task_text       = opts.task_text
  local section_context = cap_section_context(opts.section_context or "")
  local iteration       = opts.iteration or 1
  local prior_note      = opts.prior_note or "No details recorded."
  local version         = opts.version or "unknown"
  local tool_context    = opts.tool_context or ""
  local session_context = cap_journal(opts.session_context or "")

  local tech     = project_type.get_tech(cfg)
  local src_dirs = project_type.get_src_dirs(cfg)
  local primary_dir = src_dirs[1] and (cfg.PROJECT_PATH .. "/" .. src_dirs[1]) or cfg.PROJECT_PATH

  -- Read state files inline (capped) — avoids a tool call round-trip per prompt
  -- and makes the budget cap reliable vs. an unbounded tool-call read.
  local progress_text = read_tail(cfg.PROGRESS_FILE, ctx("CTX_PROGRESS_CHARS", 2000))
  local agents_text   = read_tail(cfg.AGENTS_FILE,   ctx("CTX_AGENTS_CHARS",   3000))

  local retry_block = ""
  if iteration > 1 then
    retry_block = string.format([[

## !! RETRY — iteration %d/%d !!
Previous attempt(s) made NO file changes. What was noted: %s
Skip straight to writing the file. Target directory: %s

]],    iteration, cfg.MAX_ITERATIONS, prior_note, primary_dir)
  end

  -- Project-type rules as a single compact line to minimise tokens
  local type_hints = ""
  local pt = cfg.PROJECT_TYPE
  if pt == "unity" then
    type_hints = "Unity: use project namespace; MonoBehaviours→Assets/Scripts/Core/; Editor scripts→Assets/Scripts/Editor/; no deprecated APIs. v" .. version
  elseif pt == "rust" then
    type_hints = "Rust: clippy-clean; Result<T,E> over unwrap() in libs; minimal unsafe; doc comments on public items."
  elseif pt == "node" then
    type_hints = "TS: strict mode, no `any`; ES2022+; explicit type exports; pure functions preferred."
  elseif pt == "python" then
    type_hints = "Python: PEP 8/257; type hints throughout; dataclasses/Pydantic for models; no mutable defaults."
  elseif pt == "go" then
    type_hints = "Go: effective-Go; return errors (no panic); export comments; document goroutines."
  end

  local session_block = session_context ~= ""
    and ("## This session — completed tasks\n" .. session_context .. "\n\n")
    or  ""

  local section_block = section_context ~= ""
    and ("## Sibling tasks in this batch\n" .. section_context .. "\n\n")
    or  ""

  local tool_block = tool_context ~= ""
    and (tool_context .. "\n\n")
    or  ""

  return string.format([[
You are a %s developer. Write code immediately — do not explore first.

## Rules
1. At most ONE tool call for exploration before writing.
2. Read a file before editing it.
3. When finished, output exactly: DONE

## Project
Path: %s | Tech: %s | Version: %s
Dirs: %s
%s
## AGENTS.md
%s

## Recent progress
%s
%s%s%s## Existing files
%s

## Task #%s
%s

## On completion
Append one discovery note to %s/%s, then output: DONE
]],
    tech,
    cfg.PROJECT_PATH, tech, version,
    src_dir_listing(),
    type_hints ~= "" and ("Lang rules: " .. type_hints .. "\n") or "",
    agents_text,
    progress_text,
    retry_block,
    session_block,
    section_block,
    tool_block,
    existing_sources_list(),
    task_num, task_text,
    cfg.PROJECT_PATH, cfg.AGENTS_FILE)
end

-- ---------------------------------------------------------------------------
-- build_fix_prompt
-- ---------------------------------------------------------------------------
function M.build_fix_prompt(opts)
  local task_num        = opts.task_num
  local task_text       = opts.task_text
  local compile_errors  = opts.compile_errors or ""
  local version         = opts.version or "unknown"
  local session_context = cap_journal(opts.session_context or "")

  local tech = project_type.get_tech(cfg)

  local session_block = session_context ~= ""
    and ("## This session\n" .. session_context .. "\n\n")
    or  ""

  return string.format([[
You are a %s developer. Fix compile errors — do not restructure working code.

## Rules
1. Read each erroring file BEFORE editing.
2. Fix ONLY the reported errors.
3. Output exactly: DONE

## Project: %s | Version: %s
%s## Task implemented: #%s — %s

## Errors
%s

## Existing files
%s

Fix the errors, then output: DONE
]],
    tech,
    cfg.PROJECT_PATH, version,
    session_block,
    task_num, task_text,
    compile_errors,
    existing_sources_list())
end

-- ---------------------------------------------------------------------------
-- build_self_improve_prompt
-- ---------------------------------------------------------------------------
local MAX_SOURCE_CHARS = 24000   -- ~6k tokens

function M.build_self_improve_prompt(opts)
  local mod_name       = opts.mod_name
  local mod_path       = opts.mod_path or ("modules/" .. mod_name .. ".lua")
  local current_source = opts.current_source or ""
  local reason         = opts.reason or "general"
  local context_str    = opts.context_str or ""
  local progress       = opts.progress or ""

  if #current_source > MAX_SOURCE_CHARS then
    current_source = current_source:sub(1, MAX_SOURCE_CHARS)
      .. "\n\n-- [SOURCE TRUNCATED — " .. #(opts.current_source) .. " chars total]\n"
  end
  local prog_cap = ctx("CTX_PROGRESS_CHARS", 2000)
  if #progress > prog_cap then
    progress = "[... omitted ...]\n" .. progress:sub(#progress - prog_cap + 1)
  end

  return string.format([[
You are an expert Lua developer improving a programming automation system.

## IMPORTANT — file locations
This is an orchestration system, NOT the project being built.
The module you are improving is at: %s
The entry point is: %s
Other modules are in the same directory as the module above.
Do NOT look in src/, scripts/, or PROJECT_PATH for these files.

Reason: %s
Context: %s

## Recent progress
%s

## Module: %s
```lua
%s
```

Rewrite to fix the problem described above. Rules:
  1. Return ONLY valid Lua 5.4 — no markdown, no backticks.
  2. Module must return table M.
  3. Do not remove functionality.
  4. Keep all function signatures compatible.
  5. If nothing needs changing, return source UNCHANGED.

Output the complete Lua source now, starting with the module header comment.
]],
    mod_path,
    _G.KERNEL_SOURCE_PATH or "(run_automation.lua)",
    reason, context_str, progress, mod_name, current_source)
end

-- ---------------------------------------------------------------------------
-- build_query_prompt — lightweight one-shot Q&A
-- ---------------------------------------------------------------------------
function M.build_query_prompt(opts)
  local question        = opts.question or ""
  local version         = opts.version  or "unknown"
  local session_context = cap_journal(opts.session_context or "")
  local tech            = project_type.get_tech(cfg)

  local session_block = session_context ~= ""
    and ("## This session\n" .. session_context .. "\n\n")
    or  ""

  return string.format([[
You are a %s developer assistant. Answer concisely.

Project: %s | Tech: %s | Version: %s
Dirs: %s
Files: %s

%s%s

Do not write or modify files. Do not output DONE.
]],
    tech,
    cfg.PROJECT_PATH, tech, version,
    src_dir_listing(),
    existing_sources_list(),
    session_block,
    question)
end

-- ---------------------------------------------------------------------------
-- Nudge prompts — varied so a stalled model gets a different angle each time
-- ---------------------------------------------------------------------------
local _NUDGE_PROMPTS = {
  "You appear to have stopped mid-task. Continue from where you left off "
    .. "and write the remaining file(s). Output DONE on its own line when complete.",

  "Keep going — the task is not finished yet. "
    .. "Write any remaining code now and output DONE when done.",

  "You have more work to do. Check what files you have written so far, "
    .. "implement anything still missing, then output DONE.",

  "Continue implementing. Do not re-read files you have already read. "
    .. "Write the next required file and output DONE.",

  "Almost there — finish the implementation and output DONE on its own line.",

  "Stop re-reading files. Write the code that is still missing, then output DONE.",

  "One final push — complete the remaining implementation and output DONE.",
}

M.FIX_NUDGE_PROMPT =
  "Continue fixing the errors. Output DONE when all errors are resolved."

function M.get_nudge(count)
  return _NUDGE_PROMPTS[((count - 1) % #_NUDGE_PROMPTS) + 1]
end

return M
