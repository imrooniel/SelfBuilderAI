--[[
  modules/project_type.lua — project-type profiles.
  AI-rewritable.

  Each profile describes:
    extensions  — tracked source file extensions (for snapshot)
    tech        — human-readable technology description (injected into prompts)
    src_dirs    — standard source directory layout
    compile     — function(cfg) → ok(bool), errors_text(string)
    check       — optional secondary analysis, same signature (or nil)

  Adding a new project type:
    1. Add an entry to PROFILES keyed by the type string.
    2. Set cfg.PROJECT_TYPE = "<your_key>" in config.lua.
    3. The compile/check lambdas receive the live cfg table.
]]

local M = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function run_cmd(cmd)
  local handle = io.popen(cmd .. " 2>&1")
  local out = handle and handle:read("*a") or ""
  local ok  = handle and handle:close()
  return (ok == true or ok == 0), out
end

local function grep_errors(output, patterns)
  local errors = {}
  for line in output:gmatch("[^\n]+") do
    for _, pat in ipairs(patterns) do
      if line:match(pat) then
        errors[#errors+1] = line
        break
      end
    end
  end
  return errors
end

-- ---------------------------------------------------------------------------
-- Profile definitions
-- ---------------------------------------------------------------------------
M.PROFILES = {

  -- ── generic ────────────────────────────────────────────────────────────
  generic = {
    tech       = "general software project",
    extensions = { [".lua"]=true,[".py"]=true,[".js"]=true,[".ts"]=true,
                   [".go"]=true,[".rs"]=true,[".c"]=true,[".cpp"]=true,
                   [".h"]=true,[".java"]=true,[".rb"]=true,[".sh"]=true },
    src_dirs   = { "src", "lib", "scripts" },
    compile    = nil,   -- no compile check
    check      = nil,
  },

  -- ── unity ──────────────────────────────────────────────────────────────
  unity = {
    tech       = "Unity C# (MonoBehaviour, ScriptableObject, ECS)",
    extensions = { [".cs"]=true,[".shader"]=true,[".hlsl"]=true,
                   [".compute"]=true,[".asmdef"]=true,[".asmref"]=true,
                   [".json"]=true,[".asset"]=true },
    src_dirs   = {
      "Assets/Scripts/Core",
      "Assets/Scripts/Editor",
      "Assets/ScriptableObjects",
      "Assets/Shaders",
    },
    compile = function(cfg)
      local f = io.open(cfg.UNITY_EDITOR, "r")
      if not f then
        return true, "SKIPPED: Unity editor binary not found at " .. cfg.UNITY_EDITOR
      end
      f:close()
      local log = os.tmpname()
      local cmd = string.format(
        '"%s" -quit -batchmode -nographics -logFile "%s" -projectPath "%s" 2>/dev/null',
        cfg.UNITY_EDITOR, log, cfg.PROJECT_PATH)
      local exit_ok = os.execute(cmd)
      local unity_ok = (exit_ok == true or exit_ok == 0)
      local errors = {}
      local fh = io.open(log, "r")
      if fh then
        for line in fh:lines() do
          if line:match("error CS%d+") or line:match("Exception.*:") then
            errors[#errors+1] = line:gsub("^%s+", "")
          end
        end
        fh:close(); os.remove(log)
      end
      if #errors == 0 and not unity_ok then
        errors[#errors+1] = "Unity batch compile exited with non-zero status"
      end
      return #errors == 0, table.concat(errors, "\n")
    end,
    check = function(cfg)
      -- JetBrains inspectcode (optional)
      local h = io.popen("which jb 2>/dev/null")
      local r = h and h:read("*a") or ""
      if h then h:close() end
      if not r:match("%S") then return true, "SKIPPED: jb not in PATH" end

      local sln = cfg.SOLUTION_FILE
      if not sln then
        local sh = io.popen(string.format('ls "%s"/*.sln 2>/dev/null | head -1', cfg.PROJECT_PATH))
        sln = sh and sh:read("*a"):gsub("%s+$","") or ""
        if sh then sh:close() end
      end
      if not sln or sln == "" then return true, "SKIPPED: no .sln found" end

      local xml = os.tmpname()
      local lg  = os.tmpname()
      os.execute(string.format(
        'jb inspectcode "%s" --severity=ERROR -f=Xml -o="%s" --verbosity=WARN > "%s" 2>&1',
        sln, xml, lg))

      local errors = {}
      local fl = io.open(lg, "r")
      if fl then
        for line in fl:lines() do
          if line:match("%[MsBuild%].*CS%d+") or line:lower():match("^%[error%]") then
            errors[#errors+1] = line
          end
        end
        fl:close(); os.remove(lg)
      end
      local fx = io.open(xml, "r")
      if fx then
        local content = fx:read("*a"); fx:close(); os.remove(xml)
        for issue in content:gmatch("<Issue[^>]+>") do
          local file_ = issue:match('File="([^"]*)"')   or "?"
          local line_ = issue:match('Line="([^"]*)"')   or "?"
          local msg   = issue:match('Message="([^"]*)"') or "?"
          errors[#errors+1] = string.format("%s(%s): %s", file_, line_, msg)
        end
      end
      return #errors == 0, table.concat(errors, "\n")
    end,
  },

  -- ── rust ───────────────────────────────────────────────────────────────
  rust = {
    tech       = "Rust (cargo)",
    extensions = { [".rs"]=true,[".toml"]=true },
    src_dirs   = { "src", "tests", "examples" },
    compile = function(cfg)
      local ok, out = run_cmd(string.format('cd "%s" && cargo build 2>&1', cfg.PROJECT_PATH))
      local errors = grep_errors(out, { "^error", "^error%[" })
      return #errors == 0, table.concat(errors, "\n")
    end,
    check = function(cfg)
      local ok, out = run_cmd(string.format('cd "%s" && cargo clippy -- -D warnings 2>&1', cfg.PROJECT_PATH))
      local errors = grep_errors(out, { "^error", "warning%[" })
      return #errors == 0, table.concat(errors, "\n")
    end,
  },

  -- ── node ───────────────────────────────────────────────────────────────
  node = {
    tech       = "Node.js / TypeScript",
    extensions = { [".ts"]=true,[".tsx"]=true,[".js"]=true,[".jsx"]=true,
                   [".json"]=true,[".mts"]=true,[".cts"]=true },
    src_dirs   = { "src", "lib", "test", "tests" },
    compile = function(cfg)
      -- try tsc first, fall back to npm run build
      local tsc_ok, tsc_out = run_cmd(
        string.format('cd "%s" && npx tsc --noEmit 2>&1', cfg.PROJECT_PATH))
      if tsc_out:match("error TS%d+") then
        local errors = grep_errors(tsc_out, { "error TS%d+" })
        return false, table.concat(errors, "\n")
      end
      -- also try npm run build if package.json has a build script
      local pb = io.open(cfg.PROJECT_PATH .. "/package.json", "r")
      if pb then
        local pkg = pb:read("*a"); pb:close()
        if pkg:match('"build"') then
          local ok2, out2 = run_cmd(
            string.format('cd "%s" && npm run build 2>&1', cfg.PROJECT_PATH))
          if not ok2 then
            return false, out2
          end
        end
      end
      return true, ""
    end,
    check = function(cfg)
      -- ESLint if available
      local h = io.popen(string.format(
        'cd "%s" && npx eslint src --max-warnings=0 2>&1', cfg.PROJECT_PATH))
      local out = h and h:read("*a") or ""
      if h then h:close() end
      local errors = grep_errors(out, { "^/", "Error:", "error " })
      return #errors == 0, table.concat(errors, "\n")
    end,
  },

  -- ── python ─────────────────────────────────────────────────────────────
  python = {
    tech       = "Python 3",
    extensions = { [".py"]=true,[".pyi"]=true,[".toml"]=true,[".cfg"]=true },
    src_dirs   = { "src", "tests", "scripts" },
    compile = function(cfg)
      -- pyflakes for quick syntax/import check
      local ok, out = run_cmd(string.format(
        'cd "%s" && python3 -m pyflakes . 2>&1', cfg.PROJECT_PATH))
      local errors = grep_errors(out, { "%.py:%d+:", "SyntaxError", "ImportError" })
      return #errors == 0, table.concat(errors, "\n")
    end,
    check = function(cfg)
      -- mypy (optional)
      local h = io.popen("which mypy 2>/dev/null")
      local r = h and h:read("*a") or ""; if h then h:close() end
      if not r:match("%S") then return true, "SKIPPED: mypy not installed" end
      local ok, out = run_cmd(string.format(
        'cd "%s" && mypy . --ignore-missing-imports 2>&1', cfg.PROJECT_PATH))
      local errors = grep_errors(out, { "error:", "Found %d+ error" })
      return #errors == 0, table.concat(errors, "\n")
    end,
  },

  -- ── go ─────────────────────────────────────────────────────────────────
  go = {
    tech       = "Go",
    extensions = { [".go"]=true,[".mod"]=true,[".sum"]=true },
    src_dirs   = { "cmd", "internal", "pkg" },
    compile = function(cfg)
      local ok, out = run_cmd(string.format('cd "%s" && go build ./... 2>&1', cfg.PROJECT_PATH))
      local errors = grep_errors(out, { "%.go:%d+:%d+:", "^#" })
      return #errors == 0, table.concat(errors, "\n")
    end,
    check = function(cfg)
      local ok, out = run_cmd(string.format('cd "%s" && go vet ./... 2>&1', cfg.PROJECT_PATH))
      local errors = grep_errors(out, { "%.go:%d+" })
      return #errors == 0, table.concat(errors, "\n")
    end,
  },

  -- ── custom ─────────────────────────────────────────────────────────────
  custom = {
    tech       = "custom project (configure in config.lua)",
    extensions = { [".c"]=true,[".cpp"]=true,[".h"]=true,[".hpp"]=true,
                   [".py"]=true,[".js"]=true,[".ts"]=true,[".rs"]=true },
    src_dirs   = { "src" },
    compile = function(cfg)
      if not cfg.CUSTOM_COMPILE_CMD then return true, "SKIPPED: no CUSTOM_COMPILE_CMD set" end
      local cmd = cfg.CUSTOM_COMPILE_CMD:format(cfg.PROJECT_PATH)
      local ok, out = run_cmd(cmd)
      return ok, out
    end,
    check = function(cfg)
      if not cfg.CUSTOM_CHECK_CMD then return true, "SKIPPED: no CUSTOM_CHECK_CMD set" end
      local cmd = cfg.CUSTOM_CHECK_CMD:format(cfg.PROJECT_PATH)
      local ok, out = run_cmd(cmd)
      return ok, out
    end,
  },
}

-- ---------------------------------------------------------------------------
-- resolve — return profile for cfg.PROJECT_TYPE (fallback: generic)
-- ---------------------------------------------------------------------------
function M.resolve(cfg)
  return M.PROFILES[cfg.PROJECT_TYPE] or M.PROFILES["generic"]
end

-- ---------------------------------------------------------------------------
-- get_extensions — return effective SNAPSHOT_EXTENSIONS table
-- ---------------------------------------------------------------------------
function M.get_extensions(cfg)
  if cfg.SNAPSHOT_EXTENSIONS then return cfg.SNAPSHOT_EXTENSIONS end
  local profile = M.resolve(cfg)
  return profile.extensions or M.PROFILES["generic"].extensions
end

-- ---------------------------------------------------------------------------
-- get_tech — return technology description string
-- ---------------------------------------------------------------------------
function M.get_tech(cfg)
  if cfg.TECH_DESCRIPTION then return cfg.TECH_DESCRIPTION end
  local profile = M.resolve(cfg)
  return profile.tech or "software project"
end

-- ---------------------------------------------------------------------------
-- get_src_dirs — return list of canonical source directories
-- ---------------------------------------------------------------------------
function M.get_src_dirs(cfg)
  local profile = M.resolve(cfg)
  return profile.src_dirs or { "src" }
end

return M
