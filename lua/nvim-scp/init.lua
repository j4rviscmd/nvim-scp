--- nvim-scp: upload/download files and dirs between Neovim and a remote host
--- over plain scp (key auth). Telescope-driven, fully async.
---
--- Commands:
---   :ScpUpload         pick a local file/dir, pick a remote dir, push
---   :ScpUploadCurrent  pick a remote dir, push the current buffer's file
---   :ScpDownload       pick a remote file/dir, pick a local dir, pull
local config = require("nvim-scp.config")
local browser = require("nvim-scp.browser")
local transfer = require("nvim-scp.transfer")
local fidget = require("fidget")

local M = {}

--- Last-used remote dir (session scope only). Every remote picker starts here;
--- a picked file remembers its parent dir. browse_remote falls back to
--- remote_base_path when this dir no longer exists. Stored as an absolute
--- path — the remote lister resolves it via `pwd` (remote_base_path may be "~").
M._last_remote_dir = nil

--- Last-used local download dir (session scope only). Starts the download
--- destination picker. The upload source picker intentionally stays at cwd
--- (source files vary per invocation).
-- Note: both last-dir vars are in-memory by design; cross-session persistence
-- is a roadmap item (README.md "Post-MVP"), not an oversight.
M._last_local_dir = nil

---@param user_opts table { host: string, remote_base_path: string }
function M.setup(user_opts)
  config.setup(user_opts)
end

-- Lazy validation: setup() without a host is allowed, commands error on first use.
local function require_host()
  if not config.config.host then
    fidget.notify("nvim-scp: setup({ host = ... }) is required", vim.log.levels.ERROR)
    return nil
  end
  return config.config.host
end

local function push(local_path, remote_dir)
  M._last_remote_dir = remote_dir
  transfer.push(local_path, remote_dir)
end

function M.upload()
  if not require_host() then
    return
  end
  browser.browse_local({
    include_files = true,
    title = "Upload source",
    on_pick = function(local_path)
      browser.browse_remote({
        start = M._last_remote_dir,
        include_files = false,
        title = "Upload to",
        on_pick = function(remote_dir)
          push(local_path, remote_dir)
        end,
      })
    end,
  })
end

function M.upload_current()
  if not require_host() then
    return
  end
  local path = vim.fn.expand("%:p")
  if path == "" then
    fidget.notify("nvim-scp: current buffer has no file", vim.log.levels.ERROR)
    return
  end
  -- Why: refuse instead of auto-:write — the plugin never saves the user's
  -- buffer behind their back
  if vim.bo.modified then
    fidget.notify("nvim-scp: buffer has unsaved changes, :write first", vim.log.levels.ERROR)
    return
  end
  browser.browse_remote({
    start = M._last_remote_dir,
    include_files = false,
    title = "Upload to",
    on_pick = function(remote_dir)
      push(path, remote_dir)
    end,
  })
end

function M.download()
  if not require_host() then
    return
  end
  browser.browse_remote({
    start = M._last_remote_dir,
    include_files = true,
    title = "Download",
    on_pick = function(remote_path, is_dir)
      -- Remember where the pick happened: the dir itself, or the file's parent
      M._last_remote_dir = is_dir and remote_path or browser.remote_parent(remote_path)
      browser.browse_local({
        start = M._last_local_dir or vim.fn.getcwd(),
        include_files = false,
        title = "Download to",
        on_pick = function(local_dir)
          M._last_local_dir = local_dir
          transfer.pull(remote_path, local_dir)
        end,
      })
    end,
  })
end

vim.api.nvim_create_user_command("ScpUpload", M.upload, { desc = "nvim-scp: upload file/dir to remote" })
vim.api.nvim_create_user_command("ScpUploadCurrent", M.upload_current, { desc = "nvim-scp: upload current file" })
vim.api.nvim_create_user_command("ScpDownload", M.download, { desc = "nvim-scp: download file/dir from remote" })

return M
