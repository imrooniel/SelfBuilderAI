--[[
  modules/git_utils.lua — git wrappers and file-snapshot helpers.
  AI-rewritable.
]]

local M = {}

local cfg          = require("config")
local logging      = require("logging")
local project_type = require("project_type")

-- ---------------------------------------------------------------------------
-- git() — run a git command in the project directory
-- ---------------------------------------------------------------------------
local function git(args, check)
  local cmd = string.format('git -C "%s" %s 2>&1', cfg.PROJECT_PATH, args)
  local handle = io.popen(cmd)
  local output = handle and handle:read("*a") or ""
  local ok = handle and handle:close()
  if check ~= false and not ok then
    logging.warn("git command failed: " .. cmd)
  end
  return output, ok
end

function M.git(args, check)
  return git(args, check)
end

-- ---------------------------------------------------------------------------
-- is_git_repo — check whether the project is a git repo (or can become one)
-- ---------------------------------------------------------------------------
function M.is_git_repo()
  local _, ok = git("rev-parse --git-dir", false)
  -- io.popen handle:close() returns true on success (exit 0), not the integer 0
  return ok == true
end

-- ---------------------------------------------------------------------------
-- ensure_git_repo — initialise git if not already present
-- ---------------------------------------------------------------------------
function M.ensure_git_repo()
  if not M.is_git_repo() then
    logging.log("Initialising git repository in " .. cfg.PROJECT_PATH)
    git("init")
    git('config user.email "ralph-automation@localhost"', false)
    git('config user.name "Ralph Automation"', false)
    -- Create an initial commit so branches can be made
    local readme = cfg.PROJECT_PATH .. "/README.md"
    local f = io.open(readme, "w")
    if f then f:write("# " .. cfg.SESSION_NAME .. "\n"); f:close() end
    git("add -A")
    git('commit -m "chore: init repo"')
    logging.ok("Git repository initialised.")
  end
end

-- ---------------------------------------------------------------------------
-- ensure_branch
-- ---------------------------------------------------------------------------
function M.ensure_branch(branch_name)
  if not M.is_git_repo() then
    logging.warn("Not a git repo — skipping branch management.")
    return
  end
  local _, exists = git('rev-parse --verify "' .. branch_name .. '"', false)
  if exists then
    logging.log("Using existing branch: " .. branch_name)
    git('checkout "' .. branch_name .. '"')
  else
    logging.log("Creating new branch: " .. branch_name)
    git('checkout -b "' .. branch_name .. '"')
  end
end

-- ---------------------------------------------------------------------------
-- git_commit
-- ---------------------------------------------------------------------------
function M.git_commit(task_num, slug, task_text, compile_clean)
  if not M.is_git_repo() then
    logging.warn("Not a git repo — skipping commit.")
    return
  end
  git("add -A")
  local handle = io.popen(string.format(
    'git -C "%s" diff --cached --quiet 2>/dev/null; echo $?', cfg.PROJECT_PATH))
  local code = handle and handle:read("*a") or "1"
  if handle then handle:close() end
  code = code:gsub("%s+", "")
  if code == "0" then
    logging.log("No staged changes to commit")
    return
  end
  local suffix = compile_clean and "" or " [compile-errors]"
  git(string.format('commit -m "task-%s-%s: %s%s"', task_num, slug, task_text, suffix))
  logging.log("Committed to branch")
end

-- ---------------------------------------------------------------------------
-- snapshot_files — return {path → mtime} for all tracked source files
-- ---------------------------------------------------------------------------
function M.snapshot_files()
  local result = {}
  local extensions = project_type.get_extensions(cfg)

  local exts = {}
  for ext in pairs(extensions) do
    exts[#exts+1] = '-name "*' .. ext .. '"'
  end
  if #exts == 0 then return result end
  local ext_filter = table.concat(exts, " -o ")

  -- Build skip-dir prune expression
  local skip_parts = {}
  for dir in pairs(cfg.SNAPSHOT_SKIP_DIRS) do
    skip_parts[#skip_parts+1] = string.format('-name "%s" -prune', dir)
  end
  local skip_expr = #skip_parts > 0
    and "\\( " .. table.concat(skip_parts, " -o ") .. " \\) -o"
    or ""

  -- Portable mtime: try GNU stat first, fall back to BSD stat (macOS)
  -- GNU: stat -c "%Y %n"   BSD: stat -f "%m %N"
  local stat_cmd
  local test_handle = io.popen("stat --version 2>/dev/null")
  local stat_out = test_handle and test_handle:read("*l") or ""
  if test_handle then test_handle:close() end
  if stat_out:find("GNU") then
    stat_cmd = 'xargs -0 stat -c "%Y %n" 2>/dev/null'
  else
    stat_cmd = 'xargs -0 stat -f "%m %N" 2>/dev/null'
  end

  local cmd = string.format(
    'find "%s" %s \\( %s \\) -print0 2>/dev/null | %s',
    cfg.PROJECT_PATH, skip_expr, ext_filter, stat_cmd)

  local handle = io.popen(cmd)
  if handle then
    for line in handle:lines() do
      local mtime, path = line:match("^(%d+)%s+(.+)$")
      if mtime and path then
        result[path] = tonumber(mtime)
      end
    end
    handle:close()
  end
  return result
end

-- ---------------------------------------------------------------------------
-- files_changed_since — return list of paths new/modified vs before snapshot
-- ---------------------------------------------------------------------------
function M.files_changed_since(before)
  local after   = M.snapshot_files()
  local changed = {}
  for path, mtime in pairs(after) do
    if before[path] ~= mtime then
      changed[#changed+1] = path
    end
  end
  return changed
end

return M
