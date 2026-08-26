--- Telescope pickers for browsing remote (ssh cd/pwd/ls) and local (vim.fs) paths.
--- One shared picker builder; the lister and path helpers are injected per mode.
--- Selection model: `<CR>` on a dir descends, on "./" confirms the current dir,
--- on a file picks it (only when files are listed). `<Esc>` cancels.
local config = require("nvim-scp.config")
local transfer = require("nvim-scp.transfer")

local M = {}

local function telescope_modules()
  local ok, mods = pcall(function()
    return {
      pickers = require("telescope.pickers"),
      finders = require("telescope.finders"),
      sorters = require("telescope.sorters"),
      actions = require("telescope.actions"),
      action_state = require("telescope.actions.state"),
    }
  end)
  if not ok then
    vim.notify("nvim-scp: telescope.nvim is required", vim.log.levels.ERROR)
    return nil
  end
  return mods
end

---@param title string
---@param entries table[] {name: string, is_dir?: boolean} in display order
---@param on_select fun(entry: table)
local function open_picker(mods, title, entries, on_select)
  mods.pickers
    .new({}, {
      prompt_title = title,
      finder = mods.finders.new_table({
        results = entries,
        entry_maker = function(e)
          return {
            value = e,
            display = e.name .. (e.is_dir and "/" or ""),
            ordinal = e.name,
          }
        end,
      }),
      sorter = mods.sorters.get_generic_fuzzy_sorter(),
      attach_mappings = function(prompt_bufnr, _)
        mods.actions.select_default:replace(function()
          local entry = mods.action_state.get_selected_entry()
          mods.actions.close(prompt_bufnr)
          -- Reopening a picker inside the close path misbehaves; defer one tick.
          if entry then
            vim.schedule(function()
              on_select(entry.value)
            end)
          end
        end)
        return true
      end,
    })
    :find()
end

--- Normalize a remote path: strip trailing "/" ("~/" -> "~"), keep "/" as-is.
local function norm_remote(p)
  if p == "/" or p == "~" then
    return p
  end
  local r = p:gsub("/+$", "")
  return r ~= "" and r or "/"
end

--- Parent of a remote path; "/" is the only root anchor — returns nil there.
--- Paths are absolute in practice: list_remote resolves them via `pwd` before
--- any entry is built, so `..` climbs one real level even above "~".
--- Exported: init.lua uses it to remember the parent of a picked remote file.
function M.remote_parent(path)
  if path == "/" or path == "" then
    return nil
  end
  local parent = path:match("^(.+)/[^/]+$")
  if parent == nil or parent == "" then
    return "/"
  end
  return parent
end

--- `ssh host 'cd <path> && pwd && ls -1F'`, async. The leading `pwd` resolves
--- the path to its absolute form (remote shell expands "~"), which is what
--- makes parent navigation work above the remote home. Suffix info: "/" = dir
--- (descendable), "@/=/|" = symlink/socket/fifo (treated as files, not
--- descendable).
local function list_remote(host, path, cb)
  -- Why: BatchMode=yes on every ssh/scp call — key-auth only by design, so a
  -- dead tunnel fails fast instead of hanging on a password prompt
  -- (README.md "Behavior notes")
  -- TODO: paths containing spaces break here (ssh joins argv with spaces and
  -- the remote shell re-splits them); quote the path when fixing this
  -- Why: shell operators ("&&") as separate argv items is intentional — ssh
  -- joins everything after the host with spaces and the remote shell interprets
  -- the result, so a compound remote command needs no local shell
  -- (README.md "Behavior notes")
  local cmd = { "ssh", "-o", "BatchMode=yes", host, "cd", path, "&&", "pwd", "&&", "ls", "-1F" }
  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        vim.notify(
          "nvim-scp: remote list failed: " .. path .. "\n" .. (res.stderr or ""):gsub("%s*$", ""),
          vim.log.levels.ERROR
        )
        return
      end
      local lines = vim.split(res.stdout or "", "\n")
      -- first line is the `pwd` output: the resolved absolute path
      local resolved = table.remove(lines, 1)
      if not resolved or resolved == "" then
        vim.notify("nvim-scp: remote list failed: " .. path, vim.log.levels.ERROR)
        return
      end
      local dirs, files = {}, {}
      for _, line in ipairs(lines) do
        if line ~= "" then
          if line:sub(-1) == "/" then
            table.insert(dirs, line:sub(1, -2))
          else
            -- parens: drop gsub's second return (count), else insert() reads it as `pos`
            table.insert(files, (line:gsub("[%*=@|]$", "")))
          end
        end
      end
      table.sort(dirs)
      table.sort(files)
      cb(resolved, dirs, files)
    end)
  end)
