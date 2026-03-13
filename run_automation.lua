#!/usr/bin/env lua
--[[
  run_automation.lua — KERNEL (read-only to the AI agent)

  SelfBuilderAI - a general-purpose AI agent orchestrator extending the Ralph pattern
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
KERNEL_VERSION = "2.2.0"

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

-- Kernel source path exposed to self_improve (read-only use).
-- Stored in both cfg and _G so modules can read it either way.
KERNEL_SOURCE_PATH = BASE_DIR .. "run_automation.lua"
cfg.KERNEL_SOURCE_PATH   = KERNEL_SOURCE_PATH
cfg.KERNEL_MODULES_DIR   = BASE_DIR .. "modules"

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
  local log_file    = string.format("%s/logs/%s-task-%s-%s.log",
    cfg.PROJECT_PATH, run_ts, task_num, task_slug(task_text))
  local error_out   = cfg.PROJECT_PATH .. "/.ralph-errors"
  local slug        = task_slug(task_text)
  local tool_ctx    = tool_reg.describe_tools()
  local section_ctx = all_tasks and todo_parser.build_section_context(all_tasks) or ""

  -- Ensure logs dir exists
  os.execute('mkdir -p "' .. cfg.PROJECT_PATH .. '/logs"')

  -- Fresh start
  logging.header(string.format("\n[TASK #%s] %s", task_num, task_text))
  logging.log("Log: " .. log_file)

  local function session_context_fn()
    return type(session_context) == "function" and session_context() or (session_context or "")
  end

  -- Outer loop: fresh context attempts
  for iteration = 1, cfg.MAX_ITERATIONS do
    local prior_note = "No details recorded."
    if iteration > 1 then
      local pf = io.open(cfg.PROJECT_PATH .. "/" .. cfg.PROGRESS_FILE, "r")
      if pf then
        local content = pf:read("*a"); pf:close()
        local last_block = content:match("\n## %[.-%] Task #" .. task_num .. ":(.-)\n## %[") or ""
        prior_note = last_block ~= "" and last_block or "Previous iteration made no changes"
      end
    end

    local prompt = prompts.build_task_prompt({
      task_num        = task_num,
      task_text       = task_text,
      section_context = section_ctx,
      iteration       = iteration,
      prior_note      = prior_note,
      version         = version,
      tool_context    = tool_ctx,
      session_context = session_context_fn(),
    })

    logging.step("ITERATION", string.format("%d/%d", iteration, cfg.MAX_ITERATIONS))
    local _, session_id = opencode.run_fresh(log_file, prompt, model)

    -- Inner loop: continue nudges
    local continue_count = 0
    while continue_count < cfg.MAX_CONTINUES and not opencode.log_says_done(log_file) do
      continue_count = continue_count + 1
      logging.step("NUDGE", string.format("%d/%d", continue_count, cfg.MAX_CONTINUES))
      opencode.run_continue(log_file, session_id, prompts.get_nudge(continue_count), model)
    end

    tool_reg.process_tool_calls(log_file, task_num, run_ts)

    if opencode.log_says_done(log_file) then
      -- Self-reflection pass (if enabled)
      if cfg.SELF_REFLECTION_ENABLED then
        logging.step("REFLECT", "Running self-review...")
        local reflection_prompt = prompts.build_reflection_prompt({
          task_num  = task_num,
          task_text = task_text,
          version   = version,
        })
        opencode.run_continue(log_file, session_id, reflection_prompt, model)

        -- Give model a chance to fix issues it found
        local reflection_round = 0
        while reflection_round < cfg.SELF_REFLECTION_MAX_ROUNDS do
          if opencode.log_says_reflection_ok(log_file) then
            logging.ok("Self-reflection passed — model approved its work")
            break
          end
          
          if opencode.log_says_done(log_file) then
            logging.log("Model made corrections during reflection")
            break
          end

          reflection_round = reflection_round + 1
          if reflection_round < cfg.SELF_REFLECTION_MAX_ROUNDS then
            logging.step("REFLECT", string.format("nudge %d/%d", reflection_round, cfg.SELF_REFLECTION_MAX_ROUNDS))
            opencode.run_continue(log_file, session_id,
              "Continue your self-review. Fix any remaining issues or output REFLECTION_OK if satisfied.", model)
          end
        end
      end

      -- Compile/check pass
      local fix_round = 0
      while fix_round < cfg.MAX_FIX_ROUNDS do
        local clean = compile.run_compile_check(error_out)
        if clean then
          git_utils.git_commit(task_num, slug, task_text, true)
          session.append_progress(task_num, task_text, "Task completed successfully.")
          if all_tasks then todo_parser.mark_task_done(task_num, task_text) end
          logging.ok("DONE — clean compile, moving on.")
          return true
        end

        -- Targeted self-improvement on compile failure
        if cfg.SELF_IMPROVE_ENABLED and cfg.SELF_IMPROVE_TARGETED then
          logging.log("[SELF-IMPROVE] Compile failed — running targeted improvement pass...")
          self_improve.run_targeted(model, {
            reason     = "compile_failure",
            task_num   = task_num,
            task_text  = task_text,
            error_out  = error_out,
            log_file   = log_file,
            run_ts     = run_ts,
          })
          __refresh_modules()
        end

        fix_round = fix_round + 1
        logging.step("FIX", string.format("round %d/%d", fix_round, cfg.MAX_FIX_ROUNDS))

        local fix_prompt = prompts.build_fix_prompt({
          task_num    = task_num,
          task_text   = task_text,
          error_out   = error_out,
          round       = fix_round,
          version     = version,
        })
        opencode.run_continue(log_file, session_id, fix_prompt, model)

        local fix_nudges = 0
        while fix_nudges < 2 and not opencode.log_says_done(log_file) do
          fix_nudges = fix_nudges + 1
          opencode.run_continue(log_file, session_id, prompts.get_fix_nudge(fix_round), model)
        end
      end

      -- Exceeded fix rounds
      git_utils.git_commit(task_num, slug, task_text, false)
      session.append_progress(task_num, task_text, "Task completed but compile errors remain.")
      logging.warn("Compile errors persist after max fix rounds.")
      return false
    end
  end

  -- Exceeded iteration limit
  git_utils.git_commit(task_num, slug, task_text, false)
  session.append_progress(task_num, task_text, "Task incomplete after max iterations.")
  logging.warn("Max iterations reached without completion.")
  return false
end

-- ---------------------------------------------------------------------------
-- Interactive loop — replaced automatic classification with explicit menu
-- ---------------------------------------------------------------------------
local function run_interactive_loop(model, version, has_sources, branch_name)
  local tasks_done   = 0
  local tasks_failed = 0
  local failed_labels = {}
  local task_counter = 0
  local run_ts       = os.date("%Y%m%d-%H%M%S")
  local journal      = {}

  local function session_context()
    if #journal == 0 then return "" end
    local max = cfg.CTX_JOURNAL_ENTRIES or 10
    if #journal <= max then return table.concat(journal, "\n") end
    local tail = {}
    for i = #journal - max + 1, #journal do tail[#tail+1] = journal[i] end
    return "[... " .. (#journal - max) .. " earlier entries omitted ...]\n" .. table.concat(tail, "\n")
  end

  local function journal_record(task_num, task_text, status, changed)
    local files_str = #changed > 0
      and table.concat(changed, ", "):gsub(cfg.PROJECT_PATH .. "/", "")
      or  "no files changed"
    journal[#journal+1] = string.format("Task #%s [%s]: %s → files: %s", task_num, status, task_text, files_str)
  end

  logging.header("\n============================================")
  logging.header("Interactive Mode")
  logging.header("Branch: " .. branch_name)
  logging.header("============================================\n")

  while true do
    print()
    print(logging.bold_white("┌──────────────────────────────────────┐"))
    print(logging.bold_white("│  Select action:                      │"))
    print(logging.bold_white("├──────────────────────────────────────┤"))
    print(logging.bold_white("│  1) Task     — build/modify project  │"))
    print(logging.bold_white("│  2) Improve  — improve SelfBuilderAI │"))
    print(logging.bold_white("│  3) Query    — ask a question        │"))
    print(logging.bold_white("│  q) Quit                             │"))
    print(logging.bold_white("└──────────────────────────────────────┘"))
    print()
    io.write("Choice: ")
    local choice = io.read()

    if choice == "q" or choice == "Q" then
      break
    end

    local action_type = nil
    if choice == "1" then
      action_type = "TASK"
    elseif choice == "2" then
      action_type = "SELF_IMPROVE"
    elseif choice == "3" then
      action_type = "QUERY"
    else
      logging.warn("Invalid choice: '" .. tostring(choice) .. "'")
      goto continue
    end

    -- Get user input
    print()
    if action_type == "TASK" then
      io.write("Describe the task: ")
    elseif action_type == "SELF_IMPROVE" then
      io.write("What should be improved? ")
    elseif action_type == "QUERY" then
      io.write("Your question: ")
    end
    local input = io.read()

    if not input or input:match("^%s*$") then
      logging.warn("Empty input — skipping.")
      goto continue
    end

    -- Handle based on action type
    if action_type == "QUERY" then
      logging.log("[QUERY] Processing question...")
      local query_prompt = prompts.build_query_prompt({
        question        = input,
        version         = version,
        session_context = session_context(),
      })
      local response = opencode.run_classify(query_prompt, model)
      -- Response already streamed to stdout by run_classify() with color coding
      
      -- Record Q&A in journal so subsequent queries have conversational context
      journal[#journal+1] = string.format("Q: %s\nA: %s", input, response)

    elseif action_type == "SELF_IMPROVE" then
      logging.log("[SELF-IMPROVE] Processing improvement request...")
      
      -- Optional: ask which module to focus on
      io.write("Focus on specific module? (or press Enter to skip): ")
      local module_input = io.read()
      local target_module = nil
      if module_input and not module_input:match("^%s*$") then
        target_module = module_input:match("^%s*(.-)%s*$")
      end

      self_improve.run_targeted(model, {
        reason        = input:match("^%s*(.-)%s*$"), -- trim whitespace
        target_module = target_module,
        run_ts        = run_ts,
      })
      __refresh_modules()
      logging.ok("Self-improvement pass complete.")

    else  -- TASK
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
  logging.header("SelfBuilderAI — AI Programming Orchestrator  [Self-Improving]")
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
  session.prune_old_logs()

  -- Ensure git repo exists
  git_utils.ensure_git_repo()

  tool_reg.bootstrap()

  local model = cfg.DEFAULT_MODEL or session.select_model()
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
    logging.header("Session complete!  [SelfBuilderAI v" .. KERNEL_VERSION .. "]")
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
