# replays.nvim

**Videogame-style replay recorder for Neovim** - Record your coding sessions to generate efficiency scores (APM, keybind usage) and visual replays.

## Features

- **Zero-Latency Recording**: Fully asynchronous capture that doesn't interfere with your workflow
- **Dual-Stream Capture**: Records both raw keystrokes (for APM analysis) and text changes (for visual replay)
- **Smart Hybrid Flushing**: Combines size-based, time-based, and idle-detection triggers for optimal performance
- **Memory Safe**: Ring buffer with automatic content truncation prevents OOM errors
- **Circuit Breaker**: Automatically stops recording if disk writes fail repeatedly
- **Multi-Buffer Support**: Tracks all buffers simultaneously with proper labeling
- **Security-First**: Auto-excludes sensitive files (.env, keys, password managers)

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "sammme/replays.nvim",
  config = function()
    require("replays").setup({
      -- Optional: customize settings
      -- storage_path = vim.fn.expand("~/.local/share/nvim/replays"),
      -- debug = false,
    })
  end
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "sammme/replays.nvim",
  config = function()
    require("replays").setup()
  end
}
```

### Using [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'sammme/replays.nvim'

" In your init.lua or init.vim:
lua require("replays").setup()
```

## Quick Start

### Basic Usage

```lua
-- In your Neovim config (init.lua)
require("replays").setup()

-- Optionally map keys for quick access
vim.keymap.set("n", "<leader>rr", "<cmd>ReplaysToggle<cr>", { desc = "Toggle replay recording" })
vim.keymap.set("n", "<leader>rs", "<cmd>ReplaysStatus<cr>", { desc = "Show replay status" })
```

### User Commands

| Command | Description |
|---------|-------------|
| `:ReplaysStart` | Start recording current session |
| `:ReplaysStop` | Stop recording |
| `:ReplaysToggle` | Toggle recording on/off |
| `:ReplaysPause` | Pause recording (keeps session active) |
| `:ReplaysResume` | Resume recording |
| `:ReplaysTogglePause` | Toggle pause/resume |
| `:ReplaysStatus` | Show current recording status |
| `:ReplaysList` | List all recorded sessions |
| `:ReplaysPath` | Show where recordings are stored |
| `:ReplaysResetCircuit` | Reset circuit breaker after resolving write errors |

### Programmatic API

```lua
local replays = require("replays")

-- Start/stop recording
local success, err = replays.start()
replays.stop("my_reason")

-- Toggle recording
local is_recording = replays.toggle()

-- Pause/resume
replays.pause()
replays.resume()
replays.toggle_pause()  -- Toggle pause state

-- Check state
if replays.is_recording() then
  print("Recording...")
end

if replays.is_paused() then
  print("Paused")
end

-- Get detailed status
local status = replays.status()
print(status.is_recording)
print(status.is_paused)
print(status.buffer_stats.total_events)

-- List sessions
local sessions = replays.list_sessions()
for _, session in ipairs(sessions) do
  print(session.filename)
end
```

## Configuration

### Default Configuration

```lua
require("replays").setup({
  -- Storage location (default: stdpath('data')/replays)
  storage_path = nil,
  
  -- Auto-start/stop behavior
  auto_start = false,           -- Auto-start recording when Neovim opens
  auto_stop = false,            -- Auto-stop recording when Neovim exits
  
  -- Keybindings (set to false to disable any binding)
  keybindings = {
    toggle = "<leader>rr",      -- Toggle recording on/off
    start = false,              -- Explicit start (disabled by default)
    stop = false,               -- Explicit stop (disabled by default)
    pause = "<leader>rp",       -- Pause/resume (toggle if resume not set)
    resume = false,             -- Explicit resume (disabled by default)
    status = "<leader>rs",      -- Show status
    list = "<leader>rl",        -- List sessions
  },
  
  -- Flush strategy thresholds
  flush = {
    size_threshold = 2000,      -- Events before forced flush
    time_threshold = 60000,     -- Milliseconds (60s) for periodic flush
    idle_threshold = 2000,      -- Milliseconds (2s) of inactivity triggers flush
    idle_check_interval = 500,  -- How often to check for idle state (ms)
  },
  
  -- Performance settings
  cursor_sample_rate = 200,           -- Milliseconds between cursor samples
  max_event_content_lines = 1000,     -- Truncate edits larger than this
  max_event_content_bytes = 51200,    -- 50KB - truncate if exceeded
  
  -- Safety: Sensitive file patterns (glob-style)
  blacklist = {
    "*.env",
    "*.secret",
    "*.key",
    "*.pem",
    "**/secrets/**",
    "**/KeePass*.kdbx",
    -- ... see config.lua for full list
  },
  
  -- Buffer types to ignore
  blacklist_buftypes = {
    "prompt",
    "nofile",
  },
  
  -- Memory safety
  max_memory_mb = 50,
  
  -- Enable debug logging
  debug = false,
})
```

### Custom Configuration Examples

#### Auto-record every session

```lua
require("replays").setup({
  auto_start = true,            -- Start recording automatically
  auto_stop = true,             -- Stop when exiting Neovim
  keybindings = {
    pause = "<leader>rp",       -- Allow pausing during session
    status = "<leader>rs",      -- Check status
  },
})
```

#### Explicit control with separate start/stop

```lua
require("replays").setup({
  keybindings = {
    toggle = false,             -- Disable toggle
    start = "<leader>rr",       -- Explicit start
    stop = "<leader>rq",        -- Explicit stop
    pause = "<leader>rp",       -- Pause
    resume = "<leader>ru",      -- Resume (separate from pause)
  },
})
```

#### Minimal setup with just toggle

