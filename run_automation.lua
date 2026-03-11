#!/usr/bin/env lua
--[[
  run_automation.lua — KERNEL (read-only to the AI agent)

  This file boots the entire orchestration system. It is the only file
  the AI cannot rewrite. It CAN read this file and suggest improvements
  via KERNEL_SUGGESTIONS.md, which the user reviews manually.

  Responsibilities:
    - Bootstrap the module loader and hot-reload system
    - Validate environment (paths, opencode, todo.md)
    - Drive the top-level task loop
    - Trigger self-improvement passes (targeted on failure, proactive at session end)
    - Trigger kernel-suggestion pass on task failure
    - Print session summary and kernel-suggestion notice

  Module layout (all rewritable by the AI):
    modules/config.lua         — paths and tuneable constants
    modules/logging.lua        — coloured log helpers
    modules/session.lua        — archive, state-file bootstrap, model selection
    modules/todo_parser.lua    — parse/select/mark tasks
    modules/git_utils.lua      — git wrappers, file snapshot
    modules/compile.lua        — Unity batch compile + inspectcode
    modules/prompts.lua        — build_task_prompt(), build_fix_prompt(), nudges
    modules/opencode.lua       — run_opencode_fresh(), run_opencode_continue()
    modules/hot_reload.lua     — safe module hot-swap with rollback
    modules/tool_registry.lua  — dynamic tool loading/calling
    modules/self_improve.lua   — AI self-improvement orchestration

  tools/                       — AI-written tools (empty at start)
]]

-- ---------------------------------------------------------------------------
-- Kernel version — bump manually when you apply AI suggestions
-- ---------------------------------------------------------------------------
KERNEL_VERSION = "1.0.0"

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
-- Bootstrap: load hot_reload first (needed to load everything else safely)
-- ---------------------------------------------------------------------------
local ok_hr, hot_reload = pcall(require, "hot_reload")
if not ok_hr then
  io.stderr:write("[KERNEL] FATAL: cannot load modules/hot_reload.lua\n")
  io.stderr:write(tostring(hot_reload) .. "\n")
  os.exit(1)
end

-- Load all other modules through hot_reload so they are registered
-- and can be reloaded later without restarting the process.
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
local session      = load_module("session")
local todo_parser  = load_module("todo_parser")
local git_utils    = load_module("git_utils")
local compile      = load_module("compile")
local prompts      = load_module("prompts")
local opencode     = load_module("opencode")
local tool_reg     = load_module("tool_registry")
local self_improve = load_module("self_improve")

-- Expose module reloader so self_improve can hot-swap modules
-- without touching the kernel.
_G.__reload_module = function(name)
  local new_mod, err = hot_reload.reload(name)
  if not new_mod then
    logging.warn("Hot-reload FAILED for " .. name .. ": " .. tostring(err))
    return false, err
  end
  logging.log("Hot-reloaded module: " .. name)
  return true
end

-- ---------------------------------------------------------------------------
-- Re-fetch module refs after any hot-reload (called by self_improve)
-- ---------------------------------------------------------------------------
function _G.__refresh_modules()
  cfg          = hot_reload.get("config")        or cfg
  logging      = hot_reload.get("logging")       or logging
  session      = hot_reload.get("session")       or session
  todo_parser  = hot_reload.get("todo_parser")   or todo_parser
  git_utils    = hot_reload.get("git_utils")     or git_utils
  compile      = hot_reload.get("compile")       or compile
  prompts      = hot_reload.get("prompts")       or prompts
  opencode     = hot_reload.get("opencode")      or opencode
  tool_reg     = hot_reload.get("tool_registry") or tool_reg
  self_improve = hot_reload.get("self_improve")  or self_improve
end

-- ---------------------------------------------------------------------------
-- Kernel source path — AI may read this file but NEVER writes it
-- ---------------------------------------------------------------------------
KERNEL_SOURCE_PATH = BASE_DIR .. "run_automation.lua"

