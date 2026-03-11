--[[
  modules/logging.lua — coloured log helpers.
  AI-rewritable.
]]

local M = {}

-- Detect whether stdout is a TTY
local function is_tty()
  local term = os.getenv("TERM")
  return term and term ~= "dumb"
end

local TTY = is_tty()

local function c(code, text)
  if TTY then
    return string.format("\027[%sm%s\027[0m", code, text)
  end
  return text
end

-- Colour palette
M.dim         = function(t) return c("2",    t) end
M.cyan        = function(t) return c("36",   t) end
M.green       = function(t) return c("32",   t) end
M.bold_green  = function(t) return c("1;32", t) end
M.yellow      = function(t) return c("33",   t) end
M.bold_yellow = function(t) return c("1;33", t) end
M.red         = function(t) return c("31",   t) end
M.bold_red    = function(t) return c("1;31", t) end
M.bold_white  = function(t) return c("1",    t) end
M.magenta     = function(t) return c("35",   t) end
M.bold_cyan   = function(t) return c("1;36", t) end
M.blue        = function(t) return c("34",   t) end
M.bold_blue   = function(t) return c("1;34", t) end

-- Log-level functions
function M.log(msg)
  print(M.dim("[INFO]   ") .. " " .. msg)
end

function M.ok(msg)
  print(M.bold_green("[SUCCESS]") .. " " .. M.green(msg))
end

function M.warn(msg)
  print(M.bold_yellow("[WARN]   ") .. " " .. M.yellow(msg))
end

function M.err(msg)
  io.stderr:write(M.bold_red("[ERROR]  ") .. " " .. M.red(msg) .. "\n")
end

function M.header(msg)
  print(M.bold_white(msg))
end

function M.thinking(msg)
  print(c("2;35", msg))
end

function M.step(label, msg)
  print(M.bold_blue(string.format("[%-8s]", label)) .. " " .. msg)
end

return M
