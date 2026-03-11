--[[
  modules/prompts.lua — task and fix prompt builders, nudge rotation.
  AI-rewritable — highest-value module for self-improvement.

  Prompts are project-type-aware: they inject the correct technology
  description, source directories, and language-specific context.
]]

local M = {}

local cfg          = require("config")
local project_type = require("project_type")

-- ---------------------------------------------------------------------------
-- Helper: list existing source files
-- ---------------------------------------------------------------------------
local function existing_sources_list(max)
  max = max or 40
  local src_dirs = project_type.get_src_dirs(cfg)
  local paths = {}
  for _, dir in ipairs(src_dirs) do
    local full = cfg.PROJECT_PATH .. "/" .. dir
    local handle = io.popen(string.format(
      'find "%s" -type f 2>/dev/null | grep -v "__pycache__" | grep -v ".pyc" | head -20',
      full))
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
  return table.concat(paths, ", ")
end

-- ---------------------------------------------------------------------------
-- Helper: read a state file
-- ---------------------------------------------------------------------------
local function read_state_file(rel_path)
  local f = io.open(cfg.PROJECT_PATH .. "/" .. rel_path, "r")
  if not f then return "(not found)" end
  local s = f:read("*a"); f:close()
  return s
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
-- build_task_prompt
-- ---------------------------------------------------------------------------
function M.build_task_prompt(opts)
  local task_num        = opts.task_num
  local task_text       = opts.task_text
  local section_context = opts.section_context or ""
  local iteration       = opts.iteration or 1
  local prior_note      = opts.prior_note or "No details recorded."
  local version         = opts.version or "unknown"
  local tool_context    = opts.tool_context or ""
  local session_context = opts.session_context or ""

  local tech     = project_type.get_tech(cfg)
  local src_dirs = project_type.get_src_dirs(cfg)
  local primary_dir = src_dirs[1] and (cfg.PROJECT_PATH .. "/" .. src_dirs[1]) or cfg.PROJECT_PATH

  local retry_block = ""
  if iteration > 1 then
    retry_block = string.format([[

## !! RETRY — iteration %d/%d !!
Previous attempt(s) made NO file changes. This is unacceptable.
What was noted: %s
DO NOT explore or list directories again. Skip straight to writing the file.
Target directory: %s
Create the file NOW using write_file or a shell command.
]], iteration, cfg.MAX_ITERATIONS, prior_note, primary_dir)
  end

  -- Inject project-type-specific extra context
  local type_hints = ""
  local pt = cfg.PROJECT_TYPE
  if pt == "unity" then
    type_hints = string.format([[
## Unity-specific rules
- Namespace: use your project namespace (see AGENTS.md)
- MonoBehaviours → Assets/Scripts/Core/
- Editor scripts → Assets/Scripts/Editor/ (only compiled in Editor)
- Never use deprecated Unity APIs
- Version: %s
]], version)
  elseif pt == "rust" then
    type_hints = [[
## Rust-specific rules
- Use idiomatic Rust (clippy-clean)
- Prefer Result<T,E> over unwrap() in library code
- Keep unsafe blocks minimal and documented
- Add doc comments (///) to public items
]]
  elseif pt == "node" then
    type_hints = [[
## TypeScript/Node-specific rules
- Prefer strict TypeScript — avoid `any`
- Use ES2022+ syntax
- Export types explicitly
- Keep functions pure where possible
]]
  elseif pt == "python" then
    type_hints = [[
## Python-specific rules
- Follow PEP 8 and PEP 257 (docstrings)
- Use type hints throughout
- Prefer dataclasses/Pydantic for data models
- Avoid mutable default arguments
]]
  elseif pt == "go" then
    type_hints = [[
## Go-specific rules
- Follow effective Go conventions
- Return errors explicitly (don't panic)
- Add comments to all exported symbols
- Keep goroutines and channels documented
]]
  end

  -- Build session history block (empty string = omit section entirely)
  local session_block = ""
  if session_context ~= "" then
    session_block = "## What has been built in this session (read before writing anything)\n"
      .. session_context .. "\n"
  end

  return string.format([[
You are a %s developer. Your job is to write code, not explore.

## CRITICAL RULES — read before anything else
1. DO NOT spend more than one tool call on exploration.
2. Write the required file(s) IMMEDIATELY.
3. ALWAYS read a file with the Read tool before editing or overwriting it.
4. When done, output a line containing ONLY the word: DONE

## Persistent memory — read these two files first (one tool call each):
- %s/%s
- %s/%s

## Project
Path: %s
Technology: %s
Version: %s

## Existing source files (for reference only — do not re-read all of them)
%s

## Directory layout
%s
%s
%s
%s
%s
## Section context (other tasks in this batch for coherence)
%s

## Task #%s — implement this now
%s

## Your action sequence (follow exactly, in order)
1. Read %s/%s
2. Read %s/%s
3. Write the required file(s)
4. Append a one-line discovery note to %s/%s
5. Output exactly: DONE
]],
    tech,
    cfg.PROJECT_PATH, cfg.PROGRESS_FILE,
    cfg.PROJECT_PATH, cfg.AGENTS_FILE,
    cfg.PROJECT_PATH,
    tech,
    version,
    existing_sources_list(),
    src_dir_listing(),
    retry_block,
    type_hints,
    tool_context,
    session_block,
    section_context,
    task_num,
    task_text,
    cfg.PROJECT_PATH, cfg.PROGRESS_FILE,
    cfg.PROJECT_PATH, cfg.AGENTS_FILE,
    cfg.PROJECT_PATH, cfg.AGENTS_FILE)
end

-- ---------------------------------------------------------------------------
-- build_fix_prompt
-- ---------------------------------------------------------------------------
function M.build_fix_prompt(opts)
  local task_num       = opts.task_num
  local task_text      = opts.task_text
  local compile_errors = opts.compile_errors or ""
  local version        = opts.version or "unknown"
  local session_context = opts.session_context or ""

  local tech = project_type.get_tech(cfg)

  local session_block = ""
  if session_context ~= "" then
    session_block = "## What has been built in this session\n" .. session_context .. "\n"
  end

  return string.format([[
You are a %s developer. Fix compile/check errors — do not explore.

## CRITICAL RULES
1. Read each file BEFORE editing — editing without reading first will fail.
2. Open the file(s) listed in the errors below IMMEDIATELY.
3. Fix ONLY the reported errors. Do not restructure working code.
4. Output a line containing ONLY: DONE

## Read these first (one call each):
- %s/%s
- %s/%s
%s
## Task that was implemented
#%s: %s

## Errors to fix NOW
%s

## Existing source files
%s

## Action sequence
1. Read %s/%s
2. Read %s/%s
3. Read the file(s) listed in the errors (Read tool)
4. Edit the file(s) to fix the errors (Edit tool)
5. Output exactly: DONE
]],
    tech,
    cfg.PROJECT_PATH, cfg.PROGRESS_FILE,
    cfg.PROJECT_PATH, cfg.AGENTS_FILE,
    session_block,
    task_num, task_text,
    compile_errors,
    existing_sources_list(),
    cfg.PROJECT_PATH, cfg.PROGRESS_FILE,
    cfg.PROJECT_PATH, cfg.AGENTS_FILE)
end

-- ---------------------------------------------------------------------------
-- build_self_improve_prompt
-- ---------------------------------------------------------------------------
local MAX_SOURCE_CHARS = 24000   -- ~6k tokens; keeps us well inside context limits

function M.build_self_improve_prompt(opts)
  local mod_name       = opts.mod_name
  local current_source = opts.current_source or ""
  local reason         = opts.reason or "general"
  local context_str    = opts.context_str or ""
  local progress       = opts.progress or ""

  -- Guard: truncate oversized sources with a visible marker so the model knows
  if #current_source > MAX_SOURCE_CHARS then
    current_source = current_source:sub(1, MAX_SOURCE_CHARS)
      .. "\n\n-- [SOURCE TRUNCATED FOR CONTEXT — " .. #(opts.current_source) .. " chars total]\n"
  end

  return string.format([[
You are an expert Lua developer improving a programming automation orchestration system.

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
]],
    reason, context_str, progress, mod_name, current_source)
end

-- ---------------------------------------------------------------------------
-- build_query_prompt — lightweight one-shot Q&A (no file writing expected)
-- ---------------------------------------------------------------------------
function M.build_query_prompt(opts)
  local question        = opts.question or ""
  local version         = opts.version  or "unknown"
  local session_context = opts.session_context or ""
  local tech     = project_type.get_tech(cfg)
  local src_dirs = project_type.get_src_dirs(cfg)

  local dir_lines = {}
  for _, d in ipairs(src_dirs) do
    dir_lines[#dir_lines+1] = "- " .. cfg.PROJECT_PATH .. "/" .. d
  end

  local session_block = ""
  if session_context ~= "" then
    session_block = "## What has been built in this session\n" .. session_context .. "\n"
  end

  return string.format([[
You are a %s developer assistant. Answer the question below concisely.

## Project
Path: %s
Technology: %s
Version: %s

## Source layout
%s

## Existing files (for context)
%s
%s
## Question
%s

## Rules
- Answer directly. Do NOT write or modify any files unless explicitly asked.
- Do NOT output DONE.
- Keep your answer concise and focused.
]],
    tech,
    cfg.PROJECT_PATH,
    tech,
    version,
    table.concat(dir_lines, "\n"),
    existing_sources_list(),
    session_block,
    question)
end
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
