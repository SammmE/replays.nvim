--- Configuration management for replays.nvim
--- Handles user options, defaults, and validation
local M = {}

--- Default configuration
M.defaults = {
  -- Storage settings
  storage_path = nil, -- Will be set to stdpath('data')/replays if nil

  -- Auto-start recording behavior
  auto_start = true, -- Auto-start recording when Neovim starts
  auto_stop = true,  -- Auto-stop recording when Neovim exits

  -- Keybindings (set to false to disable, or provide custom binding string)
  keybindings = {
    toggle = "<leader>rr", -- Toggle recording on/off
    start = false,         -- Start recording (false = no binding)
    stop = false,          -- Stop recording (false = no binding)
    pause = "<leader>rp",  -- Pause recording (keeps session, stops capturing)
    resume = false,        -- Resume recording (false = use pause to toggle)
    status = "<leader>rs", -- Show recording status
    list = "<leader>rl",   -- List recorded sessions
  },

  -- Flush strategy thresholds
  flush = {
    size_threshold = 2000,     -- Events before forced flush
    time_threshold = 60000,    -- Milliseconds (60s) for periodic flush
    idle_threshold = 2000,     -- Milliseconds (2s) of inactivity triggers flush
    idle_check_interval = 500, -- How often to check for idle state (ms)
  },

  -- Performance settings
  cursor_sample_rate = 200,        -- Milliseconds between cursor position samples
  max_event_content_lines = 1000,  -- Truncate edit events larger than this
  max_event_content_bytes = 51200, -- 50KB - truncate if exceeded

  -- Safety: Sensitive file patterns (glob-style)
  blacklist = {
    -- Filenames
    "*.env",
    "*.secret",
    "*.key",
    "*.pem",
    "*.p12",
    "*.pfx",
    "*_rsa",
    "*_dsa",
    "*_ed25519",
    "*_ecdsa",

    -- Paths
    "**/.env",
    "**/.env.*",
    "**/secrets/**",
    "**/.git/**",
    "**/node_modules/**", -- Don't record massive deps

    -- Password managers
    "**/KeePass*.kdbx",
    "**/1Password/**",
    "**/Bitwarden/**",
  },

  -- Buffer types to ignore
  blacklist_buftypes = {
    "prompt",
    "nofile",
    -- NOTE: terminal, floating, quickfix are labeled but NOT ignored
    -- per user requirement to "label them but don't count for efficiency"
  },

  -- Memory safety
  max_memory_mb = 50, -- Warn if replay buffer exceeds this

  -- Logging
  debug = false,
}

--- Current active configuration
M.options = vim.deepcopy(M.defaults)

--- Setup configuration with user options
---@param user_opts table|nil User configuration overrides
function M.setup(user_opts)
  user_opts = user_opts or {}

  -- Deep merge user options with defaults
  M.options = vim.tbl_deep_extend("force", M.defaults, user_opts)

  -- Resolve storage path
  if not M.options.storage_path then
    M.options.storage_path = vim.fn.stdpath("data") .. "/replays"
  end

  -- Ensure storage directory exists
  vim.fn.mkdir(M.options.storage_path, "p")

  -- Validate thresholds
  assert(M.options.flush.size_threshold > 0, "flush.size_threshold must be positive")
  assert(M.options.flush.time_threshold > 0, "flush.time_threshold must be positive")
  assert(M.options.flush.idle_threshold > 0, "flush.idle_threshold must be positive")

  return M.options
end

--- Check if a buffer should be recorded based on blacklist
---@param bufnr number Buffer handle
---@return boolean should_record
---@return string|nil reason Reason for exclusion if false
function M.should_record_buffer(bufnr)
  -- Check buffer validity
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false, "invalid_buffer"
  end

  -- Check buftype blacklist
  local buftype = vim.api.nvim_buf_get_option(bufnr, "buftype")
  if vim.tbl_contains(M.options.blacklist_buftypes, buftype) then
    return false, "blacklisted_buftype:" .. buftype
  end

  -- Check filename against blacklist patterns
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  if bufname == "" then
    return true -- Unnamed buffers are OK
  end

  for _, pattern in ipairs(M.options.blacklist) do
    -- Convert glob pattern to Lua pattern (basic conversion)
    local lua_pattern = pattern
        :gsub("%*%*", ".-")  -- ** → match any path
        :gsub("%*", "[^/]*") -- * → match filename chars
        :gsub("%.", "%%.")   -- . → literal dot

    if bufname:match(lua_pattern) then
      return false, "blacklisted_pattern:" .. pattern
    end
  end

  return true
end

--- Get buffer metadata for labeling (doesn't exclude, just tags)
---@param bufnr number Buffer handle
---@return table metadata {buftype, filetype, is_floating, etc}
function M.get_buffer_metadata(bufnr)
  local ok, buftype = pcall(vim.api.nvim_buf_get_option, bufnr, "buftype")
  local ok2, filetype = pcall(vim.api.nvim_buf_get_option, bufnr, "filetype")

  return {
    buftype = ok and buftype or "unknown",
    filetype = ok2 and filetype or "unknown",
    is_floating = #vim.api.nvim_list_wins() > 0 and
        vim.api.nvim_win_get_config(0).relative ~= "",
  }
end

--- Log debug message if debug mode enabled
---@param msg string Message to log
function M.debug_log(msg)
  if M.options.debug then
    vim.schedule(function()
      vim.notify("[replays.nvim] " .. msg, vim.log.levels.DEBUG)
    end)
  end
end

--- Log error message
---@param msg string Error message
function M.error_log(msg)
  vim.schedule(function()
    vim.notify("[replays.nvim] ERROR: " .. msg, vim.log.levels.ERROR)
  end)
end

return M
