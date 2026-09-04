--- Telescope pickers for browsing remote (ssh cd/pwd/ls) and local (vim.fs) paths.
--- One shared picker builder; the lister and path helpers are injected per mode.
--- Selection model: `<CR>` on a dir descends, on "./" confirms the current dir,
--- on a file picks it (only when files are listed). `<Esc>` cancels.
--- Path jump: a pasted path (multi-char chunk landing at once) jumps
--- immediately; a hand-typed path jumps on `<CR>`. Targets are absolute,
--- "~"-anchored, or relative to the current dir, and path intent always wins
--- over entry selection (the n-gram sorter can still match rows for such a
--- prompt). A file target opens its parent with the file preselected; the
--- user's next `<CR>` confirms it. Jump moves, it never picks.
local config = require("nvim-scp.config")
local transfer = require("nvim-scp.transfer")
local fidget = require("fidget")

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
    fidget.notify("nvim-scp: telescope.nvim is required", vim.log.levels.ERROR)
    return nil
  end
  return mods
end

---@param title string
---@param entries table[] {name: string, is_dir?: boolean} in display order
---@param on_select fun(entry: table)
---@param on_jump fun(input: string) path-jump handler (pasted path, or typed path + `<CR>`)
---@param preselect string|nil entry name to highlight initially
local function open_picker(mods, title, entries, on_select, on_jump, preselect)
  -- Why a separator char: entry names never contain one, so a separator in
  -- the prompt is never a name filter the user could complete with `<CR>`.
  -- Path intent wins over entry selection unconditionally: the n-gram sorter
  -- (get_generic_fuzzy_sorter) still surfaces rows for such prompts — a full
  -- path's filename tail overlaps the entry's n-grams — and letting that
  -- selection fire would pick a file instead of jumping
  -- (README.md "Browsing")
  local function is_path_input(line)
    -- "./" is the confirm-the-current-dir gesture: filter the prompt down to
    -- the "./" row and hit `<CR>`. Jumping on it would resolve to the current
    -- dir and reopen it in an endless loop (README.md "Browsing")
    if line == "./" then
      return false
    end
    if line:find("/", 1, true) then
      return true
    end
    return vim.fn.has("win32") == 1 and line:find("\\", 1, true) ~= nil
  end
  -- A paste lands as one multi-char change; keystrokes (and IME commits,
  -- which stay under typical word length) land in small chunks. 8 chars in
  -- one change = pasted path -> jump immediately, no `<CR>` needed
  local PASTE_MIN = 8
  local prompt_buf
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
        prompt_buf = prompt_bufnr
        local last_len = 0
        vim.api.nvim_create_autocmd("TextChangedI", {
          buffer = prompt_bufnr,
          callback = function()
            local line = mods.action_state.get_current_line()
            local delta = #line - last_len
            last_len = #line
            if delta >= PASTE_MIN and is_path_input(line) then
              -- Mirror the `<CR>` path: close this picker first, then defer
              -- the reopen one tick (same close-path caveat as select_default)
              mods.actions.close(prompt_bufnr)
              vim.schedule(function()
                on_jump(line)
              end)
            end
          end,
        })
        mods.actions.select_default:replace(function()
          local entry = mods.action_state.get_selected_entry()
          local line = mods.action_state.get_current_line()
          mods.actions.close(prompt_bufnr)
          -- Reopening a picker inside the close path misbehaves; defer one tick.
          vim.schedule(function()
            if is_path_input(line) then
              on_jump(line)
            elseif entry then
              on_select(entry.value)
            end
          end)
        end)
        return true
      end,
    })
    :find()
  -- Highlight `preselect` by scanning the rendered results buffer. Why not
  -- default_selection_index: it maps a results index through get_row(), which
  -- with the default descending strategy and the (much larger) scroll limit
  -- computes out-of-window rows and the highlight silently lands nowhere
  if preselect and prompt_buf then
    vim.defer_fn(function()
      local ok, picker = pcall(mods.action_state.get_current_picker, prompt_buf)
      if not ok or not picker then
        return
      end
      local lines = vim.api.nvim_buf_get_lines(picker.results_bufnr, 0, -1, false)
      for row, l in ipairs(lines) do
        -- Exact match after stripping the caret/entry prefix: a substring
        -- match would highlight "ab.txt" when preselecting "b.txt"
        if (l:gsub("^[%s>]+", "")) == preselect then
          picker:set_selection(row - 1)
          break
        end
      end
    end, 100)
  end
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

--- Resolve a typed remote path: "/" or "~"-anchored input is absolute,
--- anything else joins onto `cur`. ".."/"." segments pass through raw — the
--- remote shell resolves them in `cd`/`test` (only the title shows them
--- unnormalized).
local function resolve_remote(input, cur)
  local head = input:sub(1, 1)
  if head == "/" or head == "~" then
    return norm_remote(input)
  end
  return norm_remote(transfer.join_remote(cur, input))
