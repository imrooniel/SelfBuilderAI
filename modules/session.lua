--[[
  modules/session.lua — session lifecycle helpers.
  AI-rewritable.
]]

local M = {}

local cfg     = require("config")
local logging = require("logging")

-- ---------------------------------------------------------------------------
-- Unity version detection
-- ---------------------------------------------------------------------------
function M.get_unity_version()
  local pv_path = cfg.PROJECT_PATH .. "/ProjectSettings/ProjectVersion.txt"
  local f = io.open(pv_path, "r")
  if not f then return "unknown" end
  for line in f:lines() do
    local v = line:match("m_EditorVersion:%s+(%S+)")
    if v then f:close(); return v end
  end
  f:close()
  return "unknown"
end

-- ---------------------------------------------------------------------------
-- Session archiving
-- ---------------------------------------------------------------------------
function M.handle_session_archive()
  local last_file = cfg.PROJECT_PATH .. "/" .. cfg.LAST_SESSION_FILE
  local f = io.open(last_file, "r")
  if f then
    local last = f:read("*l"); f:close()
    if last and last ~= "" and last ~= cfg.SESSION_NAME then
      local date_str     = os.date("%Y-%m-%d")
      local archive_dir  = string.format("%s/%s/%s-%s",
        cfg.PROJECT_PATH, cfg.ARCHIVE_DIR, date_str, last)
      logging.log(string.format(
        "Session changed (%s → %s) — archiving previous run...", last, cfg.SESSION_NAME))
      os.execute('mkdir -p "' .. archive_dir .. '"')
      for _, fname in ipairs({ cfg.PROGRESS_FILE, cfg.AGENTS_FILE }) do
        local src = cfg.PROJECT_PATH .. "/" .. fname
        os.execute(string.format('cp "%s" "%s/" 2>/dev/null', src, archive_dir))
      end
      logging.log("Archived to: " .. archive_dir)
      -- Reset progress for new session
      local pf = io.open(cfg.PROJECT_PATH .. "/" .. cfg.PROGRESS_FILE, "w")
      if pf then pf:write(""); pf:close() end
    end
  end
  local fw = io.open(last_file, "w")
  if fw then fw:write(cfg.SESSION_NAME); fw:close() end
end

-- ---------------------------------------------------------------------------
-- Bootstrap Ralph state files
-- ---------------------------------------------------------------------------
function M.ensure_state_files(unity_version)
  local pf_path = cfg.PROJECT_PATH .. "/" .. cfg.PROGRESS_FILE
  local pf = io.open(pf_path, "r")
  if not pf then
    local fw = io.open(pf_path, "w")
    if fw then
      fw:write("# Progress Log\n")
      fw:write("Append-only learnings discovered during each task iteration.\n")
      fw:write("The model reads this at the start of every fresh context window.\n")
      fw:close()
    end
  else
    pf:close()
  end

  local af_path = cfg.PROJECT_PATH .. "/" .. cfg.AGENTS_FILE
  local af = io.open(af_path, "r")
  if not af then
    local fw = io.open(af_path, "w")
    if fw then
      fw:write(string.format([[
# AGENTS.md — Unity Project Codebase Patterns
Auto-updated by the task runner after each completed task.
The model reads this at the start of every iteration.

## Project: LeviatanHunt
Unity version: %s

## Layout
- Assets/Scripts/Core/      — MonoBehaviour scripts
- Assets/Scripts/Editor/    — Editor-only scripts
- Assets/Shaders/           — Shader files
- Assets/ScriptableObjects/ — Data assets

## Conventions
- Follow standard Unity C# naming conventions
- MonoBehaviours go in Assets/Scripts/Core/
- Editor scripts go in Assets/Scripts/Editor/

## Known Patterns
<!-- The model appends discoveries here after each task -->
]], unity_version))
      fw:close()
    end
  else
    af:close()
  end
end

-- ---------------------------------------------------------------------------
-- Model selection
-- ---------------------------------------------------------------------------
function M.select_model()
  print("Fetching Ollama models...")
  local cfg_mod = require("config")
  local handle = io.popen(string.format('"%s" models 2>/dev/null', cfg_mod.OPENCODE))
  local models = {}
  if handle then
    for line in handle:lines() do
      if line:match("^ollama/") then
        models[#models+1] = line:gsub("^ollama/", "")
      end
    end
    handle:close()
  end

  if #models == 0 then
    logging.err("No Ollama models found. Is Ollama running?"); os.exit(1)
  end

  print("\nAvailable Ollama models:")
  for i, m in ipairs(models) do
    print(string.format("  %d) %s", i, m))
  end
  print()

  io.write("Select model number: ")
  local choice = io.read()
  local idx = tonumber(choice)
  if not idx or idx < 1 or idx > #models then
    logging.err("Invalid selection: '" .. tostring(choice) .. "'"); os.exit(1)
  end

  local selected = "ollama/" .. models[idx]
  logging.log("Using model: " .. selected)
  return selected
end

-- ---------------------------------------------------------------------------
-- Progress log helpers
-- ---------------------------------------------------------------------------
function M.append_progress(task_num, task_text, note)
  local ts = os.date("%Y-%m-%d %H:%M")
  local pf = io.open(cfg.PROJECT_PATH .. "/" .. cfg.PROGRESS_FILE, "a")
  if pf then
    pf:write(string.format("\n## [%s] Task #%s: %s\n%s\n", ts, task_num, task_text, note))
    pf:close()
  end
end

return M
