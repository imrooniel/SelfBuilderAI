--[[
  modules/opencode.lua — wrappers around the opencode CLI.
  AI-rewritable.

  Two public functions:
    run_fresh()    — start a brand-new session (Ralph outer loop)
    run_continue() — nudge an existing session (Ralph inner loop)
]]

local M = {}

local cfg     = require("config")
local logging = require("logging")

-- ---------------------------------------------------------------------------
-- Internal: classify and print a line with colour
-- ---------------------------------------------------------------------------
local _in_think_block = false

local function reset_think_state()
  _in_think_block = false
end

local function classify_and_print(line)
  line = line:gsub("\n$", "")

  if line:lower():find("<think>", 1, true) then
    _in_think_block = true
  end
  if line:lower():find("</think>", 1, true) then
    _in_think_block = false
    print(logging.dim(line))
    return
  end
  if _in_think_block then
    print(logging.dim(line))
    return
  end

  local stripped = line:match("^%s*(.-)%s*$")
  if stripped:lower():match("^thinking:") or stripped:lower():match("^%[thinking%]") then
    print(logging.dim(line))
    return
  end

  if stripped:upper() == "DONE" then
    print(logging.bold_cyan(line))
    return
  end

  local tool_markers = {
    "running tool", "tool result", "● ", "✓ ", "✗ ", "→ ", "⟳ ",
    "calling ", "read_file", "write_file", "bash", "grep", "find",
    "edit_file", "create_file", "run_command",
  }
  for _, marker in ipairs(tool_markers) do
    if stripped:lower():sub(1, #marker) == marker:lower() then
      print(logging.cyan(line))
      return
    end
  end

  print(line)
end

-- ---------------------------------------------------------------------------
-- Internal: stream a subprocess to stdout and log file simultaneously
-- ---------------------------------------------------------------------------
local function stream_cmd(cmd, log_file)
  local fa = io.open(log_file, "a")
  if fa then fa:write("$ " .. cmd .. "\n"); fa:close() end

  reset_think_state()

  local full_cmd = string.format('%s 2>&1 | tee -a "%s"', cmd, log_file)
  local handle = io.popen(full_cmd)
  if handle then
    for line in handle:lines() do
      classify_and_print(line)
    end
    handle:close()
  end
  print()
end

-- ---------------------------------------------------------------------------
-- Internal: generate a unique session title
-- ---------------------------------------------------------------------------
local function unique_title()
  return string.format("task-%d-%04x", os.time(), math.random(0, 65535))
end

-- ---------------------------------------------------------------------------
-- Internal: resolve session ID from title
-- ---------------------------------------------------------------------------
local function resolve_session_id(title)
  for _ = 1, 3 do
    local handle = io.popen(string.format('"%s" session list 2>/dev/null', cfg.OPENCODE))
    if handle then
      for line in handle:lines() do
        if line:find(title, 1, true) then
          handle:close()
          return line:match("^(%S+)")
        end
      end
      handle:close()
    end
    local t = os.time(); while os.time() - t < 1 do end
  end

  -- Fallback: newest session
  local handle = io.popen(string.format('"%s" session list 2>/dev/null', cfg.OPENCODE))
  if handle then
    local first = handle:read("*l")
    handle:close()
    if first then return first:match("^(%S+)") end
  end
  return ""
end

-- ---------------------------------------------------------------------------
-- log_says_done — detect DONE line in log.
-- Strips ANSI escape sequences and carriage returns before matching so that
-- terminal colouring or Windows-style line endings cannot prevent detection.
-- ---------------------------------------------------------------------------
function M.log_says_done(log_path)
  local f = io.open(log_path, "r")
  if not f then return false end
  for line in f:lines() do
    -- Strip ANSI CSI sequences (\027[...m) and bare \r
    local clean = line:gsub("\027%[[%d;]*%a", ""):gsub("\r", "")
    -- Trim leading/trailing whitespace then check for exact DONE
    if clean:match("^%s*DONE%s*$") then
      f:close(); return true
    end
  end
  f:close()
  return false
end

-- ---------------------------------------------------------------------------
-- run_fresh — start a new opencode session
-- ---------------------------------------------------------------------------
function M.run_fresh(log_file, prompt, model)
  local title = unique_title()

  local prompt_file = os.tmpname()
  local pf = io.open(prompt_file, "w")
  if pf then pf:write(prompt); pf:close() end

  local cmd = string.format(
    '"%s" run --model "%s" --title "%s" "$(cat %s)"',
    cfg.OPENCODE, model, title, prompt_file)

  stream_cmd(cmd, log_file)
  os.remove(prompt_file)

  local sid = resolve_session_id(title)
  if sid and sid ~= "" then
    logging.log("Session ID: " .. sid)
  else
    logging.warn("Could not resolve session ID")
  end

  return 0, sid
end

-- ---------------------------------------------------------------------------
-- run_continue — nudge an existing session
-- ---------------------------------------------------------------------------
function M.run_continue(log_file, session_id, nudge, model)
  local nudge_file = os.tmpname()
  local nf = io.open(nudge_file, "w")
  if nf then nf:write(nudge); nf:close() end

  local cmd
  if session_id and session_id ~= "" then
    logging.log("Continuing session: " .. session_id)
    cmd = string.format(
      '"%s" run --model "%s" --continue --session "%s" "$(cat %s)"',
      cfg.OPENCODE, model, session_id, nudge_file)
  else
    logging.warn("No session ID — sending nudge as new session (context lost)")
    cmd = string.format(
      '"%s" run --model "%s" "$(cat %s)"',
      cfg.OPENCODE, model, nudge_file)
  end

  stream_cmd(cmd, log_file)
  os.remove(nudge_file)
  return 0
end

return M
