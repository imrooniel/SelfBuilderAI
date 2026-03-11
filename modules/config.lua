--[[
  modules/config.lua — all paths and tuneable constants.
  AI-rewritable. Edit paths for your machine and project type.

  PROJECT_TYPE controls which workflow plugins are active:
    "generic"  — any codebase, no compile check
    "unity"    — Unity C# project (batch compile + inspectcode)
    "rust"     — cargo build / cargo clippy
    "node"     — npm run build / tsc
    "python"   — pyflakes / mypy
    "go"       — go build / go vet
    "custom"   — supply your own compile_cmd / check_cmd below
]]

local M = {}

-- ---------------------------------------------------------------------------
-- Core paths
-- ---------------------------------------------------------------------------
M.PROJECT_PATH  = os.getenv("HOME") .. "/Documents/SelfBuilderAI"
M.OPENCODE      = os.getenv("HOME") .. "/.opencode/bin/opencode"

-- ---------------------------------------------------------------------------
-- Project type — determines compile/check workflow
-- ---------------------------------------------------------------------------
M.PROJECT_TYPE  = "generic"   -- "unity"|"rust"|"node"|"python"|"go"|"generic"|"custom"

-- ---------------------------------------------------------------------------
-- Unity-specific (only used when PROJECT_TYPE == "unity")
-- ---------------------------------------------------------------------------
M.UNITY_EDITOR  = "/path/to/Unity/Hub/Editor/6000.x/Editor/Unity"
M.SOLUTION_FILE = nil   -- nil = auto-discover *.sln in PROJECT_PATH

-- ---------------------------------------------------------------------------
-- Custom compile/check commands (only used when PROJECT_TYPE == "custom")
-- %s is substituted with PROJECT_PATH
-- ---------------------------------------------------------------------------
M.CUSTOM_COMPILE_CMD = 'make -C "%s" 2>&1'
M.CUSTOM_CHECK_CMD   = nil    -- optional secondary static-analysis command

-- ---------------------------------------------------------------------------
-- Language/tech description injected into every prompt
-- (auto-populated from PROJECT_TYPE if left nil)
-- ---------------------------------------------------------------------------
M.TECH_DESCRIPTION = nil   -- e.g. "Rust 2021 with Tokio async runtime"

-- ---------------------------------------------------------------------------
-- Source file extensions tracked by the snapshot system
-- (auto-populated from PROJECT_TYPE if left nil, override here if needed)
-- ---------------------------------------------------------------------------
M.SNAPSHOT_EXTENSIONS = nil   -- nil = auto from PROJECT_TYPE

-- ---------------------------------------------------------------------------
-- Directories to skip during snapshot
-- ---------------------------------------------------------------------------
M.SNAPSHOT_SKIP_DIRS = {
  [".git"]       = true,
  ["node_modules"] = true,
  ["target"]     = true,   -- Rust
  ["dist"]       = true,
  ["build"]      = true,
  ["__pycache__"] = true,
  [".venv"]      = true,
  ["Library"]    = true,   -- Unity
  ["Temp"]       = true,   -- Unity
  ["obj"]        = true,
  ["Packages"]   = true,   -- Unity
}

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
-- State files (relative to PROJECT_PATH)
-- ---------------------------------------------------------------------------
M.PROGRESS_FILE       = "progress.txt"
M.AGENTS_FILE         = "AGENTS.md"
M.ARCHIVE_DIR         = ".ralph-archive"
M.LAST_SESSION_FILE   = ".ralph-last-session"
M.KERNEL_SUGGESTIONS  = "KERNEL_SUGGESTIONS.md"
M.TOOL_REGISTRY_FILE  = ".ralph-tools.json"

-- ---------------------------------------------------------------------------
-- Self-improvement settings
-- ---------------------------------------------------------------------------
M.SELF_IMPROVE_ENABLED   = true   -- set false to disable all AI self-improvement passes
M.SELF_IMPROVE_TARGETED  = true   -- targeted pass on task failure / compile error
M.SELF_IMPROVE_PROACTIVE = true   -- proactive pass at end of each session
M.SELF_IMPROVE_MIN_TASKS = 3      -- minimum tasks in a session before proactive pass runs

-- ---------------------------------------------------------------------------
-- Context budget — tune for your model's context window.
-- These control how much supplementary data is injected into every prompt.
-- At 512k context a local model uses roughly 3–4 chars per token, so
-- 512k tokens ≈ 1.5–2 MB of text. The defaults below leave ~80% of the
-- window for the model's own output and tool call round-trips.
-- ---------------------------------------------------------------------------
M.CTX_PROGRESS_CHARS   = 2000   -- max chars of progress.txt tail injected per prompt
M.CTX_AGENTS_CHARS     = 3000   -- max chars of AGENTS.md injected per prompt
M.CTX_FILE_LIST_MAX    = 20     -- max source file paths listed in prompt
M.CTX_SECTION_TASKS    = 10     -- max sibling tasks shown in section_context
M.CTX_JOURNAL_ENTRIES  = 10     -- max recent journal entries passed as session context
M.CTX_PROMPT_HARD_CAP  = 12000  -- max chars of supplementary context per task prompt
                                 -- (agents + progress + journal + files + tools combined)
                                 -- 12k chars ≈ 3k–4k tokens; leaves plenty of room for output

-- ---------------------------------------------------------------------------
-- Model selection
-- ---------------------------------------------------------------------------
M.DEFAULT_MODEL = nil   -- e.g. "ollama/qwen3.5:35b-256k"; nil = interactive prompt at startup

-- ---------------------------------------------------------------------------
-- Log retention
-- ---------------------------------------------------------------------------
M.LOG_RETENTION_DAYS = 7   -- delete logs older than N days at session start; nil = keep forever

-- ---------------------------------------------------------------------------
-- Kernel path (set by run_automation.lua at boot; modules read cfg.KERNEL_SOURCE_PATH)
-- ---------------------------------------------------------------------------
M.KERNEL_SOURCE_PATH = nil

return M
