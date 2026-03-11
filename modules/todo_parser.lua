--[[
  modules/todo_parser.lua — parse sections and tasks from todo.md, mark tasks done.
  AI-rewritable.
]]

local M = {}

local cfg     = require("config")
local logging = require("logging")

-- ---------------------------------------------------------------------------
-- Read todo.md lines
-- ---------------------------------------------------------------------------
local function todo_lines()
  local lines = {}
  local f = io.open(cfg.PROJECT_PATH .. "/todo.md", "r")
  if not f then return lines end
  for line in f:lines() do lines[#lines+1] = line end
  f:close()
  return lines
end

-- ---------------------------------------------------------------------------
-- parse_sections — return list of {name, start, end_} (### headings)
-- ---------------------------------------------------------------------------
function M.parse_sections()
  local sections = {}
  local lines    = todo_lines()
  for i, line in ipairs(lines) do
    if line:match("^### ") then
      sections[#sections+1] = { name = line:sub(5), start = i, end_ = 99999 }
    end
  end
  for j = 1, #sections - 1 do
    sections[j].end_ = sections[j+1].start
  end
  return sections
end

-- ---------------------------------------------------------------------------
-- parse_subsections — return {section_index → [subsection_name, ...]}
-- ---------------------------------------------------------------------------
function M.parse_subsections(sections)
  local result = {}
  for i = 1, #sections do result[i] = {} end
  local lines = todo_lines()
  for i, line in ipairs(lines) do
    if line:match("^#### ") then
      for si, sec in ipairs(sections) do
        if sec.start < i and i < sec.end_ then
          result[si][#result[si]+1] = line:sub(6)
          break
        end
      end
    end
  end
  return result
end

-- ---------------------------------------------------------------------------
-- parse_tasks — return all_tasks, unchecked_tasks for a section
-- ---------------------------------------------------------------------------
function M.parse_tasks(section)
  local all_tasks = {}
  local unchecked = {}
  local lines     = todo_lines()
  for i, line in ipairs(lines) do
    if section.start < i and i < section.end_ then
      local num, state, text = line:match("^(%d+)%.%s+%[([%s x])%]%s+(.+)$")
      if num then
        local task = { num = num, state = state, text = text }
        all_tasks[#all_tasks+1] = task
        if state == " " then unchecked[#unchecked+1] = task end
      end
    end
  end
  return all_tasks, unchecked
end

-- ---------------------------------------------------------------------------
-- mark_task_done — flip [ ] → [x] in todo.md
-- ---------------------------------------------------------------------------
function M.mark_task_done(task_num, task_text)
  local path    = cfg.PROJECT_PATH .. "/todo.md"
  local f       = io.open(path, "r")
  if not f then return end
  local content = f:read("*a"); f:close()

  -- Escape magic chars in task_text for pattern
  local escaped = task_text:gsub("([%(%)%.%%%+%-%*%?%[%^%$])", "%%%1")
  local pattern = "(" .. task_num .. "%.%s+%[)%s(%]%s+" .. escaped .. ")"
  local new_content, n = content:gsub(pattern, "%1x%2")
  if n == 0 then
    logging.warn("mark_task_done: pattern not matched for task #" .. task_num)
    return
  end

  local fw = io.open(path, "w")
  if fw then fw:write(new_content); fw:close() end
  logging.log("Marked #" .. task_num .. " as done in todo.md")
end

-- ---------------------------------------------------------------------------
-- build_section_context — render task list as plain text for prompts
-- ---------------------------------------------------------------------------
function M.build_section_context(all_tasks)
  local lines = {}
  for _, t in ipairs(all_tasks) do
    local mark = (t.state == "done" or t.state == "x") and "x" or " "
    lines[#lines+1] = string.format("%s. [%s] %s", t.num, mark, t.text)
  end
  return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Interactive section selection
-- ---------------------------------------------------------------------------
function M.select_section(sections, subsections)
  print("Available sections:\n")
  for i, sec in ipairs(sections) do
    print(string.format("  %d) %s", i, sec.name))
    for _, sub in ipairs(subsections[i] or {}) do
      print("      - " .. sub)
    end
  end
  print()

  io.write("Select section number: ")
  local choice = io.read()
  local idx = tonumber(choice)
  if not idx or idx < 1 or idx > #sections then
    logging.err("Invalid section: '" .. tostring(choice) .. "'"); os.exit(1)
  end
  return idx
end

-- ---------------------------------------------------------------------------
-- Interactive task selection
-- ---------------------------------------------------------------------------
function M.select_tasks(unchecked)
  print(string.format("\nTasks found (%d unchecked):", #unchecked))
  for i, t in ipairs(unchecked) do
    print(string.format("  %d) [#%s] %s", i, t.num, t.text))
  end

  print("\nSelect:")
  print("  1) Run all tasks")
  print("  2) Run specific task (by list position)")
  print("  3) Run range by list position (e.g. 1:5)")
  print("  4) Run by global task number (e.g. 42)")
  print("  q) Quit")
  io.write("Choice: ")
  local choice = io.read()

  if choice == "1" then
    local copy = {}
    for _, t in ipairs(unchecked) do copy[#copy+1] = t end
    return copy

  elseif choice == "2" then
    io.write("Task position: ")
    local pos = tonumber(io.read())
    if not pos or pos < 1 or pos > #unchecked then
      logging.err("Invalid task position"); os.exit(1)
    end
    return { unchecked[pos] }

  elseif choice == "3" then
    io.write("Range (e.g. 1:5): ")
    local rng   = io.read()
    local s, e  = rng:match("^(%d+):(%d+)$")
    if not s then logging.err("Invalid range: " .. tostring(rng)); os.exit(1) end
    local result = {}
    for i = tonumber(s), tonumber(e) do
      if unchecked[i] then result[#result+1] = unchecked[i] end
    end
    if #result == 0 then logging.err("Empty range"); os.exit(1) end
    return result

  elseif choice == "4" then
    io.write("Global task number: ")
    local gnum = io.read()
    for _, t in ipairs(unchecked) do
      if t.num == gnum then return { t } end
    end
    logging.err("Task #" .. gnum .. " not found or already done"); os.exit(1)

  elseif choice:lower() == "q" then
    os.exit(0)

  else
    logging.err("Invalid choice: " .. tostring(choice)); os.exit(1)
  end
end

return M
