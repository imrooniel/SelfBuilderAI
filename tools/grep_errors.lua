--[[
  tools/grep_errors.lua — example tool: grep for patterns in project files.

  This is an example tool shipped with the suite. It demonstrates the tool
  contract that the AI must follow when writing new tools.

  Tool contract:
    Return a table with: name, description, params, run(params_str) → result, err
]]

return {
  name        = "grep_errors",
  description = "Grep for a pattern across all C# files in the project",
  params      = "pattern string to search for (plain text)",

  run = function(params_str)
    local cfg = require("config")
    local pattern = params_str:match("^%s*(.-)%s*$")
    if not pattern or pattern == "" then
      return nil, "grep_errors: empty pattern"
    end

    -- Sanitize: disallow shell injection via pattern
    pattern = pattern:gsub('"', '\\"')

    local cmd = string.format(
      'grep -rn "%s" "%s/Assets/Scripts" --include="*.cs" 2>/dev/null | head -50',
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
