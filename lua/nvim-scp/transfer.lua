--- scp execution, path building, overwrite check, notifications.
--- All transfers run async via vim.system; args are lists so no shell quoting is needed.
local config = require("nvim-scp.config")

local M = {}

--- Last non-empty lines of a command output, for failure notifications.
-- Note: scp's actionable errors ("lost connection", "No such file") land at the
-- END of stderr — hence tail lines, not head
local function last_lines(s, n)
  local lines = vim.split(s or "", "\n")
  local out = {}
  for i = math.max(1, #lines - n + 1), #lines do
    local l = lines[i]:gsub("%s+$", "")
    if l ~= "" then
      table.insert(out, l)
    end
  end
  return table.concat(out, "\n")
end

--- Local path in scp-friendly form: Windows OpenSSH accepts "C:/..." with forward slashes.
local function to_scp_local(path)
  if vim.fn.has("win32") == 1 then
    return (path:gsub("\\", "/"))
  end
  return path
end

--- Join a remote dir and a name. "~" stays the root anchor ("~/foo", never "~//foo").
--- Exported: browser.lua uses it to build child paths while descending.
function M.join_remote(dir, name)
  dir = dir:gsub("/+$", "")
  if dir == "" or dir == "/" then
    return "/" .. name
  end
  return dir .. "/" .. name
end

--- Run scp asynchronously. `desc` is shown in start/success notifications.
--- `on_done(ok)` fires after the transfer settles (called from a main-loop callback).
--- `diagnose` runs only on failure: it receives `report(cause?)` and may call
--- it (from any callback depth) with a human-readable cause line to show above
--- the raw stderr tail.
local function run_scp(args, desc, on_done, diagnose)
  vim.notify("nvim-scp: " .. desc, vim.log.levels.INFO)
  vim.system(args, { text = true }, function(res)
    vim.schedule(function()
      if res.code == 0 then
        vim.notify("nvim-scp: done (" .. desc .. ")", vim.log.levels.INFO)
        if on_done then
          on_done(true)
        end
        return
      end
      local function report(cause)
        local msg = "nvim-scp: failed (" .. desc .. ")"
        if cause then
          msg = msg .. "\ncause: " .. cause
        end
        msg = msg .. "\n" .. last_lines(res.stderr, 5)
        vim.notify(msg, vim.log.levels.ERROR)
        if on_done then
          on_done(false)
        end
      end
      diagnose(report)
    end)
  end)
end

-- Caution: when the existing target is a directory, scp -r merges/overwrites
-- into it (it never deletes the dir first); the pre-check detects the name
-- only, so one confirm covers the whole dir
local function ask_overwrite(prompt, then_run)
  vim.ui.select({ "Overwrite", "Cancel" }, { prompt = prompt }, function(choice)
    if choice == "Overwrite" then
      then_run()
    else
      vim.notify("nvim-scp: cancelled", vim.log.levels.INFO)
    end
  end)
end

--- Check remote existence asynchronously.
--- `then_run(exists)` on success, nil after a connection error (already reported).
local function remote_exists(host, remote_path, then_run)
  -- Why: BatchMode=yes on every ssh/scp call — key-auth only by design, so a
  -- dead tunnel fails fast instead of hanging on a password prompt
  -- (README.md "Behavior notes")
  vim.system({ "ssh", "-o", "BatchMode=yes", host, "test", "-e", remote_path }, { text = true }, function(res)
    vim.schedule(function()
      if res.code == 0 then
        then_run(true)
      elseif res.code == 1 then
        then_run(false)
      else
        -- 255 etc: ssh itself failed (tunnel down, unknown host). Don't treat as "missing".
        vim.notify("nvim-scp: ssh check failed\n" .. last_lines(res.stderr, 3), vim.log.levels.ERROR)
      end
    end)
  end)
end

--- Upload `local_path` (file or dir) into `remote_dir`.
--- `on_done(ok)` fires only after a transfer attempt; it is NOT called when the
--- overwrite check is cancelled or fails (those paths notify on their own).
function M.push(local_path, remote_dir, on_done)
  local host = config.config.host
  local name = vim.fs.basename(to_scp_local(local_path))
  local desc = "uploading " .. name .. " -> " .. host .. ":" .. remote_dir

  local function start()
    -- Note: -r is passed even for single files — harmless for a plain file, so
    -- one code path serves both file and dir transfers
    local args = {
      "scp",
      "-o",
      "BatchMode=yes",
      "-r",
      to_scp_local(local_path),
      host .. ":" .. remote_dir,
    }
    -- Why: SFTP-mode scp (OpenSSH >= 9 default) reports a permission failure
    -- on the remote dir as the misleading "stat remote: No such file or
    -- directory"; `test -w` after failure recovers the real cause
    local function diagnose(report)
      vim.system({ "ssh", "-o", "BatchMode=yes", host, "test", "-w", remote_dir }, { text = true }, function(res)
        vim.schedule(function()
          if res.code == 1 then
            report("no write access to " .. host .. ":" .. remote_dir)
          else
            -- 0 = writable (failure is something else), 255 = ssh itself broken
            report()
          end
        end)
      end)
    end
    run_scp(args, desc, on_done, diagnose)
  end

  local target = M.join_remote(remote_dir, name)
  remote_exists(host, target, function(exists)
    if exists then
      ask_overwrite("nvim-scp: overwrite " .. host .. ":" .. target .. "?", start)
    else
      start()
    end
  end)
end

--- Download `remote_path` (file or dir) into `local_dir`.
--- Same on_done contract as push().
function M.pull(remote_path, local_dir, on_done)
  local host = config.config.host
  local name = vim.fs.basename(remote_path)
  local desc = "downloading " .. host .. ":" .. remote_path .. " -> " .. local_dir

  local function start()
    local args = {
      "scp",
      "-o",
      "BatchMode=yes",
      "-r",
      host .. ":" .. remote_path,
      to_scp_local(local_dir),
    }
    -- Local twin of push()'s diagnose: libuv access check, synchronous
    local function diagnose(report)
      if vim.uv.fs_access(to_scp_local(local_dir), "W") == false then
        report("no write access to local " .. local_dir)
      else
        report()
      end
    end
    run_scp(args, desc, on_done, diagnose)
  end

  local target = to_scp_local(local_dir):gsub("/+$", "") .. "/" .. name
  -- vim.uv.fs_stat, not vim.fs.stat (0.12+ only)
  local stat = vim.uv.fs_stat(target)
  if stat then
    ask_overwrite("nvim-scp: overwrite local " .. target .. "?", start)
  else
    start()
  end
end

return M
