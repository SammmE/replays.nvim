--- replays.nvim - Videogame-style replay recorder for Neovim
--- Records coding sessions with high-efficiency dual-stream capture
local recorder = require("replays.recorder")
local config = require("replays.config")
local flush = require("replays.flush")

local M = {}

--- Setup replays.nvim with user configuration
---@param opts table|nil User configuration options
---   Available options:
---     - storage_path: string - Where to store recordings (default: stdpath('data')/replays)
---     - auto_start: boolean - Auto-start recording on VimEnter (default: false)
---     - auto_stop: boolean - Auto-stop recording on VimLeavePre (default: false)
---     - keybindings: table - Custom keybindings for commands (see config.lua for defaults)
---     - flush.size_threshold: number - Events before forced flush (default: 2000)
---     - flush.time_threshold: number - Milliseconds for periodic flush (default: 60000)
---     - flush.idle_threshold: number - Milliseconds of idle before flush (default: 2000)
---     - cursor_sample_rate: number - Milliseconds between cursor samples (default: 200)
---     - blacklist: table - File patterns to exclude from recording
---     - debug: boolean - Enable debug logging (default: false)
function M.setup(opts)
  opts = opts or {}
  
  -- Initialize configuration
  recorder.setup(opts)
  
  -- Store config for later use
  local cfg = config.options
  
  -- Create user commands
  vim.api.nvim_create_user_command("ReplaysStart", function()
    local success, err = recorder.start_recording()
    if success then
      vim.notify("[replays.nvim] Recording started", vim.log.levels.INFO)
    else
      vim.notify("[replays.nvim] Failed to start: " .. tostring(err), vim.log.levels.ERROR)
    end
  end, {
    desc = "Start recording coding session",
  })
  
  vim.api.nvim_create_user_command("ReplaysStop", function()
    local success, err = recorder.stop_recording("user_command")
    if success then
      vim.notify("[replays.nvim] Recording stopped", vim.log.levels.INFO)
    else
      vim.notify("[replays.nvim] Not recording", vim.log.levels.WARN)
    end
  end, {
    desc = "Stop recording coding session",
  })
  
  vim.api.nvim_create_user_command("ReplaysToggle", function()
    local is_recording = recorder.toggle_recording()
    if is_recording then
      vim.notify("[replays.nvim] Recording started", vim.log.levels.INFO)
    else
      vim.notify("[replays.nvim] Recording stopped", vim.log.levels.INFO)
    end
  end, {
    desc = "Toggle recording on/off",
  })
  
  vim.api.nvim_create_user_command("ReplaysPause", function()
    local success, err = recorder.pause_recording()
    if success then
      vim.notify("[replays.nvim] Recording paused", vim.log.levels.INFO)
    else
      vim.notify("[replays.nvim] " .. tostring(err), vim.log.levels.WARN)
    end
  end, {
    desc = "Pause recording (keeps session active)",
  })
  
  vim.api.nvim_create_user_command("ReplaysResume", function()
    local success, err = recorder.resume_recording()
    if success then
      vim.notify("[replays.nvim] Recording resumed", vim.log.levels.INFO)
    else
      vim.notify("[replays.nvim] " .. tostring(err), vim.log.levels.WARN)
    end
  end, {
    desc = "Resume recording",
  })
  
  vim.api.nvim_create_user_command("ReplaysTogglePause", function()
    local is_paused = recorder.toggle_pause()
    if is_paused then
      vim.notify("[replays.nvim] Recording paused", vim.log.levels.INFO)
    else
      vim.notify("[replays.nvim] Recording resumed", vim.log.levels.INFO)
    end
  end, {
    desc = "Toggle pause/resume",
  })
  
  vim.api.nvim_create_user_command("ReplaysStatus", function()
    local status = recorder.get_status()
    
    if not status.is_recording then
      vim.notify("[replays.nvim] Not recording", vim.log.levels.INFO)
      return
    end
    
    local duration_sec = math.floor((status.duration_ms or 0) / 1000)
    local minutes = math.floor(duration_sec / 60)
    local seconds = duration_sec % 60
    
    local state_str = status.is_paused and "PAUSED" or "ACTIVE"
    
    local message = string.format(
      "[replays.nvim] Recording: %s\n" ..
      "Session ID: %s\n" ..
      "Duration: %dm %ds",
      state_str,
      status.session_id or "N/A",
      minutes, seconds
    )
    
    if status.is_paused and status.total_paused_ms then
      local paused_sec = math.floor(status.total_paused_ms / 1000)
      message = message .. string.format("\nPaused time: %ds", paused_sec)
    end
    
    message = message .. string.format(
      "\nEvents buffered: %d / %d\n" ..
      "Total events: %d\n" ..
      "Tracked buffers: %d\n" ..
      "Memory: %.2f MB",
      status.buffer_stats.size,
      status.buffer_stats.max_size,
      status.buffer_stats.total_events,
      status.tracked_buffers,
      status.buffer_stats.memory_mb
    )
    
    if status.memory_warning then
      message = message .. "\n⚠ " .. status.memory_warning
    end
    
    if status.circuit_status.is_open then
      message = message .. "\n⚠ Circuit breaker OPEN - recording disabled"
    end
    
    vim.notify(message, vim.log.levels.INFO)
  end, {
    desc = "Show recording status",
  })
  
  vim.api.nvim_create_user_command("ReplaysList", function()
    local sessions = flush.list_sessions()
    
    if #sessions == 0 then
      vim.notify("[replays.nvim] No recordings found", vim.log.levels.INFO)
      return
    end
    
    local lines = {"[replays.nvim] Recorded sessions:", ""}
    for i, session in ipairs(sessions) do
      table.insert(lines, string.format("%d. %s", i, session.filename))
      if session.timestamp then
        table.insert(lines, string.format("   Date: %s", session.timestamp))
      end
      table.insert(lines, string.format("   Path: %s", session.filepath))
      table.insert(lines, "")
    end
    
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end, {
    desc = "List all recorded sessions",
  })
  
  vim.api.nvim_create_user_command("ReplaysPath", function()
    local path = config.options.storage_path
    vim.notify("[replays.nvim] Storage path: " .. path, vim.log.levels.INFO)
  end, {
    desc = "Show storage path for recordings",
  })
  
  vim.api.nvim_create_user_command("ReplaysResetCircuit", function()
    flush.reset_circuit()
    vim.notify("[replays.nvim] Circuit breaker reset", vim.log.levels.INFO)
  end, {
    desc = "Manually reset circuit breaker (use if write errors resolved)",
  })
  
  -- Setup keybindings if configured
  local keybindings = cfg.keybindings
  if keybindings then
    if keybindings.toggle then
      vim.keymap.set("n", keybindings.toggle, "<cmd>ReplaysToggle<cr>", {
        desc = "Toggle replay recording",
        silent = true,
      })
    end
    
    if keybindings.start then
      vim.keymap.set("n", keybindings.start, "<cmd>ReplaysStart<cr>", {
        desc = "Start replay recording",
        silent = true,
      })
    end
    
    if keybindings.stop then
      vim.keymap.set("n", keybindings.stop, "<cmd>ReplaysStop<cr>", {
        desc = "Stop replay recording",
        silent = true,
      })
    end
    
    if keybindings.pause then
      -- If resume binding is not set, use pause as toggle
      if not keybindings.resume then
        vim.keymap.set("n", keybindings.pause, "<cmd>ReplaysTogglePause<cr>", {
          desc = "Toggle pause/resume recording",
          silent = true,
        })
      else
        vim.keymap.set("n", keybindings.pause, "<cmd>ReplaysPause<cr>", {
          desc = "Pause recording",
          silent = true,
        })
      end
    end
    
    if keybindings.resume then
      vim.keymap.set("n", keybindings.resume, "<cmd>ReplaysResume<cr>", {
        desc = "Resume recording",
        silent = true,
      })
    end
    
    if keybindings.status then
      vim.keymap.set("n", keybindings.status, "<cmd>ReplaysStatus<cr>", {
        desc = "Show replay status",
        silent = true,
      })
    end
    
    if keybindings.list then
      vim.keymap.set("n", keybindings.list, "<cmd>ReplaysList<cr>", {
        desc = "List recorded sessions",
        silent = true,
      })
    end
  end
  
  -- Setup auto-start on VimEnter
  if cfg.auto_start then
    vim.api.nvim_create_autocmd("VimEnter", {
      group = vim.api.nvim_create_augroup("replays_auto_start", { clear = true }),
      callback = function()
        -- Delay slightly to let other plugins initialize
        vim.defer_fn(function()
          local success, err = recorder.start_recording()
          if success then
            if cfg.debug then
              vim.notify("[replays.nvim] Auto-started recording", vim.log.levels.DEBUG)
            end
          else
            config.error_log("Auto-start failed: " .. tostring(err))
          end
        end, 100)
      end,
    })
  end
  
  -- Setup auto-stop on VimLeavePre
  if cfg.auto_stop then
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = vim.api.nvim_create_augroup("replays_auto_stop", { clear = true }),
      callback = function()
        recorder.stop_recording("auto_stop_vim_exit")
      end,
    })
  end
