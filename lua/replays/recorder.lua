--- Core recording engine for replays.nvim
--- Manages all event listeners and orchestrates the recording loop
local config = require("replays.config")
local buffer = require("replays.buffer")
local flush = require("replays.flush")

local M = {}

--- Recording state
local state = {
  is_recording = false,
  is_paused = false,          -- Paused state (session active but not capturing)
  session_id = nil,
  start_time = nil,           -- hrtime() at session start
  pause_time = nil,           -- hrtime() when paused
  total_paused_time = 0,      -- Total time spent paused (for accurate duration)
  last_activity = nil,        -- hrtime() of last event
  
  -- Listener handles
  key_listener_id = nil,      -- vim.on_key callback
  attached_buffers = {},      -- {[bufnr] = detach_callback}
  cursor_timer = nil,         -- Timer for throttled cursor sampling
  idle_timer = nil,           -- Timer for idle detection
  periodic_timer = nil,       -- Timer for periodic flush
  
  -- Cursor tracking state
  last_cursor_pos = nil,      -- {row, col, bufnr} from last sample
  
  -- Buffers to track
  tracked_buffers = {},       -- Set of buffer numbers currently tracked
  buf_name_cache = {},        -- Cache: {[bufnr] = "path/to/file"} - avoids API calls on hot path
}

--- Generate a simple UUID (good enough for session IDs)
---@return string uuid
local function generate_uuid()
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return string.gsub(template, "[xy]", function(c)
    local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
    return string.format("%x", v)
  end)
end

--- Get high-resolution timestamp in milliseconds
---@return number timestamp_ms
local function get_timestamp()
  return vim.loop.hrtime() / 1e6 -- Convert nanoseconds to milliseconds
end

--- Update last activity timestamp
local function mark_activity()
  state.last_activity = vim.loop.hrtime()
end

--- Create event with common fields
---@param event_type string "key"|"edit"|"cursor"
---@param bufnr number Buffer handle
---@return table event Partially filled event
local function create_event(event_type, bufnr)
  -- USE CACHE: Ultra fast table lookup instead of API call
  local bufname = state.buf_name_cache[bufnr] or ""
  
  return {
    ts = get_timestamp() - state.start_time, -- Relative time since session start
    type = event_type,
    buf = bufnr,
    buf_name = bufname,
  }
end

