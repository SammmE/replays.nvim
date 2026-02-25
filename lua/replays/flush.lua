--- Async file writer for session events
--- Uses libuv for non-blocking I/O with circuit breaker pattern
local config = require("replays.config")

local M = {}

--- Circuit breaker state
local circuit_breaker = {
  is_open = false,      -- If true, all writes fail fast
  failure_count = 0,    -- Consecutive failures
  last_error = nil,     -- Last error message
  max_failures = 3,     -- Open circuit after this many failures
}

--- Generate filename for session
---@param session_id string UUID for session
---@return string filepath Full path to session file
local function get_session_filepath(session_id)
  local timestamp = os.date("%Y-%m-%d_%H-%M-%S")
  local filename = string.format("%s_%s.jsonl", timestamp, session_id)
  return config.options.storage_path .. "/" .. filename
end

--- Serialize event to JSON line
---@param event table Event to serialize
---@return string json_line JSON string with newline
local function serialize_event(event)
  -- Use vim.json.encode for safe serialization
  local ok, json = pcall(vim.json.encode, event)
  if not ok then
    config.error_log("Failed to serialize event: " .. tostring(json))
    -- Return a placeholder error event
    return vim.json.encode({
      ts = event.ts or 0,
      type = "error",
      error = "serialization_failed",
      original_type = event.type,
    }) .. "\n"
  end
  return json .. "\n"
end

--- Write events to file asynchronously
---@param session_id string Session UUID
---@param events table Array of events to write
---@param callback function(success: boolean, error: string|nil) Completion callback
function M.write_async(session_id, events, callback)
  -- Check circuit breaker
  if circuit_breaker.is_open then
    config.debug_log("Circuit breaker open, skipping write")
    callback(false, "circuit_breaker_open:" .. (circuit_breaker.last_error or "unknown"))
    return
  end
  
  if #events == 0 then
    callback(true, nil)
    return
  end
  
  local filepath = get_session_filepath(session_id)
  
  -- Serialize all events to JSONL
  local lines = {}
  for _, event in ipairs(events) do
    table.insert(lines, serialize_event(event))
  end
  local content = table.concat(lines, "")
  
  config.debug_log(string.format("Writing %d events (%d bytes) to %s", 
    #events, #content, filepath))
  
  -- Open file for appending (create if doesn't exist)
  local uv = vim.loop
  uv.fs_open(filepath, "a", 438, function(err_open, fd) -- 438 = 0666 in octal
    if err_open or not fd then
      local error_msg = "fs_open failed: " .. tostring(err_open)
      config.error_log(error_msg)
      
      -- Update circuit breaker
      circuit_breaker.failure_count = circuit_breaker.failure_count + 1
      circuit_breaker.last_error = error_msg
      if circuit_breaker.failure_count >= circuit_breaker.max_failures then
        circuit_breaker.is_open = true
        config.error_log("Circuit breaker opened after " .. circuit_breaker.failure_count .. " failures")
      end
      
      -- Try sync fallback
      vim.schedule(function()
        callback(false, error_msg)
      end)
      return
    end
    
    -- Write content
    uv.fs_write(fd, content, -1, function(err_write, bytes_written)
      if err_write then
        local error_msg = "fs_write failed: " .. tostring(err_write)
        config.error_log(error_msg)
        
        -- Update circuit breaker
        circuit_breaker.failure_count = circuit_breaker.failure_count + 1
        circuit_breaker.last_error = error_msg
        if circuit_breaker.failure_count >= circuit_breaker.max_failures then
          circuit_breaker.is_open = true
          config.error_log("Circuit breaker opened after " .. circuit_breaker.failure_count .. " failures")
        end
        
        -- Close file and callback
        uv.fs_close(fd, function()
          vim.schedule(function()
            callback(false, error_msg)
          end)
        end)
        return
      end
      
      -- Success - close file
      uv.fs_close(fd, function(err_close)
        if err_close then
          config.error_log("fs_close warning: " .. tostring(err_close))
        end
        
        -- Reset circuit breaker on success
        circuit_breaker.failure_count = 0
        circuit_breaker.last_error = nil
        
        config.debug_log(string.format("Successfully wrote %d bytes", bytes_written or 0))
        
        vim.schedule(function()
          callback(true, nil)
        end)
      end)
    end)
  end)
end

--- Synchronous fallback write (blocking, use only in emergencies)
---@param session_id string Session UUID
---@param events table Array of events to write
---@return boolean success
---@return string|nil error
function M.write_sync(session_id, events)
  if #events == 0 then
    return true, nil
  end
  
  local filepath = get_session_filepath(session_id)
  
  -- Serialize events
  local lines = {}
  for _, event in ipairs(events) do
    table.insert(lines, serialize_event(event))
  end
  local content = table.concat(lines, "")
  
  -- Open and write synchronously
  local file, err = io.open(filepath, "a")
  if not file then
    return false, "io.open failed: " .. tostring(err)
  end
  
  local ok, write_err = pcall(file.write, file, content)
  file:close()
  
  if not ok then
    return false, "io.write failed: " .. tostring(write_err)
  end
  
  return true, nil
end

--- Get circuit breaker status
---@return table status {is_open, failure_count, last_error}
function M.get_circuit_status()
  return vim.deepcopy(circuit_breaker)
end

--- Manually reset circuit breaker (use with caution)
function M.reset_circuit()
  circuit_breaker.is_open = false
  circuit_breaker.failure_count = 0
  circuit_breaker.last_error = nil
  config.debug_log("Circuit breaker manually reset")
end

--- Write session metadata file (called once at session start)
---@param session_id string Session UUID
---@param metadata table Session metadata
---@param callback function(success: boolean, error: string|nil)
function M.write_metadata(session_id, metadata, callback)
  local filepath = get_session_filepath(session_id):gsub("%.jsonl$", ".meta.json")
  local content = vim.json.encode(metadata)
  
  local uv = vim.loop
  uv.fs_open(filepath, "w", 438, function(err_open, fd)
    if err_open or not fd then
      config.error_log("Failed to write metadata: " .. tostring(err_open))
      vim.schedule(function() callback(false, err_open) end)
      return
    end
    
    uv.fs_write(fd, content, -1, function(err_write)
      uv.fs_close(fd, function()
        if err_write then
          config.error_log("Failed to write metadata content: " .. tostring(err_write))
          vim.schedule(function() callback(false, err_write) end)
        else
          vim.schedule(function() callback(true, nil) end)
        end
      end)
    end)
  end)
end

--- List all session files in storage directory
---@return table sessions Array of {filepath, filename, timestamp}
function M.list_sessions()
  local sessions = {}
  local storage_path = config.options.storage_path
  
  -- Use scandir to list files
  local uv = vim.loop
  local handle = uv.fs_scandir(storage_path)
  if not handle then
    return sessions
  end
  
  while true do
    local name, type = uv.fs_scandir_next(handle)
    if not name then break end
    
    if type == "file" and name:match("%.jsonl$") then
      table.insert(sessions, {
        filepath = storage_path .. "/" .. name,
        filename = name,
        -- Extract timestamp from filename (YYYY-MM-DD_HH-MM-SS_uuid.jsonl)
        timestamp = name:match("^(%d%d%d%d%-%d%d%-%d%d_%d%d%-%d%d%-%d%d)"),
      })
    end
  end
  
  -- Sort by timestamp descending (newest first)
  table.sort(sessions, function(a, b)
    return (a.timestamp or "") > (b.timestamp or "")
  end)
  
  return sessions
end

return M