```lua
require("replays").setup({
  keybindings = {
    toggle = "<leader>r",       -- Just one key
    pause = false,              -- Disable other bindings
    status = false,
    list = false,
  },
})
```

#### Project-local storage

```lua
require("replays").setup({
  storage_path = vim.fn.getcwd() .. "/.replays",
  -- Remember to add .replays/ to your .gitignore!
})
```

#### Aggressive flushing for detailed analysis

```lua
require("replays").setup({
  -- Store recordings in project directory
  storage_path = vim.fn.getcwd() .. "/.replays",
  
  -- More aggressive flushing for long sessions
  flush = {
    size_threshold = 1000,    -- Flush more often
    time_threshold = 30000,   -- Every 30s instead of 60s
  },
  
  -- Add custom sensitive patterns
  blacklist = vim.list_extend(
    require("replays.config").defaults.blacklist,
    {
      "**/my-secrets/**",
      "*.custom-secret",
    }
  ),
  
  -- Enable debug mode
  debug = true,
})
```

## Recording Format

Sessions are stored as **JSON Lines (JSONL)** files in the format:

```
~/.local/share/nvim/replays/
  ├── 2026-02-24_14-30-45_abc123-uuid.jsonl          # Event stream
  ├── 2026-02-24_14-30-45_abc123-uuid.meta.json      # Session metadata
  └── ...
```

### Event Schema

Each line in the `.jsonl` file is a JSON event:

```json
{
  "ts": 1234.567,                    // Timestamp (ms since session start)
  "type": "key",                     // "key" | "edit" | "cursor"
  "buf": 1,                          // Buffer handle
  "buf_name": "/path/to/file.lua",   // File path
  "buf_metadata": {                  // Buffer classification
    "buftype": "normal",
    "filetype": "lua",
    "is_floating": false
  },
  "key": "j",                        // For type="key"
  "mode": "n"                        // For type="key"
}
```

**Edit events:**
```json
{
  "ts": 1235.890,
  "type": "edit",
  "buf": 1,
  "buf_name": "/path/to/file.lua",
  "edit": {
    "start_row": 10,
    "start_col": 0,
    "end_row": 12,
    "end_col": 0,
    "new_text": ["line1", "line2"],
    "old_line_count": 2,
    "new_line_count": 2
  }
}
```

**Cursor events:**
```json
{
  "ts": 1236.123,
  "type": "cursor",
  "buf": 1,
  "buf_name": "/path/to/file.lua",
  "cursor": {
    "row": 15,
    "col": 8
  }
}
```

## Architecture

```
lua/replays/
├── init.lua        - Public API and user commands
├── config.lua      - Configuration management
├── recorder.lua    - Core recording engine (vim.on_key, nvim_buf_attach)
├── buffer.lua      - Ring buffer with content guards
└── flush.lua       - Async JSONL writer with circuit breaker
```

### Key Design Decisions

1. **Smart Hybrid Flushing**: Three triggers ensure data is saved efficiently:
   - **Size threshold** (2000 events): Prevents memory bloat
   - **Time threshold** (60s): Ensures periodic persistence
   - **Idle trigger** (2s): Flushes during "free" time when user is thinking

2. **Massive Paste Guard**: Truncates events >1000 lines or >50KB to prevent editor freezing

3. **Circuit Breaker**: After 3 consecutive flush failures, stops recording to prevent data loss and instability

4. **Per-Instance Sessions**: One Neovim instance = One session (the "Match" concept)

## Performance

- **Memory overhead**: ~500 bytes per event (2000 events ≈ 1MB)
- **CPU overhead**: Negligible (<1% on modern systems)
- **Disk I/O**: Fully asynchronous using libuv
- **Input lag**: Zero (all recording is scheduled/async)

## Use Cases

### 1. **Efficiency Analysis** (Future Phase)
Generate "post-game" reports showing:
- Actions Per Minute (APM)
- Most used keybinds
- Time spent in each file/buffer
- Inefficient patterns (key spamming, excessive undo/redo)

### 2. **Visual Replay** (Future Phase)
Reconstruct your coding session as a video-style replay:
- Watch your code being written in real-time or sped up
- Share with teammates for code reviews
- Create tutorials from actual coding sessions

### 3. **Debugging Workflow Issues**
Analyze what you were doing before a crash or bug appeared

### 4. **Time Tracking**
Accurate tracking of time spent coding vs. reading/thinking

## Troubleshooting

### Recording not starting

Check if setup was called:
```lua
:lua print(vim.inspect(require("replays").status()))
```

### High memory usage

```
:ReplaysStatus  -- Check buffer stats
```

If memory is high, you may need to:
- Reduce `flush.size_threshold`
- Increase `flush.time_threshold` for more frequent flushes
- Check for large paste operations

### Write failures

```
:ReplaysStatus  -- Check circuit breaker status
```

If circuit breaker is open:
1. Check disk space: `df -h`
2. Check permissions on storage path
3. Reset circuit: `:ReplaysResetCircuit`
4. Restart recording: `:ReplaysStart`

### Sensitive files being recorded

Add patterns to blacklist:
```lua
require("replays").setup({
  blacklist = vim.list_extend(
    require("replays.config").defaults.blacklist,
    { "**/your-pattern/**" }
  )
})
```

## Roadmap

- [x] **Phase 1**: High-Efficiency Recorder Module
- [ ] **Phase 2**: Post-Game Analyst (APM, efficiency scores)
- [ ] **Phase 3**: Visual Replay Generator
- [ ] **Phase 4**: Web-based replay viewer
- [ ] **Phase 5**: Team collaboration features

## Contributing

Contributions welcome! This plugin is in active development.

## License

MIT License - see LICENSE file

## Acknowledgments

Built with Neovim's powerful Lua API and libuv async I/O.
