--[[
  modules/session.lua — session lifecycle helpers.
  AI-rewritable.
]]

local M = {}

local cfg          = require("config")
local logging      = require("logging")
local project_type = require("project_type")

-- ---------------------------------------------------------------------------
-- Project version detection (language-aware)
-- ---------------------------------------------------------------------------
function M.get_project_version()
  local pt = cfg.PROJECT_TYPE

  if pt == "unity" then
    local pv = cfg.PROJECT_PATH .. "/ProjectSettings/ProjectVersion.txt"
    local f = io.open(pv, "r")
    if not f then return "unknown" end
    for line in f:lines() do
      local v = line:match("m_EditorVersion:%s+(%S+)")
      if v then f:close(); return v end
    end
    f:close(); return "unknown"
  end

  if pt == "rust" then
    local f = io.open(cfg.PROJECT_PATH .. "/Cargo.toml", "r")
    if f then
      for line in f:lines() do
        local v = line:match('^version%s*=%s*"([^"]+)"')
        if v then f:close(); return v end
      end
      f:close()
    end
    local h = io.popen("rustc --version 2>/dev/null")
    local r = h and h:read("*l") or "unknown"; if h then h:close() end
    return r
  end

  if pt == "node" then
    local f = io.open(cfg.PROJECT_PATH .. "/package.json", "r")
    if f then
      local content = f:read("*a"); f:close()
      local v = content:match('"version"%s*:%s*"([^"]+)"')
      if v then return v end
    end
    local h = io.popen("node --version 2>/dev/null")
    local r = h and h:read("*l") or "unknown"; if h then h:close() end
    return r
  end

  if pt == "python" then
    local h = io.popen("python3 --version 2>/dev/null")
    local r = h and h:read("*l") or "unknown"; if h then h:close() end
    return r
  end

  if pt == "go" then
    local f = io.open(cfg.PROJECT_PATH .. "/go.mod", "r")
    if f then
      for line in f:lines() do
        local v = line:match("^go%s+(%S+)")
        if v then f:close(); return "go " .. v end
      end
      f:close()
    end
    local h = io.popen("go version 2>/dev/null")
    local r = h and h:read("*l") or "unknown"; if h then h:close() end
    return r
  end

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
      local date_str    = os.date("%Y-%m-%d")
      local archive_dir = string.format("%s/%s/%s-%s",
        cfg.PROJECT_PATH, cfg.ARCHIVE_DIR, date_str, last)
      logging.log(string.format(
        "Session changed (%s → %s) — archiving previous run...", last, cfg.SESSION_NAME))
      os.execute('mkdir -p "' .. archive_dir .. '"')
      for _, fname in ipairs({ cfg.PROGRESS_FILE, cfg.AGENTS_FILE }) do
        local src = cfg.PROJECT_PATH .. "/" .. fname
        os.execute(string.format('cp "%s" "%s/" 2>/dev/null', src, archive_dir))
      end
      logging.log("Archived to: " .. archive_dir)
      local pf = io.open(cfg.PROJECT_PATH .. "/" .. cfg.PROGRESS_FILE, "w")
      if pf then pf:write(""); pf:close() end
    end
  end
  local fw = io.open(last_file, "w")
  if fw then fw:write(cfg.SESSION_NAME); fw:close() end
end

-- ---------------------------------------------------------------------------
-- Bootstrap state files
-- ---------------------------------------------------------------------------
function M.ensure_state_files(version)
  local tech = project_type.get_tech(cfg)
  local src_dirs = project_type.get_src_dirs(cfg)

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
      local dir_lines = {}
      for _, d in ipairs(src_dirs) do
        dir_lines[#dir_lines+1] = "- " .. d
      end
      fw:write(string.format([[
# AGENTS.md — Project Codebase Patterns
Auto-updated by the task runner after each completed task.
The model reads this at the start of every iteration.

## Project: %s
Technology: %s
Version: %s

## Source layout
%s

## Conventions
- Follow standard conventions for %s
- Write clean, idiomatic code
- Prefer small, focused modules/files

## Known Patterns
<!-- The model appends discoveries here after each task -->
]],
        cfg.SESSION_NAME, tech, version,
        table.concat(dir_lines, "\n"),
        tech))
      fw:close()
    end
  else
    af:close()
  end
end

-- ---------------------------------------------------------------------------
-- Scaffold project directory structure
-- ---------------------------------------------------------------------------
function M.scaffold_project_dirs()
  local src_dirs = project_type.get_src_dirs(cfg)
  for _, d in ipairs(src_dirs) do
    os.execute('mkdir -p "' .. cfg.PROJECT_PATH .. "/" .. d .. '"')
  end
  logging.ok("Project directory scaffold created.")
end

-- ---------------------------------------------------------------------------
-- Model selection
-- ---------------------------------------------------------------------------
function M.select_model()
  print("Fetching available models...")
  local handle = io.popen(string.format('"%s" models 2>/dev/null', cfg.OPENCODE))
  local models = {}
  if handle then
    for line in handle:lines() do
      if line:match("^ollama/") or line:match("^anthropic/") or
         line:match("^openai/") or line:match("^google/") then
        models[#models+1] = line:gsub("^%s+", ""):gsub("%s+$", "")
      end
    end
    handle:close()
  end

  if #models == 0 then
    logging.err("No models found. Is opencode running and configured?"); os.exit(1)
  end

  print("\nAvailable models:")
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

  local selected = models[idx]
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

-- ---------------------------------------------------------------------------
-- prune_old_logs — delete log files older than cfg.LOG_RETENTION_DAYS
-- ---------------------------------------------------------------------------
function M.prune_old_logs()
  if not cfg.LOG_RETENTION_DAYS then return end
  local log_dir = cfg.PROJECT_PATH .. "/logs"
  local cutoff  = os.time() - (cfg.LOG_RETENTION_DAYS * 86400)

  local handle = io.popen(string.format('ls "%s"/ 2>/dev/null', log_dir))
  if not handle then return end

  local files = {}
  for name in handle:lines() do
    if name:match("%.log$") or name:match("%.txt$") then
      files[#files+1] = log_dir .. "/" .. name
    end
  end
  handle:close()

  -- Portable mtime check: try GNU stat, fall back to BSD stat
  local stat_fmt
  local th = io.popen("stat --version 2>/dev/null")
  local tv = th and th:read("*l") or ""; if th then th:close() end
  stat_fmt = tv:find("GNU") and 'stat -c "%%Y" "%s" 2>/dev/null'
                             or 'stat -f "%%m" "%s" 2>/dev/null'

  local pruned = 0
  for _, path in ipairs(files) do
    local sh = io.popen(string.format(stat_fmt, path))
    local mtime = sh and tonumber(sh:read("*l")) or nil
    if sh then sh:close() end
    if mtime and mtime < cutoff then
      os.remove(path)
      pruned = pruned + 1
    end
  end

  if pruned > 0 then
    logging.log(string.format("Pruned %d old log file(s) (>%dd).", pruned, cfg.LOG_RETENTION_DAYS))
  end
end

return M
