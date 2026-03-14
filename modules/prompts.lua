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
-- Thinking instruction — prompt models to show their reasoning process
-- ---------------------------------------------------------------------------
M.THINKING_INSTRUCTION = [[
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SHOW YOUR REASONING: Wrap your planning and thought process in <think>...</think> tags.
This helps track your decision-making and catches errors early.

Example:
<think>
I need to implement user authentication. Key considerations:
- Password hashing using bcrypt
- Email validation with regex
- Session management with JWT tokens
- Edge case: handle already-registered emails
</think>

Then implement the solution.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

]]

-- ---------------------------------------------------------------------------
-- Helper: wrap a prompt with thinking instruction if enabled
-- ---------------------------------------------------------------------------
local function with_thinking(base_prompt)
  -- Check config to see if thinking prompts are enabled
  if cfg.SHOW_THINKING_ENABLED == false then
    return base_prompt
  end
  return M.THINKING_INSTRUCTION .. base_prompt
end

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
    and ("## This session\n" .. session_context .. "\n\n")
    or  ""

  local base_prompt = string.format([[
You are an expert %s engineer. You will implement the following task fully
using the available code-editing tools. The task may involve creating new
files, modifying existing files, or both.

%s## Task #%s
%s

## Project metadata
Path:         %s
Tech:         %s
Version:      %s
Type hints:   %s

## Standard directories
%s

## Current source files
%s

## Learnings from past tasks (tail of progress.txt)
%s

## Codebase patterns and conventions (tail of AGENTS.md)
%s

%s%s

When you have FULLY completed the task and written all required files:
  • Output the word DONE on its own line.
  • Do NOT continue working after DONE.
  • Do NOT output DONE until all files are written and the task is complete.
]],
    tech,
    retry_block,
    task_num, task_text,
    cfg.PROJECT_PATH, tech, version, type_hints,
    src_dir_listing(),
    existing_sources_list(),
    progress_text,
    agents_text,
    session_block,
    tool_context)

  return with_thinking(base_prompt)
end

-- ---------------------------------------------------------------------------
-- build_fix_prompt
-- ---------------------------------------------------------------------------
function M.build_fix_prompt(opts)
  local task_num   = opts.task_num
  local task_text  = opts.task_text
  local errors     = opts.errors or {}
  local round      = opts.round or 1
  local version    = opts.version or "unknown"

  local tech = project_type.get_tech(cfg)

  local err_count = #errors
  local err_block = table.concat(errors, "\n")

  local base_prompt = string.format([[
COMPILE CHECK FAILED — %d error(s) found. Fix them now.

Task #%s: %s
Tech: %s | Version: %s
Fix round: %d

Errors:
%s

Instructions:
1. Read each failing file mentioned in the errors above.
2. Fix the root cause — do not mask the problem or disable warnings.
3. Re-run write_file for each corrected file.
4. Output DONE on its own line when all errors are fixed.
]],
    err_count,
    task_num, task_text,
    tech, version,
    round,
    err_block)

  return with_thinking(base_prompt)
end

