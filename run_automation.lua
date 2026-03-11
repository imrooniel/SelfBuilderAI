#!/usr/bin/env lua
--[[
  run_automation.lua — KERNEL (read-only to the AI agent)
  v2.0.0

  A general-purpose AI agent orchestrator implementing the Ralph pattern
  (fresh-context outer loop + continue-nudge inner loop) with self-improvement.

  Supported project types (configured in modules/config.lua):
    "generic"  — any codebase, no compile check
    "unity"    — Unity C# (batch compile + inspectcode)
    "rust"     — cargo build / cargo clippy
    "node"     — tsc / npm run build / eslint
    "python"   — pyflakes / mypy
    "go"       — go build / go vet
    "custom"   — user-supplied compile/check commands

  Module layout (all AI-rewritable except this file):
    modules/config.lua          — paths, constants, project type
    modules/project_type.lua    — per-language compile/check profiles
    modules/logging.lua         — coloured log helpers
    modules/session.lua         — archive, state-file bootstrap, model selection
    modules/todo_parser.lua     — parse/select/mark tasks in todo.md
    modules/git_utils.lua       — git wrappers, file snapshot
    modules/compile.lua         — two-layer compile/check driver
    modules/prompts.lua         — build_task_prompt(), build_fix_prompt(), nudges
    modules/opencode.lua        — run_fresh(), run_continue()
    modules/hot_reload.lua      — safe module hot-swap with rollback
    modules/tool_registry.lua   — dynamic tool loading/calling
    modules/self_improve.lua    — AI self-improvement orchestration

  tools/                        — AI-written tools (empty at start)

  The AI may NOT rewrite this kernel. It may read it and append suggestions to
  KERNEL_SUGGESTIONS.md for the human developer to review and apply manually.
]]

-- ---------------------------------------------------------------------------
-- Kernel version — bump manually when you apply AI suggestions
-- ---------------------------------------------------------------------------
KERNEL_VERSION = "2.0.0"

-- ---------------------------------------------------------------------------
-- Resolve script directory so require() works from any cwd
-- ---------------------------------------------------------------------------
local function script_dir()
  local info = debug.getinfo(1, "S").source
  if info:sub(1,1) == "@" then
    return info:sub(2):match("(.*/)") or "./"
  end
  return "./"
end

local BASE_DIR = script_dir()
package.path = BASE_DIR .. "modules/?.lua;" ..
               BASE_DIR .. "tools/?.lua;" ..
               BASE_DIR .. "?.lua;" ..
               package.path

-- ---------------------------------------------------------------------------
-- Bootstrap: load hot_reload first
-- ---------------------------------------------------------------------------
local ok_hr, hot_reload = pcall(require, "hot_reload")
if not ok_hr then
  io.stderr:write("[KERNEL] FATAL: cannot load modules/hot_reload.lua\n")
  io.stderr:write(tostring(hot_reload) .. "\n")
  os.exit(1)
end

local function load_module(name)
  local mod, err = hot_reload.load(name)
  if not mod then
    io.stderr:write("[KERNEL] FATAL: cannot load modules/" .. name .. ".lua\n")
    io.stderr:write(tostring(err) .. "\n")
    os.exit(1)
  end
  return mod
end

local cfg          = load_module("config")
local logging      = load_module("logging")
local project_type = load_module("project_type")
local session      = load_module("session")
local todo_parser  = load_module("todo_parser")
local git_utils    = load_module("git_utils")
local compile      = load_module("compile")
local prompts      = load_module("prompts")
local opencode     = load_module("opencode")
local tool_reg     = load_module("tool_registry")
local self_improve = load_module("self_improve")

-- Expose module reloader so self_improve can hot-swap modules
_G.__reload_module = function(name)
  local new_mod, err = hot_reload.reload(name)
  if not new_mod then
    logging.warn("Hot-reload FAILED for " .. name .. ": " .. tostring(err))
    return false, err
  end
  logging.log("Hot-reloaded module: " .. name)
  return true
end