-- ---------------------------------------------------------------------------
-- Sanity checks
-- ---------------------------------------------------------------------------
local function sanity_check()
  if not cfg.PROJECT_PATH or cfg.PROJECT_PATH == "" then
    logging.err("PROJECT_PATH not set in config.lua"); os.exit(1)
  end
  local function is_dir(p)
    local f = io.open(p .. "/.test_kernel_probe", "w")
    if f then f:close(); os.remove(p .. "/.test_kernel_probe"); return true end
    -- fallback: try opening path itself
    return os.execute('test -d "' .. p .. '"') == 0
  end
  if not is_dir(cfg.PROJECT_PATH) then
    logging.err("Project path not found: " .. cfg.PROJECT_PATH); os.exit(1)
  end
  if not is_dir(cfg.PROJECT_PATH .. "/Assets") then
    logging.err("Not a Unity project (no Assets/): " .. cfg.PROJECT_PATH); os.exit(1)
  end
  local f = io.open(cfg.PROJECT_PATH .. "/todo.md", "r")
  if not f then
    logging.err("todo.md not found: " .. cfg.PROJECT_PATH .. "/todo.md"); os.exit(1)
  end
  f:close()
end

-- ---------------------------------------------------------------------------
-- slug helper
-- ---------------------------------------------------------------------------
local function task_slug(text)
  local s = text:lower():gsub("[^a-z0-9 ]", ""):gsub("%s+", "-")
  return s:sub(1, 40)
end

