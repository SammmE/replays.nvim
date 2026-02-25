-- Example configuration for replays.nvim
-- Copy this to your init.lua or create a separate config file

-- Minimal setup with defaults
require("replays").setup()

-- Full configuration with all options:
--[[
require("replays").setup({
  -- Storage location
  storage_path = vim.fn.expand("~/.local/share/nvim/replays"),
  
  -- Auto-start/stop behavior
  auto_start = false,           -- Auto-start recording when Neovim opens
  auto_stop = false,            -- Auto-stop recording when Neovim exits
  
  -- Keybindings (set to false to disable any binding)
  keybindings = {
    toggle = "<leader>rr",      -- Toggle recording on/off
    start = false,              -- Explicit start (disabled by default)
    stop = false,               -- Explicit stop (disabled by default)
    pause = "<leader>rp",       -- Pause/resume (acts as toggle if resume not set)
    resume = false,             -- Explicit resume (if set, pause won't toggle)
    status = "<leader>rs",      -- Show status
    list = "<leader>rl",        -- List sessions
  },
  
  -- Flush behavior
  flush = {
    size_threshold = 2000,      -- Flush after this many events
    time_threshold = 60000,     -- Flush every 60 seconds
    idle_threshold = 2000,      -- Flush after 2 seconds of inactivity
    idle_check_interval = 500,  -- Check for idle every 500ms
  },
  
  -- Performance settings
  cursor_sample_rate = 200,     -- Sample cursor position every 200ms
  max_event_content_lines = 1000,
  max_event_content_bytes = 51200,
  
  -- Security blacklist (extend defaults)
  blacklist = vim.list_extend(
    require("replays.config").defaults.blacklist,
    {
      "**/my-secrets/**",
      "*.custom-secret",
    }
  ),
  
  -- Enable debug logging
  debug = false,
})
]]--

-- Example 1: Auto-record every session
--[[
require("replays").setup({
  auto_start = true,
  auto_stop = true,
  keybindings = {
    toggle = false,             -- Disable toggle since auto-recording
    pause = "<leader>rp",       -- Still allow pausing
    status = "<leader>rs",
  },
})
]]--

-- Example 2: Minimal keybindings
--[[
require("replays").setup({
  keybindings = {
    toggle = "<leader>r",       -- Just one key to toggle
    pause = false,              -- Disable pause
    status = false,             -- Disable status
    list = false,               -- Disable list
  },
})
]]--

-- Example 3: Explicit control (no auto-start, all commands mapped)
--[[
require("replays").setup({
  auto_start = false,
  keybindings = {
    toggle = false,             -- Disable toggle
    start = "<leader>rr",       -- Explicit start
    stop = "<leader>rq",        -- Explicit stop (q for quit)
    pause = "<leader>rp",       -- Pause
    resume = "<leader>ru",      -- Resume (u for unpause)
    status = "<leader>rs",      -- Status
    list = "<leader>rl",        -- List
  },
})
]]--

-- Example 4: Project-local storage
--[[
require("replays").setup({
  storage_path = vim.fn.getcwd() .. "/.replays",
  -- Remember to add .replays/ to your .gitignore!
})
]]--

-- Example 5: High-frequency recording (for detailed analysis)
--[[
require("replays").setup({
  flush = {
    size_threshold = 1000,      -- Flush more often
    time_threshold = 30000,     -- Every 30 seconds
    idle_threshold = 1000,      -- After 1 second idle
  },
  cursor_sample_rate = 100,     -- Sample cursor more frequently
})
]]--

-- Programmatic API usage examples:
--[[
local replays = require("replays")

-- Start/stop manually
replays.start()
replays.stop("finished_feature")

-- Pause/resume
replays.pause()
replays.resume()

-- Toggle states
replays.toggle()        -- Toggle recording on/off
replays.toggle_pause()  -- Toggle pause/resume

-- Check state
if replays.is_recording() then
  print("Recording...")
end

if replays.is_paused() then
  print("Recording is paused")
end

-- Get detailed status
local status = replays.status()
print(vim.inspect(status))

-- List sessions
local sessions = replays.list_sessions()
for _, session in ipairs(sessions) do
  print(session.filename)
end
]]--