-- Re-fetch all module refs after any hot-reload.
-- IMPORTANT: This only updates the kernel-level locals listed below. Any
-- function that has already closed over one of these variables in a nested
-- closure will still hold a reference to the pre-reload module table. Avoid
-- capturing module references in long-lived closures; always read through
-- the kernel locals (cfg, logging, etc.) at call time.
function _G.__refresh_modules()
  cfg          = hot_reload.get("config")        or cfg
  logging      = hot_reload.get("logging")       or logging
  project_type = hot_reload.get("project_type")  or project_type
  session      = hot_reload.get("session")       or session
  todo_parser  = hot_reload.get("todo_parser")   or todo_parser
  git_utils    = hot_reload.get("git_utils")     or git_utils
  compile      = hot_reload.get("compile")       or compile
  prompts      = hot_reload.get("prompts")       or prompts
  opencode     = hot_reload.get("opencode")      or opencode
  tool_reg     = hot_reload.get("tool_registry") or tool_reg
  self_improve = hot_reload.get("self_improve")  or self_improve
end

-- Kernel source path exposed to self_improve (read-only use)
KERNEL_SOURCE_PATH = BASE_DIR .. "run_automation.lua"

-- Orchestrator directory paths exposed to self_improve so it can tell the
-- AI exactly where to find and write module files.
KERNEL_BASE_DIR    = BASE_DIR
KERNEL_MODULES_DIR = BASE_DIR .. "modules"
KERNEL_TOOLS_DIR   = BASE_DIR .. "tools"

-- ---------------------------------------------------------------------------
-- Sanity checks
-- ---------------------------------------------------------------------------
local function sanity_check()
  if not cfg.PROJECT_PATH or cfg.PROJECT_PATH == "" then
    logging.err("PROJECT_PATH not set in config.lua"); os.exit(1)
  end
  if not cfg.OPENCODE or cfg.OPENCODE == "" then
    logging.err("OPENCODE path not set in config.lua"); os.exit(1)
  end
  -- Verify opencode binary exists
  local f_oc = io.open(cfg.OPENCODE, "r")
  if not f_oc then
    logging.err("opencode binary not found: " .. cfg.OPENCODE)
    logging.err("Install from: https://opencode.ai  or set OPENCODE in config.lua")
    os.exit(1)
  end
  f_oc:close()

  local function is_dir(p)
    local f = io.open(p .. "/.test_kernel_probe", "w")
    if f then f:close(); os.remove(p .. "/.test_kernel_probe"); return true end
    return os.execute('test -d "' .. p .. '"') == 0
  end

  -- Create PROJECT_PATH if it doesn't exist
  if not is_dir(cfg.PROJECT_PATH) then
    local ok = os.execute('mkdir -p "' .. cfg.PROJECT_PATH .. '"')
    if not ok or not is_dir(cfg.PROJECT_PATH) then
      logging.err("Cannot create project path: " .. cfg.PROJECT_PATH); os.exit(1)
    end
    logging.log("Created project directory: " .. cfg.PROJECT_PATH)
  end

  local has_todo = io.open(cfg.PROJECT_PATH .. "/todo.md", "r")
  if has_todo then has_todo:close(); has_todo = true else has_todo = false end

  -- Detect if the project already has source structure
  local has_sources = false
  local profile = project_type.resolve(cfg)
  for _, d in ipairs(profile.src_dirs or {}) do
    if is_dir(cfg.PROJECT_PATH .. "/" .. d) then
      has_sources = true; break
    end
  end

  return has_todo, has_sources
end

-- ---------------------------------------------------------------------------
-- Slug helper
-- ---------------------------------------------------------------------------
local function task_slug(text)
  local s = text:lower():gsub("[^a-z0-9 ]", ""):gsub("%s+", "-")
  return s:sub(1, 40)
end

