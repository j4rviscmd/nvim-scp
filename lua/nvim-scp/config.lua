--- Defaults + user config merge.
--- Validated lazily: commands error on first use when `host` is unset (see init.lua).
local M = {
  config = {
    host = nil, -- REQUIRED before use. Host name in ~/.ssh/config
    remote_base_path = "~", -- remote browse start point ("~" is expanded by the remote shell)
  },
}

---@param user_opts table|nil
function M.setup(user_opts)
  M.config = vim.tbl_deep_extend("force", M.config, user_opts or {})
  return M.config
end

return M
