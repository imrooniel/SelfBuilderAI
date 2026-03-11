--[[
  modules/compile.lua — two-layer compile/check driver.
  AI-rewritable.

  Delegates the actual compile and check commands to the project_type profile
  resolved from cfg.PROJECT_TYPE. Falls back gracefully when tools are absent.

  Public API:
    run_compile_check(error_out)  → bool (true = clean)
    read_errors(error_out)        → list of error strings
    read_errors_raw(error_out)    → raw file content string
]]

local M = {}

local cfg          = require("config")
local logging      = require("logging")
local project_type = require("project_type")

-- ---------------------------------------------------------------------------
-- run_compile_check — run compile layer then optional check layer
-- ---------------------------------------------------------------------------
function M.run_compile_check(error_out)
  -- Clear output file
  local f = io.open(error_out, "w"); if f then f:close() end

  local profile = project_type.resolve(cfg)

  -- Layer 1: compile
  if profile.compile then
    logging.log(string.format(
      "Compile check [%s] — running...", cfg.PROJECT_TYPE))
    local compile_result = { pcall(profile.compile, cfg) }
    if not compile_result[1] then
      -- pcall caught a Lua error in the compile function itself
      local fa = io.open(error_out, "a")
      if fa then fa:write("ERROR: compile layer crashed: " .. tostring(compile_result[2]) .. "\n"); fa:close() end
    else
      local layer_ok     = compile_result[2]
      local layer_errors = compile_result[3] or ""
      if not layer_ok and layer_errors ~= "" then
        local fa = io.open(error_out, "a")
        if fa then
          for line in (layer_errors .. "\n"):gmatch("([^\n]*)\n") do
            if line ~= "" then fa:write("ERROR: " .. line .. "\n") end
          end
          fa:close()
        end
      end
    end
  else
    logging.log(string.format(
      "Compile check: no compile step defined for project type '%s' — skipping.", cfg.PROJECT_TYPE))
  end

  -- Layer 2: static analysis / check
  -- Failures are written as ERROR: lines and ARE blocking. Set profile.check = nil
  -- in project_type.lua to make a check layer advisory-only for a given project type.
  if profile.check then
    logging.log("Running secondary check pass...")
    local check_result = { pcall(profile.check, cfg) }
    if not check_result[1] then
      local fa = io.open(error_out, "a")
      if fa then fa:write("ERROR: check layer crashed: " .. tostring(check_result[2]) .. "\n"); fa:close() end
    else
      local layer_ok     = check_result[2]
      local layer_errors = check_result[3] or ""
      if layer_errors:match("^SKIPPED:") then
        logging.warn("Secondary check: " .. layer_errors)
      elseif not layer_ok and layer_errors ~= "" then
        local fa = io.open(error_out, "a")
        if fa then
          for line in (layer_errors .. "\n"):gmatch("([^\n]*)\n") do
            if line ~= "" then fa:write("ERROR: " .. line .. "\n") end
          end
          fa:close()
        end
      end
    end
  end

  -- Deduplicate and sort the error file
  local ef = io.open(error_out, "r")
  if ef then
    local seen   = {}
    local deduped = {}
    for line in ef:lines() do
      if not seen[line] then seen[line] = true; deduped[#deduped+1] = line end
    end
    ef:close()

    -- Filter: only ERROR: lines count as blocking failures
    local blocking = {}
    for _, line in ipairs(deduped) do
      if line:match("^ERROR:") then blocking[#blocking+1] = line end
    end

    if #blocking > 0 then
      local fw = io.open(error_out, "w")
      if fw then
        table.sort(blocking)
        fw:write(table.concat(blocking, "\n") .. "\n"); fw:close()
      end
      return false
    end
  end

  local fw = io.open(error_out, "w")
  if fw then fw:write("COMPILE_OK\n"); fw:close() end
  return true
end

-- ---------------------------------------------------------------------------
-- read_errors — return list of ERROR: lines
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
