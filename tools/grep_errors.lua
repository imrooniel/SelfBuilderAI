--[[
  tools/grep_errors.lua — grep for patterns in project source files.

  Example tool demonstrating the tool contract.
  The AI may write new tools following this same pattern.
]]

return {
  name        = "grep_errors",
  description = "Grep for a pattern across all source files in the project",
  params      = "pattern string to search for (plain text or basic regex)",

  run = function(params_str)
    local cfg = require("config")
    local pattern = params_str:match("^%s*(.-)%s*$")
    if not pattern or pattern == "" then
      return nil, "grep_errors: empty pattern"
    end

    pattern = pattern:gsub('"', '\\"')

    local cmd = string.format(
      'grep -rn "%s" "%s" '
      .. '--include="*.lua" --include="*.py" --include="*.ts" --include="*.js" '
      .. '--include="*.rs" --include="*.go" --include="*.cs" --include="*.cpp" '
      .. '--include="*.c" --include="*.h" --include="*.java" --include="*.rb" '
      .. '2>/dev/null | grep -v node_modules | grep -v ".git" | grep -v "__pycache__" | head -50',
      pattern, cfg.PROJECT_PATH)

    local handle = io.popen(cmd)
    if not handle then return nil, "grep_errors: popen failed" end
    local result = handle:read("*a")
    handle:close()

    if result == "" then
      return "No matches found for: " .. pattern, nil
    end
    return result, nil
  end,
}