-- ---------------------------------------------------------------------------
-- Single-task runner
-- ---------------------------------------------------------------------------
local function run_task(task, all_tasks, model, unity_version, run_ts)
  -- Reload prompts/opencode refs each task so self-improvements take effect
  __refresh_modules()

  local task_num  = task.num
  local task_text = task.text
  local slug      = task_slug(task_text)
  local task_start = os.time()

  print()
  logging.header("============================================")
  logging.header(string.format("[TASK #%s] %s", task_num, task_text))
  logging.header("============================================")

  os.execute('mkdir -p "' .. cfg.PROJECT_PATH .. '/logs"')

  local before_snapshot   = git_utils.snapshot_files()
  local section_context   = todo_parser.build_section_context(all_tasks)

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
      "Ralph iteration %d/%d — fresh context | log: %s-%s-iter%d-%s.log",
      iteration, cfg.MAX_ITERATIONS, task_num, slug, iteration, run_ts))
    print()

    -- Let tool_registry inject available tools into prompt context
    local tool_context = tool_reg.describe_tools()

    local prompt = prompts.build_task_prompt({
      task_num      = task_num,
      task_text     = task_text,
      section_context = section_context,
      iteration     = iteration,
      prior_note    = prior_note,
      unity_version = unity_version,
      tool_context  = tool_context,
    })

    local _, current_session = opencode.run_fresh(log_file, prompt, model)
    changed   = git_utils.files_changed_since(before_snapshot)
    said_done = opencode.log_says_done(log_file)

    -- Let the agent invoke any tools it requested in its output
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

    -- Compile check + fix loop
    local fix_round     = 0
    local compile_clean = true
    local compile_error_file = string.format("%s/logs/%s-compile-errors-%s.txt",
      cfg.PROJECT_PATH, task_num, run_ts)

    logging.log("Running compile check (Unity batch + inspectcode)...")
    if not compile.run_compile_check(compile_error_file) then
      compile_clean = false
      local errors = compile.read_errors(compile_error_file)
      logging.warn(string.format("Compile errors detected (%d error(s)):", #errors))
      for _, e in ipairs(errors) do print("          " .. e) end
    else
      logging.ok("Compile check passed.")
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
        task_num      = task_num,
        task_text     = task_text,
        compile_errors = errors_text,
        unity_version = unity_version,
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
        logging.ok(string.format("Compile errors resolved after fix round %d.", fix_round))
        break
      else
        local errs = compile.read_errors(compile_error_file)
        logging.warn(string.format("Still has errors after fix round %d:", fix_round))
        for _, e in ipairs(errs) do print("          " .. e) end
      end
    end

    if not compile_clean then
      logging.warn(string.format(
        "Errors remain after %d fix round(s) — committing for manual review.", cfg.MAX_FIX_ROUNDS))
    end

    git_utils.git_commit(task_num, slug, task_text, compile_clean)
    todo_parser.mark_task_done(task_num, task_text)

    for _, t in ipairs(all_tasks) do
      if t.num == task_num then t.state = "done"; break end
    end

    session.append_progress(task_num, task_text,
      string.format("Completed in %d iteration(s) [%ds]. Compile clean: %s.",
        iteration, elapsed, tostring(compile_clean)))

    -- Proactive self-improvement: targeted module rewrite after compile failure
    if not compile_clean then
      logging.log("[SELF-IMPROVE] Compile errors persisted — running targeted improvement pass...")
      self_improve.run_targeted(model, "compile_failure", {
        task_num  = task_num,
        task_text = task_text,
        errors    = compile.read_errors_raw(compile_error_file),
      })
      __refresh_modules()
    end

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

  -- On failure: targeted module self-improvement + kernel suggestion pass
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
-- Entry point
-- ---------------------------------------------------------------------------
local function main()
  sanity_check()

  -- cd to project so relative paths work
  os.execute('cd "' .. cfg.PROJECT_PATH .. '"')

  local unity_version = session.get_unity_version()
  os.execute('export UNITY_PROJECT_PATH="' .. cfg.PROJECT_PATH .. '"')
  os.execute('export UNITY_EDITOR="'       .. cfg.UNITY_EDITOR  .. '"')

  logging.header("============================================")
  logging.header(string.format("Unity Task Runner  [Ralph pattern + Self-Improvement]"))
  logging.header(string.format("  Kernel  : v%s (read-only)", KERNEL_VERSION))
  logging.header(string.format("  Project : %s", cfg.PROJECT_PATH))
  logging.header(string.format("  Unity   : %s", unity_version))
  logging.header("============================================")
  print()

  session.handle_session_archive()
  session.ensure_state_files(unity_version)
  tool_reg.bootstrap()   -- scan tools/ and register any existing tools

  local model = session.select_model()
  print()

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

  local branch_name = "feature/" .. cfg.SESSION_NAME
  git_utils.ensure_branch(branch_name)

  -- Ensure standard Unity directories
  for _, d in ipairs({
    "Assets/Scripts/Core", "Assets/Scripts/Editor",
    "Assets/ScriptableObjects", "Assets/Shaders",
  }) do
    os.execute('mkdir -p "' .. cfg.PROJECT_PATH .. "/" .. d .. '"')
  end
  logging.log("Ensured standard Unity directories exist.")

  local run_ts = os.date("%Y%m%d-%H%M%S")
  local tasks_done   = 0
  local tasks_failed = 0
  local failed_nums  = {}

  for _, task in ipairs(selected) do
    local success = run_task(task, all_tasks, model, unity_version, run_ts)
    if success then
      tasks_done = tasks_done + 1
    else
      tasks_failed = tasks_failed + 1
      failed_nums[#failed_nums+1] = task.num
    end
  end

  -- ----------------------------------------------------------------
  -- Proactive end-of-session self-improvement pass
  -- ----------------------------------------------------------------
  logging.log("[SELF-IMPROVE] Session complete — running proactive improvement pass...")
  self_improve.run_proactive(model, {
    tasks_done   = tasks_done,
    tasks_failed = tasks_failed,
    failed_nums  = failed_nums,
    run_ts       = run_ts,
  })
  __refresh_modules()

  -- ----------------------------------------------------------------
  -- Session summary
  -- ----------------------------------------------------------------
  print()
  logging.header("============================================")
  logging.header("Session complete!  [Ralph pattern + Self-Improvement]")
  logging.header(string.format("  Branch      : %s", branch_name))
  logging.header(string.format("  Done        : %d", tasks_done))
  logging.header(string.format("  Failed      : %d", tasks_failed))
  if #failed_nums > 0 then
    logging.header(string.format("  Failed tasks: %s", table.concat(failed_nums, " ")))
  end
  logging.header(string.format("  Progress log: %s", cfg.PROGRESS_FILE))
  logging.header(string.format("  Agents file : %s", cfg.AGENTS_FILE))
  logging.header(string.format("  Logs        : logs/*-%s.log", run_ts))
  logging.header("============================================")

  -- Kernel suggestion notice
  local ks = io.open(cfg.PROJECT_PATH .. "/KERNEL_SUGGESTIONS.md", "r")
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
