--[[
  modules/config.lua — all paths and tuneable constants.
  AI-rewritable. Edit paths for your machine.
]]

local M = {}

-- ---------------------------------------------------------------------------
-- Paths — edit these for your machine
-- ---------------------------------------------------------------------------
M.PROJECT_PATH  = "/home/patryk/Documents/LeviatanHunt"
M.UNITY_EDITOR  = "/home/patryk/Unity/Hub/Editor/6000.3.10f1/Editor/Unity"
M.OPENCODE      = os.getenv("HOME") .. "/.opencode/bin/opencode"
M.SOLUTION_FILE = "/home/patryk/Documents/LeviatanHunt/LeviatanHunt.sln"

-- ---------------------------------------------------------------------------
-- Iteration limits
-- ---------------------------------------------------------------------------
M.MAX_ITERATIONS = 5   -- max fresh Ralph restarts per task
M.MAX_CONTINUES  = 8   -- max --continue nudges within one Ralph iteration
M.MAX_FIX_ROUNDS = 5   -- max compile-fix iterations per task

-- ---------------------------------------------------------------------------
-- Session name (override via first CLI arg)
-- ---------------------------------------------------------------------------
M.SESSION_NAME = arg and arg[1] or "automation"

-- ---------------------------------------------------------------------------
-- Ralph state files (relative to PROJECT_PATH)
-- ---------------------------------------------------------------------------
M.PROGRESS_FILE       = "progress.txt"
M.AGENTS_FILE         = "AGENTS.md"
M.ARCHIVE_DIR         = ".ralph-archive"
M.LAST_SESSION_FILE   = ".ralph-last-session"
M.KERNEL_SUGGESTIONS  = "KERNEL_SUGGESTIONS.md"
M.TOOL_REGISTRY_FILE  = ".ralph-tools.json"   -- persisted tool metadata

-- ---------------------------------------------------------------------------
-- File extensions tracked by the snapshot system
-- ---------------------------------------------------------------------------
M.SNAPSHOT_EXTENSIONS = {
  [".cs"]      = true,
  [".shader"]  = true,
  [".hlsl"]    = true,
  [".compute"] = true,
  [".asmdef"]  = true,
  [".asmref"]  = true,
  [".json"]    = true,
  [".asset"]   = true,
}

M.SNAPSHOT_SKIP_DIRS = {
  [".git"]     = true,
  ["Library"]  = true,
  ["Temp"]     = true,
  ["obj"]      = true,
  ["Packages"] = true,
}

return M