end

--- Start recording (programmatic API)
---@return boolean success
---@return string|nil error
function M.start()
  return recorder.start_recording()
end

--- Stop recording (programmatic API)
---@param reason string|nil Reason for stopping
---@return boolean success
---@return string|nil error
function M.stop(reason)
  return recorder.stop_recording(reason)
end

--- Toggle recording (programmatic API)
---@return boolean is_recording New state
function M.toggle()
  return recorder.toggle_recording()
end

--- Pause recording (programmatic API)
---@return boolean success
---@return string|nil error
function M.pause()
  return recorder.pause_recording()
end

--- Resume recording (programmatic API)
---@return boolean success
---@return string|nil error
function M.resume()
  return recorder.resume_recording()
end

--- Toggle pause state (programmatic API)
---@return boolean is_paused New state
function M.toggle_pause()
  return recorder.toggle_pause()
end

--- Get recording status (programmatic API)
---@return table status
function M.status()
  return recorder.get_status()
end

--- Check if currently recording
---@return boolean is_recording
function M.is_recording()
  return recorder.get_status().is_recording
end

--- Check if currently paused
---@return boolean is_paused
function M.is_paused()
  return recorder.get_status().is_paused
end

--- Get list of recorded sessions
---@return table sessions
function M.list_sessions()
  return flush.list_sessions()
end

--- Get storage path
---@return string path
function M.get_storage_path()
  return config.options.storage_path
end

return M
