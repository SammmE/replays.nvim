--- Plugin loader for replays.nvim
--- This file is automatically loaded by Neovim when the plugin is installed

-- Prevent loading the plugin twice
if vim.g.loaded_replays then
  return
end
vim.g.loaded_replays = true

-- Plugin is loaded, but setup() must be called by user in their config
-- This follows modern Neovim plugin conventions

-- Optional: Provide a helpful message if user tries to use commands before setup
local function not_setup_error()
  vim.notify(
    "[replays.nvim] Plugin not configured. Call require('replays').setup() in your config.",
    vim.log.levels.ERROR
  )
end

-- Create placeholder commands that show helpful error if setup() not called
local temp_commands = {
  "ReplaysStart",
  "ReplaysStop",
  "ReplaysToggle",
  "ReplaysStatus",
  "ReplaysList",
  "ReplaysPath",
  "ReplaysResetCircuit",
}

for _, cmd in ipairs(temp_commands) do
  vim.api.nvim_create_user_command(cmd, not_setup_error, {
    desc = "Replays.nvim command (requires setup)",
  })
end