--- Flush events to disk
--- Called by: size threshold, time threshold, idle detection, or manual stop
---@param reason string Reason for flush
local function do_flush(reason)
  local events = buffer.drain()
  if #events == 0 then
    config.debug_log("Flush triggered (" .. reason .. ") but buffer empty")
    return
  end
  
  config.debug_log(string.format("Flushing %d events (reason: %s)", #events, reason))
  
  -- Write asynchronously
  flush.write_async(state.session_id, events, function(success, error)
    if not success then
      config.error_log("Flush failed: " .. tostring(error))
      
      -- Circuit breaker check
      local circuit = flush.get_circuit_status()
      if circuit.is_open then
        -- Stop recording to prevent data loss and instability
        M.stop_recording("circuit_breaker_triggered")
        vim.schedule(function()
          vim.notify(
            "[replays.nvim] Recording stopped due to repeated write failures.\n" ..
            "Last error: " .. tostring(circuit.last_error),
            vim.log.levels.ERROR
          )
        end)
      end
    else
      config.debug_log("Flush successful")
    end
  end)
end

--- Check if enough time has passed since last activity (idle detection)
local function check_idle()
  if not state.is_recording then
    return
  end
  
  local now = vim.loop.hrtime()
  local idle_threshold_ns = config.options.flush.idle_threshold * 1e6
  
  if state.last_activity and (now - state.last_activity) >= idle_threshold_ns then
    -- User is idle, this is a good time to flush
    if buffer.get_size() > 0 then
      do_flush("idle_detected")
    end
  end
end

--- Periodic flush (time-based threshold)
local function periodic_flush()
  if not state.is_recording then
    return
  end
  
  if buffer.get_size() > 0 then
    do_flush("periodic_timer")
  end
end

--- Key press handler (vim.on_key callback)
---@param key string Raw key pressed
---@param typed string Typed representation
local function on_key(key, typed)
  if not state.is_recording or state.is_paused then
    return
  end
  
  mark_activity()
  
  -- Get current mode and buffer
  local mode = vim.api.nvim_get_mode().mode
  local bufnr = vim.api.nvim_get_current_buf()
  
  -- Check if buffer should be recorded
  local should_record, reason = config.should_record_buffer(bufnr)
  if not should_record then
    config.debug_log("Skipping key event in buffer " .. bufnr .. ": " .. reason)
    return
  end
  
  -- Create key event
  local event = create_event("key", bufnr)
  event.key = key
  event.mode = mode
  
  -- Add buffer metadata for labeling
  local metadata = config.get_buffer_metadata(bufnr)
  event.buf_metadata = metadata
  
  -- Push to buffer (scheduled to avoid blocking vim.on_key)
  vim.schedule(function()
    local should_flush = buffer.push(event)
    if should_flush then
      do_flush("size_threshold")
    end
  end)
end

--- Buffer change handler (nvim_buf_attach callback)
---@param bufnr number Buffer handle
---@return function on_lines Callback for buffer changes
local function create_buf_attach_callback(bufnr)
  return function(_, buf, changedtick, firstline, lastline, new_lastline, byte_count)
    if not state.is_recording then
      return true -- Detach if not recording
    end
    
    -- Skip if paused
    if state.is_paused then
      return false -- Keep attached but don't record
    end
    
    mark_activity()
    
    -- Create edit event
    local event = create_event("edit", bufnr)
    
    -- Get the changed text
    local old_line_count = lastline - firstline
    local new_line_count = new_lastline - firstline
    
    -- Get new text (if not a pure deletion)
    local new_text = {}
    if new_line_count > 0 then
      local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, firstline, new_lastline, false)
      if ok then
        new_text = lines
      end
    end
    
    -- We can't get old text (it's already changed), so mark it as unknown
    -- For replay, we'll reconstruct from the sequence of edits
    local old_text = old_line_count > 0 and {"[old_content_unavailable]"} or {}
    
    event.edit = {
      start_row = firstline,
      start_col = 0, -- nvim_buf_attach doesn't give us column info
      end_row = lastline,
      end_col = 0,
      old_line_count = old_line_count,
      new_line_count = new_line_count,
      old_text = old_text,
      new_text = new_text,
      byte_count = byte_count,
      changedtick = changedtick,
    }
    
    -- Add buffer metadata
    local metadata = config.get_buffer_metadata(bufnr)
    event.buf_metadata = metadata
    
    -- Push to buffer (scheduled)
    vim.schedule(function()
      local should_flush = buffer.push(event)
      if should_flush then
        do_flush("size_threshold")
      end
    end)
    
    return false -- Keep attached
  end
end

--- Attach buffer change listener to a buffer
---@param bufnr number Buffer handle
local function attach_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  
  -- Check if should record
  local should_record, reason = config.should_record_buffer(bufnr)
  if not should_record then
    config.debug_log("Not attaching to buffer " .. bufnr .. ": " .. reason)
    return
  end
  
  -- Already attached?
  if state.attached_buffers[bufnr] then
    return
  end
  
  -- POPULATE CACHE: Cache buffer name on attach to avoid repeated API calls
  state.buf_name_cache[bufnr] = vim.api.nvim_buf_get_name(bufnr)
  
  -- Attach to buffer
  local ok, detach = pcall(vim.api.nvim_buf_attach, bufnr, false, {
    on_lines = create_buf_attach_callback(bufnr),
    on_detach = function()
      state.attached_buffers[bufnr] = nil
      state.tracked_buffers[bufnr] = nil
      state.buf_name_cache[bufnr] = nil -- CLEAR CACHE
    end,
  })
  
  if ok then
    state.attached_buffers[bufnr] = detach
    state.tracked_buffers[bufnr] = true
    config.debug_log("Attached to buffer " .. bufnr)
  else
    config.error_log("Failed to attach to buffer " .. bufnr .. ": " .. tostring(detach))
  end
end

--- Throttled cursor movement handler
local function sample_cursor_position()
  if not state.is_recording or state.is_paused then
    return
  end
  
  local bufnr = vim.api.nvim_get_current_buf()
  
  -- Check if buffer should be recorded
  local should_record = config.should_record_buffer(bufnr)
  if not should_record then
    return
  end
  
  -- Get cursor position
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, 0)
  if not ok then
    return
  end
  
  local row, col = cursor[1], cursor[2]
  
  -- Check if position changed
  if state.last_cursor_pos and
     state.last_cursor_pos.row == row and
     state.last_cursor_pos.col == col and
     state.last_cursor_pos.bufnr == bufnr then
    return -- No change
  end
  
  -- Update last position
  state.last_cursor_pos = {row = row, col = col, bufnr = bufnr}
  
  -- Create cursor event
  local event = create_event("cursor", bufnr)
  event.cursor = {row = row, col = col}
  
  -- Add buffer metadata
  local metadata = config.get_buffer_metadata(bufnr)
  event.buf_metadata = metadata
  
  -- Push to buffer
  local should_flush = buffer.push(event)
  if should_flush then
    do_flush("size_threshold")
  end
