--[[
  modules/prompts.lua — task and fix prompt builders, nudge rotation.
  AI-rewritable — this is the highest-value module for self-improvement.
]]

local M = {}

local cfg = require("config")

-- ---------------------------------------------------------------------------
-- Helper: list existing C# scripts
-- ---------------------------------------------------------------------------
local function existing_scripts_list()
  local handle = io.popen(string.format(
    'find "%s/Assets/Scripts" -name "*.cs" 2>/dev/null | grep -v Library | grep -v Temp | head -40',
    cfg.PROJECT_PATH))
  if not handle then return "none yet — fresh project" end
  local paths = {}
  for line in handle:lines() do
    paths[#paths+1] = line:gsub(cfg.PROJECT_PATH .. "/", "")
  end
  handle:close()
  if #paths == 0 then return "none yet — fresh project" end
  return table.concat(paths, ", ")
end

-- ---------------------------------------------------------------------------
-- Helper: read a state file for context injection
-- ---------------------------------------------------------------------------
local function read_state_file(rel_path)
  local f = io.open(cfg.PROJECT_PATH .. "/" .. rel_path, "r")
  if not f then return "(not found)" end
  local s = f:read("*a"); f:close()
  return s
end

-- ---------------------------------------------------------------------------
-- build_task_prompt
-- ---------------------------------------------------------------------------
function M.build_task_prompt(opts)
  local task_num       = opts.task_num
  local task_text      = opts.task_text
  local section_context = opts.section_context or ""
  local iteration      = opts.iteration or 1
  local prior_note     = opts.prior_note or "No details recorded."
  local unity_version  = opts.unity_version or "unknown"
  local tool_context   = opts.tool_context or ""

  local retry_block = ""
  if iteration > 1 then
    retry_block = string.format([[

## !! RETRY — iteration %d/%d !!
Previous attempt(s) made NO file changes. This is unacceptable.
What was noted: %s
DO NOT explore or ls again. Skip straight to writing the file.
Target path: %s/Assets/Scripts/Core/
Create the file NOW using write_file or a shell command.
]], iteration, cfg.MAX_ITERATIONS, prior_note, cfg.PROJECT_PATH)
  end

  return string.format([[
You are a Unity %s C# developer. Your job is to write code, not explore.

## CRITICAL RULES — read before anything else
1. DO NOT spend more than one tool call on exploration.
2. Write the required .cs file(s) IMMEDIATELY.
3. Output directory already exists: %s/Assets/Scripts/Core/
4. ALWAYS read a file with the Read tool before editing or overwriting it.
5. When done, output a line containing ONLY the word: DONE

## Persistent memory — read these two files first (one tool call each):
- %s/%s
- %s/%s

## Project
Path: %s
Unity: %s
Namespace: IchorAndBone.Core

## Existing scripts (for reference only — do not re-read all of them)
%s

## Directory layout
- %s/Assets/Scripts/Core/    ← write new MonoBehaviours HERE
- %s/Assets/Scripts/Editor/  ← editor-only scripts
- %s/Assets/ScriptableObjects/
- %s/Assets/Shaders/
%s
%s

## Section context
%s

## Task #%s — implement this now
%s

## Your action sequence (follow exactly, in order)
1. Read %s/%s
2. Read %s/%s
3. Write the required file(s) to %s/Assets/Scripts/Core/
4. Append a one-line discovery note to %s/%s
5. Output exactly: DONE
]],
    unity_version,
    cfg.PROJECT_PATH,
    cfg.PROJECT_PATH, cfg.PROGRESS_FILE,
    cfg.PROJECT_PATH, cfg.AGENTS_FILE,
    cfg.PROJECT_PATH,
    unity_version,
    existing_scripts_list(),
    cfg.PROJECT_PATH,
    cfg.PROJECT_PATH,
    cfg.PROJECT_PATH,
    cfg.PROJECT_PATH,
    retry_block,
    tool_context,
    section_context,
    task_num,
    task_text,
    cfg.PROJECT_PATH, cfg.PROGRESS_FILE,
    cfg.PROJECT_PATH, cfg.AGENTS_FILE,
    cfg.PROJECT_PATH,
    cfg.PROJECT_PATH, cfg.AGENTS_FILE)
end

-- ---------------------------------------------------------------------------
-- build_fix_prompt
-- ---------------------------------------------------------------------------
function M.build_fix_prompt(opts)
  local task_num      = opts.task_num
  local task_text     = opts.task_text
  local compile_errors = opts.compile_errors or ""
  local unity_version = opts.unity_version or "unknown"

  return string.format([[
You are a Unity %s C# developer. Fix compile errors — do not explore.

## CRITICAL RULES
1. Read each file BEFORE editing — editing without reading first will fail.
2. Open the file(s) listed in the errors below immediately.
3. Fix ONLY the reported errors. Do not restructure working code.
4. Output a line containing ONLY: DONE

## Read these first (one call each):
- %s/%s
- %s/%s

## Task that was implemented
#%s: %s

## Compile errors to fix NOW
%s

## Files in Assets/Scripts/
%s

## Action sequence
1. Read %s/%s
2. Read %s/%s
3. Read the file(s) listed in the errors (Read tool)
4. Edit the file(s) to fix the errors (Edit tool)
5. Output exactly: DONE
]],
    unity_version,
    cfg.PROJECT_PATH, cfg.PROGRESS_FILE,
    cfg.PROJECT_PATH, cfg.AGENTS_FILE,
    task_num, task_text,
    compile_errors,
    existing_scripts_list(),
    cfg.PROJECT_PATH, cfg.PROGRESS_FILE,
    cfg.PROJECT_PATH, cfg.AGENTS_FILE)
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
}

M.FIX_NUDGE_PROMPT =
  "Continue fixing the compile errors. Output DONE when all errors are resolved."

function M.get_nudge(count)
  return _NUDGE_PROMPTS[((count - 1) % #_NUDGE_PROMPTS) + 1]
end

return M
