--- Event buffer with ring buffer semantics and content guards
--- Prevents memory bloat from massive pastes and unbounded growth
local config = require("replays.config")

local M = {}

--- Buffer state
local state = {
  events = {},      -- Ring buffer storage
  head = 1,         -- Write position
  size = 0,         -- Current number of events
  max_size = 2000,  -- From config (will be set in setup)
  total_events = 0, -- Lifetime counter for stats
}

--- Initialize buffer with config
---@param opts table Configuration options
function M.setup(opts)
  state.max_size = opts.flush.size_threshold
  M.clear()
end

--- Sanitize and truncate event content if too large
--- This is the "Massive Paste Guard"
---@param event table Event to sanitize
---@return table sanitized_event
local function sanitize_event(event)
  if event.type ~= "edit" or not event.edit then
    return event
  end

  local edit = event.edit
  local max_lines = config.options.max_event_content_lines
  local max_bytes = config.options.max_event_content_bytes

  -- Check line count
  local new_text_lines = #(edit.new_text or {})
  local old_text_lines = #(edit.old_text or {})

  -- Calculate approximate byte size
  local new_text_bytes = 0
  if edit.new_text then
    for _, line in ipairs(edit.new_text) do
      new_text_bytes = new_text_bytes + #line
    end
  end

  local old_text_bytes = 0
  if edit.old_text then
    for _, line in ipairs(edit.old_text) do
      old_text_bytes = old_text_bytes + #line
    end
  end

  local needs_truncation = false
  local truncation_reason = nil

  -- Check if truncation needed
  if new_text_lines > max_lines then
    needs_truncation = true
    truncation_reason = string.format("new_text exceeds %d lines (%d)", max_lines, new_text_lines)
  elseif old_text_lines > max_lines then
    needs_truncation = true
    truncation_reason = string.format("old_text exceeds %d lines (%d)", max_lines, old_text_lines)
  elseif new_text_bytes > max_bytes then
    needs_truncation = true
    truncation_reason = string.format("new_text exceeds %d bytes (%d)", max_bytes, new_text_bytes)
  elseif old_text_bytes > max_bytes then
    needs_truncation = true
    truncation_reason = string.format("old_text exceeds %d bytes (%d)", max_bytes, old_text_bytes)
  end

  if needs_truncation then
    config.debug_log("Truncating large edit event: " .. truncation_reason)

    -- Create truncated event
    local truncated = vim.deepcopy(event)
    truncated.edit = {
      start_row = edit.start_row,
      start_col = edit.start_col,
      end_row = edit.end_row,
      end_col = edit.end_col,
      old_text = { "[CONTENT_TOO_LARGE]" },
      new_text = { "[CONTENT_TOO_LARGE]" },
      truncated = true,
      truncation_reason = truncation_reason,
      original_line_count = {
        old = old_text_lines,
        new = new_text_lines,
      },
      original_byte_count = {
        old = old_text_bytes,
        new = new_text_bytes,
      },
    }
    return truncated
  end

  return event
end

--- Push event to buffer
--- Returns true if flush should be triggered (size threshold reached)
---@param event table Event to push
---@return boolean should_flush
function M.push(event)
  -- Sanitize event content
  event = sanitize_event(event)

  -- Add to ring buffer
  state.events[state.head] = event
  state.head = (state.head % state.max_size) + 1

  -- Update size (cap at max_size)
  if state.size < state.max_size then
    state.size = state.size + 1
  end

  state.total_events = state.total_events + 1

  -- Check if flush needed
  return state.size >= state.max_size
end

--- Check if buffer is full
---@return boolean is_full
function M.is_full()
  return state.size >= state.max_size
end

--- Get current buffer size
---@return number size
function M.get_size()
  return state.size
end

--- Drain all events from buffer and clear it
--- Returns events in chronological order
---@return table events
function M.drain()
  if state.size == 0 then
    return {}
  end

  local events = {}

  -- If buffer wrapped, we need to read from tail to head
  if state.size >= state.max_size then
    -- Buffer is full, tail is at head position
    local tail = state.head
    for i = 0, state.size - 1 do
      local idx = ((tail + i - 1) % state.max_size) + 1
      table.insert(events, state.events[idx])
    end
  else
    -- Buffer not full, events are at start
    for i = 1, state.size do
      table.insert(events, state.events[i])
    end
  end

  -- Clear buffer
  M.clear()

  return events
end

--- Clear buffer without draining
function M.clear()
  state.events = {}
  state.head = 1
  state.size = 0
end

--- Get buffer statistics
---@return table stats {size, max_size, total_events, memory_kb}
function M.get_stats()
  -- Estimate memory usage (rough approximation)
  local memory_bytes = 0
  for i = 1, state.size do
    -- Rough estimate: 500 bytes per event on average
    -- (actual size varies by event type)
    memory_bytes = memory_bytes + 500
  end

  return {
    size = state.size,
    max_size = state.max_size,
    total_events = state.total_events,
    memory_kb = memory_bytes / 1024,
    memory_mb = memory_bytes / 1024 / 1024,
  }
end

--- Check if buffer memory usage is concerning
---@return boolean is_high
---@return string|nil warning_message
function M.check_memory_health()
  local stats = M.get_stats()
  local max_mb = config.options.max_memory_mb

  if stats.memory_mb > max_mb then
    return true, string.format(
      "Replay buffer using %.2f MB (limit: %d MB). Consider flushing.",
      stats.memory_mb,
      max_mb
    )
  end

  return false, nil
end

return M