-- ---------------------------------------------------------------------------
-- build_self_improve_prompt — rewrite one of the orchestrator's own modules
-- ---------------------------------------------------------------------------
function M.build_self_improve_prompt(opts)
  local mod_path        = opts.mod_path
  local mod_name        = opts.mod_name
  local current_source  = opts.current_source
  local reason          = opts.reason          or "Self-improvement pass"
  local context         = opts.context         or {}

  local MAX_SOURCE_CHARS = 15000
  if #current_source > MAX_SOURCE_CHARS then
    current_source = current_source:sub(1, MAX_SOURCE_CHARS)
      .. "\n[... source truncated to fit context budget]"
  end

  local context_str = ""
  if type(context) == "table" then
    local parts = {}
    for k, v in pairs(context) do
      parts[#parts+1] = k .. ": " .. tostring(v)
    end
    context_str = table.concat(parts, ", ")
  else
    context_str = tostring(context)
  end

  local progress = read_tail(cfg.PROGRESS_FILE, ctx("CTX_PROGRESS_CHARS", 2000))

  return string.format([[
You are a self-improving AI orchestrator. Your task is to rewrite one of your
own automation modules to fix a problem or improve behaviour.

## Module location
File:    %s
Kernel:  %s

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
  5. Only call functions that actually exist on required modules.
     NEVER invent function names on other modules (e.g. opencode.run_targeted,
     prompts.build_improve_reason — these do not exist).
  6. Include a M.validate() function that asserts any external module functions
     this module calls actually exist at load time. Example:
       function M.validate()
         local oc = require("opencode")
         assert(type(oc.run_fresh) == "function", "opencode.run_fresh missing")
       end
  7. If nothing needs changing, return source UNCHANGED.

Output constraints:
  - Output the complete rewritten source — no partial diffs.
  - No padding, filler comments, or prose outside the Lua source itself.
  - Keep output under 600 lines. If more is needed, focus on the highest-value changes only.

Output the complete Lua source now, starting with the module header comment.
]],
    mod_path,
    cfg.KERNEL_SOURCE_PATH or _G.KERNEL_SOURCE_PATH or "(run_automation.lua)",
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
You are a %s developer assistant. Answer the user's question concisely and completely.

Project: %s | Tech: %s | Version: %s
Dirs: %s
Files: %s

%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
QUESTION: %s
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

IMPORTANT INSTRUCTIONS:
1. You may use tools to explore the project and gather context.
2. After gathering necessary information, provide a COMPLETE answer.
3. Do NOT write or modify any files.
4. Do NOT output DONE - this is a query, not a task.
5. When your answer is complete, simply STOP. Do not keep using tools.
6. Keep your final answer focused and concise.
7. If you need to examine code, do so, then provide your answer and STOP.

Provide your answer now:
]],
    tech,
    cfg.PROJECT_PATH, tech, version,
    src_dir_listing(),
    existing_sources_list(),
    session_block,
    question)
end

-- ---------------------------------------------------------------------------
-- Nudge prompts — rotated by get_nudge(count) so repeated nudges don't feel
-- identical. FIX nudges are round-aware to escalate urgency.
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

local _FIX_NUDGE_PROMPTS = {
  "Continue fixing the errors. Output DONE when all errors are resolved.",
  "Keep going — there are still errors to fix. Address each ERROR: line and output DONE.",
  "You have not finished fixing the errors. Re-read the failing file and fix it now, then output DONE.",
  "Final fix round — correct every remaining error and output DONE. Do not re-read files you already fixed.",
}

function M.get_nudge(count)
  return _NUDGE_PROMPTS[((count - 1) % #_NUDGE_PROMPTS) + 1]
end

function M.get_fix_nudge(round)
  return _FIX_NUDGE_PROMPTS[((round - 1) % #_FIX_NUDGE_PROMPTS) + 1]
end

-- Keep the old static field for any callers that reference it directly
M.FIX_NUDGE_PROMPT = _FIX_NUDGE_PROMPTS[1]

-- ---------------------------------------------------------------------------
-- build_reflection_prompt — self-review before compile check
-- ---------------------------------------------------------------------------
function M.build_reflection_prompt(opts)
  local task_num  = opts.task_num
  local task_text = opts.task_text
  local version   = opts.version or "unknown"

  local tech = project_type.get_tech(cfg)

  local base_prompt = string.format([[
SELF-REVIEW CHECKPOINT

You just completed this task:
  Task #%s: %s
  Tech: %s | Version: %s

Before we proceed, critically review your implementation:

1. Did you FULLY complete the task as specified?
2. Are there any edge cases, error handling, or validation missing?
3. Does the code follow best practices for %s?
4. Are there any logical errors, typos, or incomplete sections?
5. Did you write tests/documentation if the task required them?

If you find ANY issues or incompleteness:
  - Fix them NOW
  - Re-read relevant files if needed
  - Write the corrected code
  - Output DONE when truly complete

If the implementation is genuinely complete and correct:
  - Output: REFLECTION_OK
  - Do NOT make unnecessary changes

Be honest and thorough. This is your chance to catch mistakes before compilation.
]],
    task_num, task_text,
    tech, version,
    tech)

  return with_thinking(base_prompt)
end

-- ---------------------------------------------------------------------------
-- validate — called by hot_reload after a rewrite.
-- Verifies that dependencies used by this module still export what we need.
-- ---------------------------------------------------------------------------
function M.validate()
  local pt = require("project_type")
  assert(type(pt.get_tech)     == "function", "project_type.get_tech missing")
  assert(type(pt.get_src_dirs) == "function", "project_type.get_src_dirs missing")
  local c = require("config")
  assert(type(c.PROJECT_PATH)  ~= "nil",      "config.PROJECT_PATH missing")
end

return M