end

--- Classify a remote path async: `cb("dir"|"file"|"missing")`, or `cb(nil)`
--- after an ssh failure (already notified). test -d first — dirs, the common
--- jump target, pay one round trip; only non-dirs pay the second test -e.
local function check_remote(host, path, cb)
  vim.system({ "ssh", "-o", "BatchMode=yes", host, "test", "-d", path }, { text = true }, function(res)
    vim.schedule(function()
      if res.code == 0 then
        cb("dir")
        return
      end
      if res.code ~= 1 then
        -- 255 etc: ssh itself failed (tunnel down, unknown host). Don't treat as "missing".
        fidget.notify("nvim-scp: ssh check failed\n" .. path, vim.log.levels.ERROR)
        cb(nil)
        return
      end
      vim.system({ "ssh", "-o", "BatchMode=yes", host, "test", "-e", path }, { text = true }, function(res2)
        vim.schedule(function()
          if res2.code == 0 then
            cb("file")
          elseif res2.code == 1 then
            cb("missing")
          else
            fidget.notify("nvim-scp: ssh check failed\n" .. path, vim.log.levels.ERROR)
            cb(nil)
          end
        end)
      end)
    end)
  end)
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
        fidget.notify(
          "nvim-scp: remote list failed: " .. path .. "\n" .. (res.stderr or ""):gsub("%s*$", ""),
          vim.log.levels.ERROR
        )
        return
      end
      local lines = vim.split(res.stdout or "", "\n")
      -- first line is the `pwd` output: the resolved absolute path
      local resolved = table.remove(lines, 1)
      if not resolved or resolved == "" then
        fidget.notify("nvim-scp: remote list failed: " .. path, vim.log.levels.ERROR)
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
    fidget.notify("nvim-scp: cannot read local dir: " .. path, vim.log.levels.ERROR)
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

--- Resolve a typed local path. Windows input may arrive backslashed
--- ("C:\Users\...") — normalize first per the project's win32 convention.
local function resolve_local(input, cur)
  local p = input
  if vim.fn.has("win32") == 1 then
    p = p:gsub("\\", "/")
  end
  if p:sub(1, 1) == "~" then
    p = vim.fn.expand(p)
    if vim.fn.has("win32") == 1 then
      p = p:gsub("\\", "/")
    end
  end
  if p:sub(1, 1) == "/" or p:match("^[A-Za-z]:/") then
    local r = p:gsub("/+$", "")
    -- "C:/" must keep its slash: bare "C:" is drive-relative, not the root
    if r:match("^[A-Za-z]:$") then
      return r .. "/"
    end
    return r
  end
  return (join_local(cur, p):gsub("/+$", ""))
end

--- Classify a local path: "dir" | "file" | "missing". fs_stat follows
--- symlinks, same as the overwrite pre-check in transfer.lua.
local function check_local(path, cb)
  local stat = vim.uv.fs_stat(path)
  if stat and stat.type == "directory" then
    cb("dir")
  elseif stat then
    cb("file")
  else
    cb("missing")
  end
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
---   resolve       fun(input, cur) -> path (typed-path resolution for jumps)
---   check         fun(path, cb("dir"|"file"|"missing"|nil))
---   on_pick       fun(path, is_dir) — a file, or a confirmed dir ("./")
local function browse(mods, opts)
  -- open_at and jump call each other; forward-declare to bind the upvalue
  local jump
  local function open_at(path, preselect)
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
      end, function(input)
        -- `cur`, not `path`: relative jumps and error recovery base on the
        -- resolved absolute path, not the (possibly "~"-anchored) request
        jump(input, cur)
      end, preselect)
    end)
  end

  --- Path jump: move only, never pick. A dir target opens directly; a file
  --- target opens its parent with the file preselected so the user's next
  --- `<CR>` confirms it through the normal selection flow.
  jump = function(input, cur)
    local target = opts.resolve(input, cur)
    opts.check(target, function(kind)
      if kind == "dir" then
        open_at(target)
        return
      end
      if kind == "file" and opts.include_files then
        open_at(opts.parent(target), vim.fs.basename(target))
        return
      end
      -- missing / file in a dirs-only picker / ssh failure (nil, already
      -- notified) — recover at the dir we jumped from
      if kind == "file" then
        fidget.notify("nvim-scp: not a directory: " .. target, vim.log.levels.ERROR)
      elseif kind == "missing" then
        fidget.notify("nvim-scp: no such path: " .. target, vim.log.levels.ERROR)
      end
      open_at(cur)
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
      resolve = resolve_remote,
      check = function(path, cb)
        check_remote(host, path, cb)
      end,
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
        fidget.notify("nvim-scp: " .. start .. " not found, starting at " .. base, vim.log.levels.WARN)
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
    resolve = resolve_local,
    check = check_local,
    on_pick = opts.on_pick,
  })
end

return M
