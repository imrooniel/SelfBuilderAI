--[[
  modules/compile.lua — two-layer compile checking.
  AI-rewritable.

  Layer 1: Unity batch mode compile  (catches C# errors)
  Layer 2: jb inspectcode            (JetBrains static analysis)
]]

local M = {}

local cfg     = require("config")
local logging = require("logging")

-- ---------------------------------------------------------------------------
-- Availability checks
-- ---------------------------------------------------------------------------
local function unity_available()
  local f = io.open(cfg.UNITY_EDITOR, "r")
  if f then f:close(); return true end
  return false
end

local function inspectcode_available()
  local handle = io.popen("which jb 2>/dev/null")
  local result = handle and handle:read("*a") or ""
  if handle then handle:close() end
  return result:match("%S") ~= nil
end

local function find_sln()
  if cfg.SOLUTION_FILE then
    local f = io.open(cfg.SOLUTION_FILE, "r")
    if f then f:close(); return cfg.SOLUTION_FILE end
  end
  local handle = io.popen(string.format('ls "%s"/*.sln 2>/dev/null | head -1', cfg.PROJECT_PATH))
  local result = handle and handle:read("*a") or ""
  if handle then handle:close() end
  result = result:gsub("%s+$", "")
  return result ~= "" and result or nil
end

-- ---------------------------------------------------------------------------
-- Layer 1: Unity batch compile
-- ---------------------------------------------------------------------------
local function run_unity_compile(error_out)
  if not unity_available() then
    logging.warn("Unity compile SKIPPED — UNITY_EDITOR not found: " .. cfg.UNITY_EDITOR)
    return true
  end

  local unity_log = os.tmpname()
  logging.log("Running Unity batch compile (this may take 30-90s)...")

  local cmd = string.format(
    '"%s" -quit -batchmode -nographics -logFile "%s" -projectPath "%s" 2>/dev/null',
    cfg.UNITY_EDITOR, unity_log, cfg.PROJECT_PATH)

  local exit_code = os.execute(cmd)

  local errors = {}
  local f = io.open(unity_log, "r")
  if f then
    for line in f:lines() do
      if line:match("error CS%d+") then
        errors[#errors+1] = "ERROR: " .. line:gsub("^%s+", "")
      elseif line:match("Exception.*:") then
        errors[#errors+1] = "EXCEPTION: " .. line:gsub("^%s+", "")
      end
    end
    f:close()
    os.remove(unity_log)
  end

  if #errors == 0 and exit_code ~= 0 then
    errors[#errors+1] = string.format(
      "ERROR: Unity batch compile exited with code %s", tostring(exit_code))
  end

  if #errors > 0 then
    local fa = io.open(error_out, "a")
    if fa then
      for _, e in ipairs(errors) do fa:write(e .. "\n") end
      fa:close()
    end
    return false
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Layer 2: jb inspectcode
-- ---------------------------------------------------------------------------
local function run_inspectcode(error_out)
  if not inspectcode_available() then
    logging.warn("inspectcode SKIPPED — 'jb' not in PATH.")
    return true
  end

  local sln = find_sln()
  if not sln then
    logging.warn("inspectcode SKIPPED — no .sln found in " .. cfg.PROJECT_PATH)
    return true
  end

  local inspect_xml = os.tmpname()
  local inspect_log = os.tmpname()

  logging.log("Running inspectcode (secondary pass)...")
  local cmd = string.format(
    'jb inspectcode "%s" --severity=ERROR -f=Xml -o="%s" --verbosity=WARN > "%s" 2>&1',
    sln, inspect_xml, inspect_log)
  os.execute(cmd)

  local fa = io.open(error_out, "a")
  if not fa then return true end

  -- Parse plain-text log for MsBuild errors
  local fl = io.open(inspect_log, "r")
  if fl then
    for line in fl:lines() do
      if line:match("%[MsBuild%].*CS%d+") then
        fa:write("ERROR: " .. line:gsub("^%[MsBuild%] ", "") .. "\n")
      elseif line:lower():match("^%[error%]") then
        fa:write("ERROR: " .. line:gsub("^%[Ee]rror%] ?", "") .. "\n")
      end
    end
    fl:close()
    os.remove(inspect_log)
  end

  -- Parse XML output
  local fx = io.open(inspect_xml, "r")
  if fx then
    local xml = fx:read("*a"); fx:close()
    os.remove(inspect_xml)
    -- Simple pattern-based XML extraction (avoid dependency on XML lib)
    for issue in xml:gmatch("<Issue[^>]+>") do
      local file  = issue:match('File="([^"]*)"')   or "?"
      local line_ = issue:match('Line="([^"]*)"')   or "?"
      local msg   = issue:match('Message="([^"]*)"') or "?"
      fa:write(string.format("ERROR: %s(%s): %s\n", file, line_, msg))
    end
  end

  fa:close()
  return true
end

-- ---------------------------------------------------------------------------
-- run_compile_check — combined entry point
-- ---------------------------------------------------------------------------
function M.run_compile_check(error_out)
  -- Clear the error file
  local f = io.open(error_out, "w"); if f then f:close() end

  local ok1, ok2 = true, true

  local success, err_msg = pcall(run_unity_compile, error_out)
  if not success then
    logging.warn("Unity compile layer crashed: " .. tostring(err_msg))
    local fa = io.open(error_out, "a")
    if fa then fa:write("ERROR: Unity compile layer crashed: " .. tostring(err_msg) .. "\n"); fa:close() end
  end

  local success2, err_msg2 = pcall(run_inspectcode, error_out)
  if not success2 then
    logging.warn("inspectcode layer crashed: " .. tostring(err_msg2))
    local fa = io.open(error_out, "a")
    if fa then fa:write("ERROR: inspectcode layer crashed: " .. tostring(err_msg2) .. "\n"); fa:close() end
  end

  -- Deduplicate error file
  local ef = io.open(error_out, "r")
  if ef then
    local lines_seen = {}
    local deduped    = {}
    for line in ef:lines() do
      if not lines_seen[line] then
        lines_seen[line] = true
        deduped[#deduped+1] = line
      end
    end
    ef:close()
    if #deduped > 0 then
      local fw = io.open(error_out, "w")
      if fw then
        table.sort(deduped)
        fw:write(table.concat(deduped, "\n") .. "\n"); fw:close()
      end
      return false
    end
  end

  local fw = io.open(error_out, "w")
  if fw then fw:write("COMPILE_OK\n"); fw:close() end
  return true
end

-- ---------------------------------------------------------------------------
-- read_errors — return list of ERROR: / EXCEPTION: lines
-- ---------------------------------------------------------------------------
function M.read_errors(error_out)
  local errors = {}
  local f = io.open(error_out, "r")
  if not f then return errors end
  for line in f:lines() do
    if line:match("^ERROR:") or line:match("^EXCEPTION:") then
      errors[#errors+1] = line
    end
  end
  f:close()
  return errors
end

-- ---------------------------------------------------------------------------
-- read_errors_raw — return raw error file content
-- ---------------------------------------------------------------------------
function M.read_errors_raw(error_out)
  local f = io.open(error_out, "r")
  if not f then return "" end
  local s = f:read("*a"); f:close()
  return s
end

return M