-- ---------------------------------------------------------------------------
-- Single-task runner
-- ---------------------------------------------------------------------------
local function run_task(task_num, task_text, all_tasks, model, version, has_sources, run_ts, session_context)
  __refresh_modules()

  session_context = session_context or ""

  local slug       = task_slug(task_text)
  local task_start = os.time()

  print()
  logging.header("============================================")
  logging.header(string.format("[TASK #%s] %s", task_num, task_text))
  logging.header(string.format("  Type: %s | Version: %s", cfg.PROJECT_TYPE, version))
  logging.header("============================================")

  os.execute('mkdir -p "' .. cfg.PROJECT_PATH .. '/logs"')

  local before_snapshot = git_utils.snapshot_files()
  local section_context = all_tasks and todo_parser.build_section_context(all_tasks) or ""

  local iteration   = 0
  local said_done   = false
  local changed     = {}
  local prior_note  = "No details recorded."
  local nudge_count = 0

  -- ----------------------------------------------------------------
  -- OUTER loop — Ralph pattern, fresh context each iteration
  -- ----------------------------------------------------------------
  while iteration < cfg.MAX_ITERATIONS and not said_done do
    iteration = iteration + 1
    local log_file = string.format("%s/logs/%s-%s-iter%d-%s.log",
      cfg.PROJECT_PATH, task_num, slug, iteration, run_ts)

    local f = io.open(log_file, "w"); if f then f:close() end

    logging.log(string.format(
      "Ralph iteration %d/%d — fresh context | log: %s",
      iteration, cfg.MAX_ITERATIONS,
      log_file:gsub(cfg.PROJECT_PATH .. "/", "")))
    print()

    local tool_context = tool_reg.describe_tools()

    local prompt = prompts.build_task_prompt({
      task_num        = task_num,
      task_text       = task_text,
      section_context = section_context,
      iteration       = iteration,
      prior_note      = prior_note,
      version         = version,
      tool_context    = tool_context,
      session_context = session_context,
    })

    local _, current_session = opencode.run_fresh(log_file, prompt, model)
    changed   = git_utils.files_changed_since(before_snapshot)
    said_done = opencode.log_says_done(log_file)

    tool_reg.process_tool_calls(log_file, task_num, run_ts)

    if said_done then break end

    -- ----------------------------------------------------------------
    -- INNER loop — continue nudges within the same session
    -- ----------------------------------------------------------------
    nudge_count = 0
    while not said_done and nudge_count < cfg.MAX_CONTINUES do
      nudge_count = nudge_count + 1
      logging.log(string.format("Continue nudge %d/%d ...", nudge_count, cfg.MAX_CONTINUES))
      print()

      opencode.run_continue(log_file, current_session, prompts.get_nudge(nudge_count), model)
      changed   = git_utils.files_changed_since(before_snapshot)
      said_done = opencode.log_says_done(log_file)

      tool_reg.process_tool_calls(log_file, task_num, run_ts)

      if said_done then break end

      if #changed == 0 and nudge_count >= 2 then
        logging.log(string.format(
          "No progress after %d nudges — escalating to fresh Ralph iteration.", nudge_count))
        break
      end
    end

    if said_done then break end

    -- Build note for next Ralph iteration
    if #changed > 0 then
      local names = {}
      for i = 1, math.min(5, #changed) do
        names[#names+1] = changed[i]:gsub(cfg.PROJECT_PATH .. "/", "")
      end
      prior_note = string.format(
        "Files were modified but DONE was not output after %d nudge(s). Changed: %s. Complete remaining work.",
        nudge_count, table.concat(names, ", "))
      logging.log("Files changed but DONE not detected — Ralph fresh restart...")
    else
      prior_note = string.format(
        "No files were created or modified after %d nudge(s). Try a completely different approach.",
        nudge_count)
      logging.log("No progress after inner loop — Ralph fresh restart...")
    end

    session.append_progress(task_num, task_text,
      string.format("Ralph iteration %d incomplete (%d nudges). %s", iteration, nudge_count, prior_note))
  end

  local elapsed = os.time() - task_start

  -- ----------------------------------------------------------------
  -- Success path
  -- ----------------------------------------------------------------
  if said_done or #changed > 0 then
    if said_done and #changed > 0 then
      logging.ok(string.format("Task #%s complete! (DONE + files changed) [iter=%d, nudges=%d, %ds]",
        task_num, iteration, nudge_count, elapsed))
    elseif said_done then
      logging.ok(string.format("Task #%s complete! (DONE) [iter=%d, nudges=%d, %ds]",
        task_num, iteration, nudge_count, elapsed))
    else
      logging.ok(string.format("Task #%s complete! (files changed) [iter=%d, nudges=%d, %ds]",
        task_num, iteration, nudge_count, elapsed))
    end

    -- ---- Compile / check pass ----
    local fix_round     = 0
    local compile_clean = true

    local profile = project_type.resolve(cfg)
    if not profile.compile then
      logging.log(string.format(
        "No compile check defined for project type '%s' — skipping.", cfg.PROJECT_TYPE))
    else
      local compile_error_file = string.format("%s/logs/%s-compile-errors-%s.txt",
        cfg.PROJECT_PATH, task_num, run_ts)

      logging.log(string.format(
        "Running compile/check pass [%s]...", cfg.PROJECT_TYPE))

      if not compile.run_compile_check(compile_error_file) then
        compile_clean = false
        local errors = compile.read_errors(compile_error_file)
        logging.warn(string.format("Compile/check errors detected (%d):", #errors))
        for _, e in ipairs(errors) do print("          " .. e) end
      else
        logging.ok("Compile/check passed.")
      end

      while not compile_clean and fix_round < cfg.MAX_FIX_ROUNDS do
        fix_round = fix_round + 1
        logging.log(string.format("Fix round %d/%d — fresh context...", fix_round, cfg.MAX_FIX_ROUNDS))
        print()

        local fix_log = string.format("%s/logs/%s-fix%d-%s.log",
          cfg.PROJECT_PATH, task_num, fix_round, run_ts)
        local f2 = io.open(fix_log, "w"); if f2 then f2:close() end

        local errors_text = compile.read_errors_raw(compile_error_file)
        local fix_prompt  = prompts.build_fix_prompt({
          task_num        = task_num,
          task_text       = task_text,
          compile_errors  = errors_text,
          version         = version,
          session_context = session_context,
        })

        local _, fix_session = opencode.run_fresh(fix_log, fix_prompt, model)

        local fix_nudge = 0
        while not opencode.log_says_done(fix_log) and fix_nudge < 4 do
          fix_nudge = fix_nudge + 1
          logging.log(string.format("Fix continue nudge %d/4...", fix_nudge))
          opencode.run_continue(fix_log, fix_session, prompts.FIX_NUDGE_PROMPT, model)
        end

        logging.log(string.format("Re-running compile check after fix round %d...", fix_round))
        if compile.run_compile_check(compile_error_file) then
          compile_clean = true
          logging.ok(string.format("Errors resolved after fix round %d.", fix_round))
          break
        else
          local errs = compile.read_errors(compile_error_file)
          logging.warn(string.format("Still has errors after fix round %d (%d errors):", fix_round, #errs))
          for _, e in ipairs(errs) do print("          " .. e) end
        end
      end

      if not compile_clean then
        logging.warn(string.format(
          "Errors remain after %d fix round(s) — committing for manual review.", cfg.MAX_FIX_ROUNDS))
      end

      -- Targeted self-improvement on persistent compile failure
      if not compile_clean then
        local compile_error_file2 = string.format("%s/logs/%s-compile-errors-%s.txt",
          cfg.PROJECT_PATH, task_num, run_ts)
        logging.log("[SELF-IMPROVE] Compile errors persisted — running targeted improvement pass...")
        self_improve.run_targeted(model, "compile_failure", {
          task_num  = task_num,
          task_text = task_text,
          errors    = compile.read_errors_raw(compile_error_file2),
        })
        __refresh_modules()
      end
    end

    git_utils.git_commit(task_num, slug, task_text, compile_clean)

    -- Mark done in todo.md only when called from todo-driven mode
    if all_tasks then
      todo_parser.mark_task_done(task_num, task_text)
      for _, t in ipairs(all_tasks) do
        if t.num == task_num then t.state = "done"; break end
      end
    end

    session.append_progress(task_num, task_text,
      string.format("Completed in %d iteration(s) [%ds]. Compile clean: %s.",
        iteration, elapsed, tostring(compile_clean)))

    return true
  end

  -- ----------------------------------------------------------------
  -- Failure path
  -- ----------------------------------------------------------------
  logging.err(string.format(
    "Task #%s failed after %d Ralph iteration(s) / %d nudge(s) [%ds]",
    task_num, iteration, nudge_count, elapsed))

  session.append_progress(task_num, task_text,
    string.format("FAILED after %d iteration(s). Manual intervention required.", iteration))

  -- Targeted self-improvement + kernel suggestion on failure
  logging.log("[SELF-IMPROVE] Task failed — running targeted improvement pass...")
  self_improve.run_targeted(model, "task_failure", {
    task_num   = task_num,
    task_text  = task_text,
    prior_note = prior_note,
    iterations = iteration,
    nudges     = nudge_count,
  })
  __refresh_modules()

  logging.log("[KERNEL] Task failed — running kernel suggestion pass...")
  self_improve.suggest_kernel_improvements(model, {
    task_num   = task_num,
    task_text  = task_text,
    prior_note = prior_note,
  })

  return false
end

-- ---------------------------------------------------------------------------
-- readline_input — rich prompt using Python's readline
-- ---------------------------------------------------------------------------
local _readline_helper_path = nil

local function ensure_readline_helper()
  if _readline_helper_path then return _readline_helper_path end

  local path = cfg.PROJECT_PATH .. "/.ralph-readline-helper.py"
  local f = io.open(path, "w")
  if not f then
    path = BASE_DIR .. ".ralph-readline-helper.py"
    f = io.open(path, "w")
  end
  if not f then return nil end

  f:write([[
import sys, os
try:
    import readline
except ImportError:
    try:
        line = input("")
        print(line)
    except EOFError:
        sys.exit(1)
    sys.exit(0)

history_file = sys.argv[1] if len(sys.argv) > 1 else None
prompt       = sys.argv[2] if len(sys.argv) > 2 else "> "

if history_file:
    try:
        readline.read_history_file(history_file)
    except FileNotFoundError:
        pass
    readline.set_history_length(500)

try:
    lines = []
    current_prompt = prompt
    while True:
        part = input(current_prompt)
        if part.endswith("\\"):
            lines.append(part[:-1])
            current_prompt = "... "
        else:
            lines.append(part)
            break
    result = "\n".join(lines)
    print(result)
except EOFError:
    if history_file:
        readline.write_history_file(history_file)
    sys.exit(1)

if history_file:
    readline.write_history_file(history_file)
]])
  f:close()
  _readline_helper_path = path
  return path
end

local function readline_input(prompt)
  local helper       = ensure_readline_helper()
  local history_file = cfg.PROJECT_PATH .. "/.ralph-repl-history"

  if helper then
    local safe_prompt  = prompt:gsub("'", "'\\''")
    local safe_history = history_file:gsub("'", "'\\''")
    local cmd = string.format("python3 '%s' '%s' '%s'", helper, safe_history, safe_prompt)
    local handle = io.popen(cmd)
    if handle then
      local output = handle:read("*a")
      local ok = handle:close()
      if not ok then return nil end
      output = output:gsub("%s+$", "")
      if output == "" then return nil end
      return output
    end
  end

  io.write(prompt)
  local line = io.read()
  if not line then return nil end
  return line:match("^%s*(.-)%s*$")
end

-- ---------------------------------------------------------------------------
-- classify_input — AI-powered intent classifier.
--
-- Returns: intent ("task" | "self_improve" | "query"), module_target (or nil)
--
-- Fast-path: a small set of unambiguous regex patterns are checked first so
-- trivially obvious inputs (bare "?" prefix, trailing "?") don't pay the cost
-- of an LLM call. Everything else goes to the model.
-- ---------------------------------------------------------------------------

-- Unambiguous fast-path patterns — only used for cases where no reasonable
-- human would mean anything other than what the pattern says.
local function fast_classify(s)
  -- Explicit query override prefix
  if s:sub(1, 1) == "?" then return "query", nil end
  -- Bare question mark ending with no task verb
  if s:match("%?%s*$") and not s:match("^%a+%s") then return "query", nil end
  return nil, nil  -- not obvious — use AI
end

local function classify_input(input, model, session_ctx)
  local s = input:lower():match("^%s*(.-)%s*$")

  -- Fast path for trivially obvious cases
  local fast_intent = fast_classify(s)
  if fast_intent then return fast_intent, nil end

  -- AI classification
  if logging.dim then
    io.write(logging.dim("  [classifying...]\r"))
  else
    io.write("  [classifying...]\r")
  end

  local classify_prompt = prompts.build_classify_prompt({
    input           = input,
    session_context = session_ctx or "",
  })

  local raw = opencode.run_classify(classify_prompt, model)

  -- Parse response: first non-empty line is the intent, optional second is MODULE:
  local intent     = nil
  local mod_target = nil
  for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" then
      if not intent then
        local upper = line:upper()
        if upper:find("SELF_IMPROVE") or upper:find("SELF-IMPROVE") then
          intent = "self_improve"
        elseif upper:find("QUERY") then
          intent = "query"
        elseif upper:find("TASK") then
          intent = "task"
        end
      elseif line:upper():match("^MODULE:%s*(.+)") then
        mod_target = line:match("^[Mm][Oo][Dd][Uu][Ll][Ee]:%s*(.+)")
        mod_target = mod_target and mod_target:match("^%s*(.-)%s*$")
        break
      end
    end
  end

  -- Clear the classifying... line
  io.write(string.rep(" ", 20) .. "\r")

  -- Fallback: if the model returned something unparseable, default to task
  if not intent then
    logging.warn("Classifier returned unrecognised response — defaulting to task.")
    intent = "task"
  end

  return intent, mod_target
end

-- ---------------------------------------------------------------------------
-- run_self_improve_interactive — handle user-initiated self-improvement.
-- ---------------------------------------------------------------------------
local function run_self_improve_interactive(input, model, run_ts, mod_target)
  if mod_target then
    logging.step("SELF-IMPROVE", "Targeted: module " .. mod_target)
    self_improve.run_targeted(model, "user_request", {
      task_num        = "interactive",
      task_text       = input,
      prior_note      = "User explicitly requested improvement of module: " .. mod_target,
      target_override = { mod_target },
    })
  else
    logging.step("SELF-IMPROVE", "General pass (user-initiated)")
    self_improve.run_proactive(model, {
      tasks_done   = 0,
      tasks_failed = 0,
      failed_nums  = {},
      run_ts       = run_ts,
      user_request = input,
    })
  end
  __refresh_modules()
end

-- ---------------------------------------------------------------------------
-- run_query — one-shot Q&A, no Ralph loop, no compile check, no git commit
-- ---------------------------------------------------------------------------
local function run_query(question, model, version, run_ts, session_context)
  -- Strip leading "?" override prefix if present
  local clean = question:match("^%s*%?%s*(.-)%s*$") or question

  logging.step("QUERY", clean:sub(1, 60))

  os.execute('mkdir -p "' .. cfg.PROJECT_PATH .. '/logs"')
  local log_file = string.format("%s/logs/query-%s.log",
    cfg.PROJECT_PATH, run_ts)

  local prompt = prompts.build_query_prompt({
    question        = clean,
    version         = version,
    session_context = session_context or "",
  })

  opencode.run_fresh(log_file, prompt, model)
  print()
end

-- ---------------------------------------------------------------------------
-- Interactive REPL
-- ---------------------------------------------------------------------------
local function run_interactive_loop(model, version, has_sources, branch_name)
  local tech = project_type.get_tech(cfg)

  logging.header("============================================")
  logging.header("Interactive mode  (no todo.md found)")
  logging.header(string.format("Project type: %s | Tech: %s", cfg.PROJECT_TYPE, tech))
  logging.header("Ask a question or describe what you want built.")
  logging.header("Tips: ↑/↓ history  |  Ctrl-R search  |  \\ to continue on next line")
  logging.header("Prefix input with ? to force question mode (no file writes).")
  logging.header("Type  quit  or  exit  (or Ctrl-D) to end the session.")
  logging.header("============================================")
  print()

  local task_counter  = 0
  local tasks_done    = 0
  local tasks_failed  = 0
  local failed_labels = {}
  local run_ts        = os.date("%Y%m%d-%H%M%S")
  local prompt        = logging.bold_white("\n> ")

  -- Session journal: an ordered list of records describing what has been done.
  -- Each entry is a plain string injected verbatim into every subsequent prompt
  -- so the model always knows what already exists in the project.
  -- Format: "Task #N [status]: <description> → files: <list>"
  local journal = {}

  -- Build the session_context string from accumulated journal entries.
  -- Returns "" when the journal is empty (first task — no history yet).
  local function session_context()
    if #journal == 0 then return "" end
    return table.concat(journal, "\n")
  end

  -- Record a completed task in the journal, including which files changed.
  local function journal_record(num, text, status, changed_files)
    local files_str = #changed_files > 0
      and table.concat(changed_files, ", ")
      or  "no files changed"
    -- Strip PROJECT_PATH prefix from file paths for readability
    files_str = files_str:gsub(cfg.PROJECT_PATH .. "/", "")
    journal[#journal+1] = string.format(
      "Task #%s [%s]: %s → files: %s", num, status, text, files_str)
  end

  while true do
    local input = readline_input(prompt)
    if not input then break end
    if input == "" then
      logging.warn("Empty input — describe a task, ask a question, or type 'quit' to exit.")
      goto continue
    end
    if input:lower() == "quit" or input:lower() == "exit" then break end

    -- Special commands
    if input:lower() == "status" then
      print(string.format("Session: %s | Done: %d | Failed: %d | Type: %s",
        cfg.SESSION_NAME, tasks_done, tasks_failed, cfg.PROJECT_TYPE))
      goto continue
    end
    if input:lower() == "help" then
      print("Commands: status | quit | exit")
      print("Tasks       : describe what to build/fix/add — Ralph will write files.")
      print("Queries     : ask a question (starts with interrogative, ends with ?, or prefix with ?).")
      print("Self-improve: 'improve yourself', 'improve prompts', etc. — rewrites Ralph's own modules.")
      goto continue
    end

    -- Classify: query / self-improve / task
    local intent, mod_target = classify_input(input, model, session_context())

    if intent == "query" then
      run_query(input, model, version, run_ts, session_context())
    elseif intent == "self_improve" then
      run_self_improve_interactive(input, model, run_ts, mod_target)
    else
      task_counter = task_counter + 1
      local before = git_utils.snapshot_files()
      local success = run_task(task_counter, input, nil, model, version, has_sources, run_ts, session_context())
      local changed = git_utils.files_changed_since(before)

      if success then
        tasks_done = tasks_done + 1
        journal_record(task_counter, input, "done", changed)
        logging.ok("Task complete. What's next?")
      else
        tasks_failed = tasks_failed + 1
        journal_record(task_counter, input, "FAILED", changed)
        failed_labels[#failed_labels+1] = tostring(task_counter) .. "(" .. input:sub(1,30) .. ")"
        logging.warn("Task did not complete. You can rephrase and try again.")
      end

      __refresh_modules()
    end

    run_ts = os.date("%Y%m%d-%H%M%S")

    ::continue::
  end

  -- End-of-session proactive improvement pass
  if tasks_done + tasks_failed > 0 then
    logging.log("[SELF-IMPROVE] Session complete — running proactive improvement pass...")
    self_improve.run_proactive(model, {
      tasks_done   = tasks_done,
      tasks_failed = tasks_failed,
      failed_nums  = failed_labels,
      run_ts       = run_ts,
    })
    __refresh_modules()
  end

  print()
  logging.header("============================================")
  logging.header("Interactive session complete!")
  logging.header(string.format("  Branch      : %s", branch_name))
  logging.header(string.format("  Done        : %d", tasks_done))
  logging.header(string.format("  Failed      : %d", tasks_failed))
  if #failed_labels > 0 then
    logging.header("  Failed tasks: " .. table.concat(failed_labels, "  "))
  end
  logging.header(string.format("  Progress log: %s", cfg.PROGRESS_FILE))
  logging.header("============================================")
end

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------
local function main()
  local has_todo, has_sources = sanity_check()

  -- NOTE: os.execute('cd ...') would spawn a subshell and have no effect on the
  -- Lua process's working directory. All paths in this codebase are constructed
  -- as absolute strings so no chdir is actually needed. If a future feature
  -- requires relative-path resolution, use posix.chdir() from luaposix instead.

  local version = session.get_project_version()
  local tech    = project_type.get_tech(cfg)

  logging.header("============================================")
  logging.header("Ralph — AI Programming Orchestrator  [Self-Improving]")
  logging.header(string.format("  Kernel      : v%s (read-only)", KERNEL_VERSION))
  logging.header(string.format("  Project     : %s", cfg.PROJECT_PATH))
  logging.header(string.format("  Type        : %s", cfg.PROJECT_TYPE))
  logging.header(string.format("  Tech        : %s", tech))
  logging.header(string.format("  Version     : %s", version))
  logging.header(string.format("  Session     : %s", cfg.SESSION_NAME))
  if not has_sources then
    logging.header("  Mode        : New project (no source dirs yet)")
  elseif not has_todo then
    logging.header("  Mode        : Interactive (no todo.md)")
  end
  logging.header("============================================")
  print()

  session.handle_session_archive()
  session.ensure_state_files(version)

  -- Ensure git repo exists
  git_utils.ensure_git_repo()

  tool_reg.bootstrap()

  local model = session.select_model()
  print()

  -- Scaffold source dirs for new projects
  if not has_sources then
    logging.log("New project — scaffolding standard directory layout...")
    session.scaffold_project_dirs()
  end

  local branch_name = "feature/" .. cfg.SESSION_NAME
  git_utils.ensure_branch(branch_name)

  -- ----------------------------------------------------------------
  -- Branch: interactive vs todo.md-driven
  -- ----------------------------------------------------------------
  if not has_todo then
    run_interactive_loop(model, version, has_sources, branch_name)
  else
    local sections = todo_parser.parse_sections()
    if not sections or #sections == 0 then
      logging.err("No sections (### headings) found in todo.md"); os.exit(1)
    end
    local subsections = todo_parser.parse_subsections(sections)

    local sec_idx = todo_parser.select_section(sections, subsections)
    local section = sections[sec_idx]
    logging.log("Selected section: " .. section.name)

    local all_tasks, unchecked = todo_parser.parse_tasks(section)
    if not unchecked or #unchecked == 0 then
      logging.warn("No unchecked tasks found for section: " .. section.name); os.exit(0)
    end

    local selected = todo_parser.select_tasks(unchecked)
    logging.log(string.format("Running %d task(s).", #selected))

    local run_ts       = os.date("%Y%m%d-%H%M%S")
    local tasks_done   = 0
    local tasks_failed = 0
    local failed_nums  = {}
    local journal      = {}   -- same in-session context mechanism as interactive mode

    for _, task in ipairs(selected) do
      local ctx = #journal > 0 and table.concat(journal, "\n") or ""
      local before = git_utils.snapshot_files()
      local success = run_task(task.num, task.text, all_tasks, model, version, has_sources, run_ts, ctx)
      local changed = git_utils.files_changed_since(before)
      local files_str = #changed > 0
        and table.concat(changed, ", "):gsub(cfg.PROJECT_PATH .. "/", "")
        or  "no files changed"
      if success then
        tasks_done = tasks_done + 1
        journal[#journal+1] = string.format("Task #%s [done]: %s → files: %s", task.num, task.text, files_str)
      else
        tasks_failed = tasks_failed + 1
        failed_nums[#failed_nums+1] = task.num
        journal[#journal+1] = string.format("Task #%s [FAILED]: %s → files: %s", task.num, task.text, files_str)
      end
    end

    -- Proactive end-of-session self-improvement
    logging.log("[SELF-IMPROVE] Session complete — running proactive improvement pass...")
    self_improve.run_proactive(model, {
      tasks_done   = tasks_done,
      tasks_failed = tasks_failed,
      failed_nums  = failed_nums,
      run_ts       = run_ts,
    })
    __refresh_modules()

    -- Session summary
    print()
    logging.header("============================================")
    logging.header("Session complete!  [Ralph v" .. KERNEL_VERSION .. "]")
    logging.header(string.format("  Branch      : %s", branch_name))
    logging.header(string.format("  Type        : %s | %s", cfg.PROJECT_TYPE, tech))
    logging.header(string.format("  Done        : %d", tasks_done))
    logging.header(string.format("  Failed      : %d", tasks_failed))
    if #failed_nums > 0 then
      logging.header(string.format("  Failed tasks: %s", table.concat(failed_nums, " ")))
    end
    logging.header(string.format("  Progress log: %s", cfg.PROGRESS_FILE))
    logging.header(string.format("  Agents file : %s", cfg.AGENTS_FILE))
    logging.header(string.format("  Logs        : logs/*-%s.log", run_ts))
    logging.header("============================================")
  end

  -- Kernel suggestion notice
  local ks = io.open(cfg.PROJECT_PATH .. "/" .. cfg.KERNEL_SUGGESTIONS, "r")
  if ks then
    ks:close()
    print()
    logging.warn("╔══════════════════════════════════════════════════════════════╗")
    logging.warn("║  KERNEL SUGGESTIONS were written during this session.        ║")
    logging.warn("║  Review KERNEL_SUGGESTIONS.md before your next run.          ║")
    logging.warn("║  Apply improvements manually to run_automation.lua.          ║")
    logging.warn("║  Bump KERNEL_VERSION after applying.                         ║")
    logging.warn("╚══════════════════════════════════════════════════════════════╝")
  end

  io.write("\nPress Enter to close...")
  io.read()
end

main()
