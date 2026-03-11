--[[
  modules/git_utils.lua — git wrappers and file-snapshot helpers.
  AI-rewritable.
]]

local M = {}

local cfg     = require("config")
local logging = require("logging")

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
-- ensure_branch
-- ---------------------------------------------------------------------------
function M.ensure_branch(branch_name)
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
  git("add -A")
  local diff, _ = git("diff --cached --quiet", false)
  -- if diff is empty string and exit 0, nothing to commit
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
  -- Use find to enumerate files with their mtimes
  local exts = {}
  for ext in pairs(cfg.SNAPSHOT_EXTENSIONS) do
    exts[#exts+1] = '-name "*' .. ext .. '"'
  end
  local ext_filter = table.concat(exts, " -o ")

  -- Build skip-dir prune expression
  local skip_parts = {}
  for dir in pairs(cfg.SNAPSHOT_SKIP_DIRS) do
    skip_parts[#skip_parts+1] = string.format('-name "%s" -prune', dir)
  end
  local skip_expr = #skip_parts > 0
    and "\\( " .. table.concat(skip_parts, " -o ") .. " \\) -o"
    or ""

  local cmd = string.format(
    'find "%s" %s \\( %s \\) -print0 2>/dev/null | xargs -0 stat -c "%%Y %%n" 2>/dev/null',
    cfg.PROJECT_PATH, skip_expr, ext_filter)

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