end

--- Attach to all current buffers
local function attach_all_buffers()
  local buffers = vim.api.nvim_list_bufs()
  for _, bufnr in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      attach_buffer(bufnr)
    end
  end
end

--- Setup recorder with configuration
---@param opts table Configuration options
function M.setup(opts)
  config.setup(opts)
  buffer.setup(config.options)
end

--- Start recording session
---@return boolean success
---@return string|nil error
function M.start_recording()
  if state.is_recording then
    return false, "already_recording"
  end
  
  config.debug_log("Starting recording session")
  
  -- Initialize session
  state.session_id = generate_uuid()
  state.start_time = get_timestamp()
  state.last_activity = vim.loop.hrtime()
  state.is_recording = true
  state.last_cursor_pos = nil
  
  -- Write session metadata
  local metadata = {
    session_id = state.session_id,
    start_time = os.time(),
    start_time_iso = os.date("%Y-%m-%dT%H:%M:%S"),
    nvim_version = vim.version(),
    cwd = vim.fn.getcwd(),
    hostname = vim.loop.os_gethostname(),
  }
  
  flush.write_metadata(state.session_id, metadata, function(success, err)
    if not success then
      config.error_log("Failed to write session metadata: " .. tostring(err))
    end
  end)
  
  -- Attach vim.on_key listener
  vim.on_key(on_key, vim.api.nvim_create_namespace("replays_key_listener"))
  
  -- Attach to all current buffers
  attach_all_buffers()
  
  -- Set up BufEnter autocmd to attach to new buffers
  vim.api.nvim_create_autocmd("BufEnter", {
    group = vim.api.nvim_create_augroup("replays_buf_attach", {clear = true}),
    callback = function(args)
      if state.is_recording then
        attach_buffer(args.buf)
      end
    end,
  })
  
  -- Set up BufFilePost autocmd to update cache when files are renamed
  vim.api.nvim_create_autocmd("BufFilePost", {
    group = vim.api.nvim_create_augroup("replays_buf_rename", {clear = true}),
    callback = function(args)
      if state.is_recording and state.buf_name_cache[args.buf] then
        state.buf_name_cache[args.buf] = vim.api.nvim_buf_get_name(args.buf)
        config.debug_log("Updated buffer name cache for buffer " .. args.buf)
      end
    end,
  })
  
  -- Start cursor sampling timer (throttled)
  state.cursor_timer = vim.loop.new_timer()
  state.cursor_timer:start(
    config.options.cursor_sample_rate,
    config.options.cursor_sample_rate,
    vim.schedule_wrap(sample_cursor_position)
  )
  
  -- Start idle detection timer
  state.idle_timer = vim.loop.new_timer()
  state.idle_timer:start(
    config.options.flush.idle_check_interval,
    config.options.flush.idle_check_interval,
    vim.schedule_wrap(check_idle)
  )
  
  -- Start periodic flush timer
  state.periodic_timer = vim.loop.new_timer()
  state.periodic_timer:start(
    config.options.flush.time_threshold,
    config.options.flush.time_threshold,
    vim.schedule_wrap(periodic_flush)
  )
  
  config.debug_log("Recording session started: " .. state.session_id)
  
  return true, nil
end