end

local function list_local(path, cb)
  local ok, dirs, files = pcall(function()
    -- vim.fs.dir (not vim.fs.readdir — that is 0.12+ only)
    -- Why: d/f, not dirs/files — the outer pcall locals are dirs/files, and
    -- selene's "shadowing" lint (CI job in .github/workflows/ci.yml, selene
    -- 0.31.0) exits 1 when inner locals reuse those names; pure rename
    local d, f = {}, {}
    for name, type in vim.fs.dir(path) do
      if type == "directory" then
        table.insert(d, name)
      else
        -- files, symlinks etc. are treated as files per spec
        table.insert(f, name)
      end
    end
    return d, f
  end)
  if not ok then
    vim.notify("nvim-scp: cannot read local dir: " .. path, vim.log.levels.ERROR)
    return
  end
  table.sort(dirs)
  table.sort(files)
  -- pass the path through unchanged (local paths are already absolute)
  cb(path, dirs, files)
end

-- Keep local paths forward-slashed end to end (vim.fs and libuv accept "/" on
-- Windows too), so joins and dirname round-trip consistently.
local function join_local(dir, name)
  return (dir:gsub("\\", "/"):gsub("/+$", "")) .. "/" .. name
end

--- Shared browse loop. opts:
---   start         path to open first
---   include_files list files (upload source / download picker) or dirs only
---   title         picker title prefix; current path is appended
---   list          fun(path, cb(cur, dirs, files)) — `cur` is the path the
---                 picker operates on: the resolved absolute path (remote
---                 lister resolves via `pwd`) or `path` unchanged (local)
---   parent        fun(path) -> path|nil
---   join          fun(dir, name) -> path
---   on_pick       fun(path, is_dir) — a file, or a confirmed dir ("./")
local function browse(mods, opts)
  local function open_at(path)
    opts.list(path, function(cur, dirs, files)
      local entries = {}
      local parent = opts.parent(cur)
      if parent then
        table.insert(entries, { name = "..", is_dir = true })
      end
      table.insert(entries, { name = ".", is_dir = true })
      for _, d in ipairs(dirs) do
        table.insert(entries, { name = d, is_dir = true })
      end
      if opts.include_files then
        for _, f in ipairs(files) do
          table.insert(entries, { name = f })
        end
      end
      open_picker(mods, opts.title .. ": " .. cur, entries, function(e)
        if e.name == ".." then
          open_at(parent)
        elseif e.name == "." then
          opts.on_pick(cur, true)
        elseif e.is_dir then
          open_at(opts.join(cur, e.name))
        else
          opts.on_pick(opts.join(cur, e.name), false)
        end
      end)
    end)
  end
  open_at(opts.start)
end

--- Browse the remote host. `on_pick(remote_path, is_dir)` fires on a file pick
--- (include_files) or "./" dir confirm.
--- When `opts.start` is given (a remembered dir) it is validated first with
--- `ssh test -d`; if it no longer exists we WARN and fall back to remote_base_path.
function M.browse_remote(opts)
  local mods = telescope_modules()
  if not mods then
    return
  end
  local host = config.config.host
  local base = norm_remote(config.config.remote_base_path)

  local function open(start)
    browse(mods, {
      start = start,
      include_files = opts.include_files,
      title = opts.title or "Remote",
      list = function(path, cb)
        list_remote(host, path, cb)
      end,
      parent = M.remote_parent,
      join = transfer.join_remote,
      on_pick = opts.on_pick,
    })
  end

  local start = opts.start and norm_remote(opts.start) or base
  if start == base then
    open(base)
    return
  end
  vim.system({ "ssh", "-o", "BatchMode=yes", host, "test", "-d", start }, { text = true }, function(res)
    vim.schedule(function()
      if res.code == 0 then
        open(start)
      else
        vim.notify("nvim-scp: " .. start .. " not found, starting at " .. base, vim.log.levels.WARN)
        open(base)
      end
    end)
  end)
end

--- Browse local paths starting at `opts.start` (default: cwd).
function M.browse_local(opts)
  local mods = telescope_modules()
  if not mods then
    return
  end
  browse(mods, {
    start = opts.start or vim.fn.getcwd(),
    include_files = opts.include_files,
    title = opts.title or "Local",
    list = list_local,
    parent = function(path)
      local p = vim.fs.dirname(path)
      -- vim.fs.dirname returns "/" (or "C:/") unchanged at a filesystem root;
      -- nil there so ".." disappears instead of re-opening the same root
      if p == path then
        return nil
      end
      return p
    end,
    join = join_local,
    on_pick = opts.on_pick,
  })
end

return M
