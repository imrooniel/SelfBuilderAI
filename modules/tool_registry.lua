--[[
  modules/tool_registry.lua — dynamic tool loading and calling.
  AI-rewritable.

  The AI agent can write new Lua files to tools/ at runtime.
  This module scans tools/, loads them, and:
    1. Injects a description of available tools into every task prompt
    2. Parses the AI's log output for TOOL_CALL directives
    3. Executes the requested tool and appends the result to the log

  Tool contract
  ─────────────
  Every file in tools/ must return a table with:
    {
      name        = "tool_name",
      description = "what this tool does",
      params      = "param description",
      run         = function(params_str) → result_string, err_string_or_nil
    }

  The AI triggers a tool by writing (anywhere on its own line):
    TOOL_CALL: tool_name | param string here
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
  local dirs = {}

  -- tools/ next to run_automation.lua
  local base = package.path:match("(.-)/modules/")
  if base then dirs[#dirs+1] = base .. "/tools" end

  -- tools/ inside project
  dirs[#dirs+1] = cfg.PROJECT_PATH .. "/tools"

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
  if count > 1 then   -- >1 because register_tool is always present
    logging.log(string.format("tool_registry: %d tool(s) available.", count))
  end
end

-- ---------------------------------------------------------------------------
-- register — register a tool table directly
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
  -- Don't clutter the prompt if only the built-in meta-tool is present
  if count <= 1 then
    return "(No custom tools registered yet. Write a Lua file to tools/ following the\n" ..
           "tool contract in tool_registry.lua, then call: TOOL_CALL: register_tool | <path>)"
  end

  local lines = {
    "## Available custom tools",
    "Invoke by outputting on its own line: TOOL_CALL: <name> | <params>",
    "",
  }
  for name, tool in pairs(_tools) do
    if name ~= "register_tool" then
      lines[#lines+1] = string.format("  %-24s — %s", name, tool.description or "")
      if tool.params then
        lines[#lines+1] = string.format("    params: %s", tool.params)
      end
    end
  end
  lines[#lines+1] = ""
  lines[#lines+1] = "You may also CREATE a new tool by writing tools/<name>.lua and then"
  lines[#lines+1] = "calling: TOOL_CALL: register_tool | tools/<name>.lua"
  return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Built-in meta-tool: register_tool
-- ---------------------------------------------------------------------------
local function builtin_register_tool(params_str)
  local path = params_str:match("^%s*(.-)%s*$")
  if not path:match("^/") then
    path = cfg.PROJECT_PATH .. "/" .. path
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
-- Built-in utility tool: run_shell
-- Lets the AI run read-only shell commands and capture output.
--
-- SECURITY NOTE: This is a best-effort safety layer, not a sandbox. It blocks
-- common destructive patterns but cannot enumerate every dangerous invocation.
-- Do not rely on this for untrusted input. For stronger isolation, run the
-- entire Lua process inside a container or bubblewrap sandbox.
-- ---------------------------------------------------------------------------
_tools["run_shell"] = {
  name        = "run_shell",
  description = "Run a read-only shell command and return stdout (max 200 lines)",
  params      = "shell command to execute (avoid commands that mutate files)",
  run = function(params_str)
    local cmd = params_str:match("^%s*(.-)%s*$")
    if cmd == "" then return nil, "run_shell: empty command" end

    -- Denylist: block obviously destructive or escape-prone patterns.
    -- This is NOT exhaustive — it catches common accidents, not adversarial input.
    local blocked_patterns = {
      -- Destructive filesystem ops
      "rm%s", "rmdir%s", "unlink%s", "shred%s",
      "mkfs", "fdisk", "dd%s",
      -- Privilege escalation
      "sudo%s", "su%s", "pkexec",
      -- Execution of arbitrary code
      "curl%s.-%|", "wget%s.-%|",   -- pipe-to-shell download patterns
      "python%d?%s+-c%s", "perl%s+-e%s", "ruby%s+-e%s",
      "bash%s+-c%s", "sh%s+-c%s", "zsh%s+-c%s",
      "eval%s", "exec%s",
      -- Redirect to sensitive paths
      ">%s*/",
      -- Fork bomb skeleton
      ":%(%){",
      -- Sensitive env / credential access
      "%.aws/", "%.ssh/", "%.gnupg/",
    }
    local cmd_lower = cmd:lower()
    for _, pat in ipairs(blocked_patterns) do
      if cmd_lower:find(pat) then
        return nil, "run_shell: blocked pattern '" .. pat .. "' in command"
      end
    end

    local handle = io.popen(cmd .. " 2>&1 | head -200")
    if not handle then return nil, "run_shell: popen failed" end
    local result = handle:read("*a")
    handle:close()
    if result == "" then return "(no output)", nil end
    return result, nil
  end,
}

-- ---------------------------------------------------------------------------
-- Built-in utility tool: grep_project
-- ---------------------------------------------------------------------------
_tools["grep_project"] = {
  name        = "grep_project",
  description = "Grep for a pattern across all source files in the project",
  params      = "pattern string to search for",
  run = function(params_str)
    local pattern = params_str:match("^%s*(.-)%s*$")
    if not pattern or pattern == "" then
      return nil, "grep_project: empty pattern"
    end
    pattern = pattern:gsub('"', '\\"')
    local cmd = string.format(
      'grep -rn "%s" "%s" --include="*.lua" --include="*.py" --include="*.ts" '
      .. '--include="*.js" --include="*.rs" --include="*.go" --include="*.cs" '
      .. '--include="*.cpp" --include="*.c" --include="*.h" '
      .. '2>/dev/null | grep -v node_modules | grep -v ".git" | head -60',
      pattern, cfg.PROJECT_PATH)
    local handle = io.popen(cmd)
    if not handle then return nil, "grep_project: popen failed" end
    local result = handle:read("*a")
    handle:close()
    if result == "" then return "No matches found for: " .. pattern, nil end
    return result, nil
  end,
}

-- ---------------------------------------------------------------------------
-- Built-in utility tool: list_files
-- ---------------------------------------------------------------------------
_tools["list_files"] = {
  name        = "list_files",
  description = "List source files in a directory (relative to PROJECT_PATH)",
  params      = "relative path from project root (e.g. 'src' or '.')",
  run = function(params_str)
    local rel = params_str:match("^%s*(.-)%s*$")
    if rel == "" then rel = "." end
    local dir = cfg.PROJECT_PATH .. "/" .. rel
    local handle = io.popen(string.format(
      'find "%s" -type f -not -path "*/.git/*" -not -path "*/node_modules/*" 2>/dev/null | head -100',
      dir))
    if not handle then return nil, "list_files: popen failed" end
    local result = handle:read("*a")
    handle:close()
    if result == "" then return "(no files found in: " .. rel .. ")", nil end
    return result:gsub(cfg.PROJECT_PATH .. "/", ""), nil
  end,
}

-- ---------------------------------------------------------------------------
-- process_tool_calls — parse a completed log file for TOOL_CALL lines
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
