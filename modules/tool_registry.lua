--[[
  modules/tool_registry.lua — dynamic tool loading and calling.

  The AI agent can write new Lua files to tools/ at runtime.
  This module scans tools/, loads them, and:
    1. Injects a description of available tools into every task prompt
    2. Parses the AI's log output for TOOL_CALL directives
    3. Executes the requested tool and appends the result to the log

  Tool contract
  ─────────────
  Every file in tools/ must return a table with:
    {
      name        = "tool_name",          -- matches filename without .lua
      description = "what this tool does",
      params      = "param description",  -- shown in prompt
      run         = function(params_str)  -- receives raw param string
                      return result_string, err_string_or_nil
                    end,
    }

  The AI triggers a tool by writing in its output (anywhere on its own line):
    TOOL_CALL: tool_name | param string here

  The orchestrator reads completed log files, extracts TOOL_CALL lines,
  runs the tools, and appends results as:
    TOOL_RESULT: tool_name | <result or ERROR: msg>
]]

local M = {}

local cfg     = require("config")
local logging = require("logging")

-- Registry: name → tool table
local _tools = {}

-- ---------------------------------------------------------------------------
-- Internal: load one tool file
-- ---------------------------------------------------------------------------
local function load_tool_file(path)
  local ok, result = pcall(dofile, path)
  if not ok then
    logging.warn("tool_registry: failed to load " .. path .. ": " .. tostring(result))
    return nil
  end
  if type(result) ~= "table" or type(result.run) ~= "function" then
    logging.warn("tool_registry: " .. path .. " did not return a valid tool table")
    return nil
  end
  return result
end

-- ---------------------------------------------------------------------------
-- bootstrap — scan tools/ and register all .lua files found
-- ---------------------------------------------------------------------------
function M.bootstrap()
  local tools_dir = cfg.PROJECT_PATH .. "/../tools"   -- relative to project
  -- Also scan next to run_automation.lua
  local dirs = {
    tools_dir,
    -- script-relative tools/ (resolved via package.path search)
    package.path:match("(.-)/modules/") and
      package.path:match("(.-)/modules/") .. "/tools" or nil,
  }

  for _, dir in ipairs(dirs) do
    if dir then
      local handle = io.popen('ls "' .. dir .. '"/*.lua 2>/dev/null')
      if handle then
        for path in handle:lines() do
          local tool = load_tool_file(path)
          if tool and tool.name then
            _tools[tool.name] = tool
            logging.log("tool_registry: registered tool '" .. tool.name .. "'")
          end
        end
        handle:close()
      end
    end
  end

  local count = 0
  for _ in pairs(_tools) do count = count + 1 end
  if count > 0 then
    logging.log(string.format("tool_registry: %d tool(s) available.", count))
  end
end

-- ---------------------------------------------------------------------------
-- register — register a tool table directly (used after AI writes a new one)
-- ---------------------------------------------------------------------------
function M.register(tool)
  if type(tool) ~= "table" or not tool.name or type(tool.run) ~= "function" then
    return false, "invalid tool table"
  end
  _tools[tool.name] = tool
  logging.ok("tool_registry: registered new tool '" .. tool.name .. "'")
  return true
end

-- ---------------------------------------------------------------------------
-- describe_tools — returns a string block injected into task prompts
-- ---------------------------------------------------------------------------
function M.describe_tools()
  local count = 0
  for _ in pairs(_tools) do count = count + 1 end
  if count == 0 then
    return "(No custom tools registered yet. You may create tools by writing a\n" ..
           "Lua file to the tools/ directory with the tool contract described in\n" ..
           "tool_registry.lua, then outputting: TOOL_CALL: register_tool | <path>)"
  end

  local lines = {
    "## Available custom tools",
    "Invoke by outputting on its own line: TOOL_CALL: <name> | <params>",
    "",
  }
  for name, tool in pairs(_tools) do
    lines[#lines+1] = string.format("  %-20s — %s", name, tool.description or "")
    if tool.params then
      lines[#lines+1] = string.format("    params: %s", tool.params)
    end
  end
  lines[#lines+1] = ""
  lines[#lines+1] = "You may also CREATE a new tool by writing tools/<name>.lua and then"
  lines[#lines+1] = "calling: TOOL_CALL: register_tool | tools/<name>.lua"
  return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Built-in meta-tool: register_tool
-- Lets the AI register a newly written .lua tool file at runtime.
-- ---------------------------------------------------------------------------
local function builtin_register_tool(params_str)
  local path = params_str:match("^%s*(.-)%s*$")  -- trim whitespace
  -- Resolve relative to project path
  if not path:match("^/") then
    path = cfg.PROJECT_PATH .. "/../" .. path
  end
  local tool = load_tool_file(path)
  if not tool then
    return nil, "failed to load tool from: " .. path
  end
  _tools[tool.name] = tool
  return "registered tool '" .. (tool.name or "?") .. "' from " .. path, nil
end

_tools["register_tool"] = {
  name        = "register_tool",
  description = "Register a newly written Lua tool file at runtime",
  params      = "path to the .lua tool file (relative to project root or absolute)",
  run         = builtin_register_tool,
}

-- ---------------------------------------------------------------------------
-- process_tool_calls — parse a completed log file for TOOL_CALL lines,
-- run them, and append TOOL_RESULT lines back to the log.
-- ---------------------------------------------------------------------------
function M.process_tool_calls(log_file, task_num, run_ts)
  local f = io.open(log_file, "r")
  if not f then return end
  local content = f:read("*a"); f:close()

  local results = {}
  local any = false

  for line in content:gmatch("[^\n]+") do
    local name, params = line:match("^TOOL_CALL:%s*([%w_%-]+)%s*|%s*(.*)$")
    if name then
      any = true
      local tool = _tools[name]
      if not tool then
        results[#results+1] = string.format("TOOL_RESULT: %s | ERROR: unknown tool '%s'", name, name)
        logging.warn("tool_registry: unknown tool called: " .. name)
      else
        logging.log(string.format("tool_registry: running tool '%s' | %s", name, params))
        local ok2, result, err = pcall(tool.run, params)
        if not ok2 then
          results[#results+1] = string.format("TOOL_RESULT: %s | ERROR: %s", name, tostring(result))
        elseif err then
          results[#results+1] = string.format("TOOL_RESULT: %s | ERROR: %s", name, err)
        else
          results[#results+1] = string.format("TOOL_RESULT: %s | %s", name, tostring(result or ""))
          logging.ok(string.format("tool_registry: tool '%s' succeeded.", name))
        end
      end
    end
  end

  if any and #results > 0 then
    local fa = io.open(log_file, "a")
    if fa then
      fa:write("\n--- TOOL RESULTS ---\n")
      for _, r in ipairs(results) do fa:write(r .. "\n") end
      fa:close()
    end
  end
end

return M