--- Stop recording session
---@param reason string|nil Reason for stopping
---@return boolean success
---@return string|nil error
function M.stop_recording(reason)
  if not state.is_recording then
    return false, "not_recording"
  end
  
  reason = reason or "user_requested"
  config.debug_log("Stopping recording session: " .. reason)
  
  -- Stop timers
  if state.cursor_timer then
    state.cursor_timer:stop()
    state.cursor_timer:close()
    state.cursor_timer = nil
  end
  
  if state.idle_timer then
    state.idle_timer:stop()
    state.idle_timer:close()
    state.idle_timer = nil
  end
  
  if state.periodic_timer then
    state.periodic_timer:stop()
    state.periodic_timer:close()
    state.periodic_timer = nil
  end
  
  -- Remove vim.on_key listener
  vim.on_key(nil, vim.api.nvim_create_namespace("replays_key_listener"))
  
  -- Detach from all buffers
  for bufnr, detach in pairs(state.attached_buffers) do
    if type(detach) == "function" then
      pcall(detach)
    end
  end
  state.attached_buffers = {}
  state.tracked_buffers = {}
  
  -- Clear autocmds
  pcall(vim.api.nvim_del_augroup_by_name, "replays_buf_attach")
  pcall(vim.api.nvim_del_augroup_by_name, "replays_buf_rename")
  
  -- Final flush
  do_flush("session_end")
  
  -- Write session end metadata
  local end_metadata = {
    session_id = state.session_id,
    end_time = os.time(),
    end_time_iso = os.date("%Y-%m-%dT%H:%M:%S"),
    duration_ms = get_timestamp() - state.start_time,
    stop_reason = reason,
    total_events = buffer.get_stats().total_events,
  }
  
  flush.write_metadata(state.session_id .. "_end", end_metadata, function() end)
  
  -- Reset state
  state.is_recording = false
  state.is_paused = false
  state.session_id = nil
  state.start_time = nil
  state.pause_time = nil
  state.total_paused_time = 0
  state.last_activity = nil
  state.last_cursor_pos = nil
  state.buf_name_cache = {} -- Clear cache
  
  config.debug_log("Recording session stopped")
  
  return true, nil
end

--- Pause recording (keeps session active but stops capturing)
---@return boolean success
---@return string|nil error
function M.pause_recording()
  if not state.is_recording then
    return false, "not_recording"
  end
  
  if state.is_paused then
    return false, "already_paused"
  end
  
  config.debug_log("Pausing recording session")
  
  state.is_paused = true
  state.pause_time = vim.loop.hrtime()
  
  -- Flush current buffer before pausing
  if buffer.get_size() > 0 then
    do_flush("pause")
  end
  
  -- Write pause event marker
  local pause_event = {
    ts = get_timestamp() - state.start_time,
    type = "pause",
    reason = "user_pause",
  }
  buffer.push(pause_event)
  do_flush("pause_marker")
  
  return true, nil
end

--- Resume recording
---@return boolean success
---@return string|nil error
function M.resume_recording()
  if not state.is_recording then
    return false, "not_recording"
  end
  
  if not state.is_paused then
    return false, "not_paused"
  end
  
  config.debug_log("Resuming recording session")
  
  -- Calculate paused duration
  local pause_duration = vim.loop.hrtime() - state.pause_time
  state.total_paused_time = state.total_paused_time + pause_duration
  
  state.is_paused = false
  state.pause_time = nil
  
  -- Write resume event marker
  local resume_event = {
    ts = get_timestamp() - state.start_time,
    type = "resume",
    pause_duration_ms = pause_duration / 1e6,
  }
  buffer.push(resume_event)
  
  return true, nil
end

--- Toggle pause state
---@return boolean is_paused New state (true = now paused, false = now recording)
function M.toggle_pause()
  if not state.is_recording then
    return false
  end
  
  if state.is_paused then
    M.resume_recording()
    return false
  else
    M.pause_recording()
    return true
  end
end

--- Get recording status
---@return table status {is_recording, is_paused, session_id, duration_ms, buffer_stats, circuit_status}
function M.get_status()
  -- Calculate actual recording time (excluding paused time)
  local duration_ms = nil
  if state.is_recording then
    local total_time = get_timestamp() - state.start_time
    local paused_time = state.total_paused_time / 1e6
    if state.is_paused and state.pause_time then
      -- Add current pause duration
      paused_time = paused_time + ((vim.loop.hrtime() - state.pause_time) / 1e6)
    end
    duration_ms = total_time - paused_time
  end
  
  local status = {
    is_recording = state.is_recording,
    is_paused = state.is_paused,
    session_id = state.session_id,
    duration_ms = duration_ms,
    total_paused_ms = state.is_recording and (state.total_paused_time / 1e6) or nil,
    buffer_stats = buffer.get_stats(),
    circuit_status = flush.get_circuit_status(),
    tracked_buffers = vim.tbl_count(state.tracked_buffers),
  }
  
  -- Add memory health check
  local is_high, warning = buffer.check_memory_health()
  status.memory_warning = is_high and warning or nil
  
  return status
end

--- Toggle recording (start if stopped, stop if started)
---@return boolean new_state
function M.toggle_recording()
  if state.is_recording then
    M.stop_recording("user_toggle")
    return false
  else
    M.start_recording()
    return true
  end
end

return M
