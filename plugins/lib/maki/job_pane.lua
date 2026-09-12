-- Live read-only output pane for a command job, opened over whatever float
-- is showing (the /tasks picker, usually). Streams via jobattach; Esc closes
-- and detaches. Any picker can reuse it: `JobPane.open(job)` with a joblist
-- row.

local OUT_TAG = "out "
local ERR_TAG = "err "
local EXIT_FMT = "exited (code %d)"
local DROPPED_NOTE = "… older output dropped"
local TICK_MS = 100
-- Once the buffer passes MAX_LINES, a redraw trims it back to KEEP_LINES, so
-- chatty jobs pay one set_lines per burst instead of one per line.
local MAX_LINES = 1000
local KEEP_LINES = 500
local CLOSE_KEYS = { esc = true, ["<C-c>"] = true }

local JobPane = {}

JobPane.MAX_LINES = MAX_LINES
JobPane.KEEP_LINES = KEEP_LINES

local pane = nil

-- One output line as spans: the stream tag carries the style, the text stays
-- plain. Theme roles only.
function JobPane.stream_line(kind, text)
  if kind == "stderr" then
    return { { ERR_TAG, "error" }, { text, "item" } }
  end
  return { { OUT_TAG, "dim" }, { text, "item" } }
end

function JobPane.exit_line(code)
  return { { EXIT_FMT:format(code), code == 0 and "success" or "error" } }
end

-- The pane's starting content: the dropped note, then the tails, then the
-- exit line for a job that already finished.
function JobPane.initial_lines(info)
  local lines = {}
  if info.dropped_output then
    lines[#lines + 1] = { { DROPPED_NOTE, "dim" } }
  end
  for _, text in ipairs(info.stdout_lines or {}) do
    lines[#lines + 1] = JobPane.stream_line("stdout", text)
  end
  for _, text in ipairs(info.stderr_lines or {}) do
    lines[#lines + 1] = JobPane.stream_line("stderr", text)
  end
  if info.exit_code then
    lines[#lines + 1] = JobPane.exit_line(info.exit_code)
  end
  return lines
end

-- Last KEEP_LINES of {lines} once it outgrows MAX_LINES, else nil (nothing to
-- do).
function JobPane.capped(lines)
  if #lines <= MAX_LINES then
    return nil
  end
  local kept = {}
  for i = #lines - KEEP_LINES + 1, #lines do
    kept[#kept + 1] = lines[i]
  end
  return kept
end

local function append(kind, text)
  local this = pane
  if not this then
    return
  end
  local line = JobPane.stream_line(kind, text)
  this.lines[#this.lines + 1] = line
  local capped = JobPane.capped(this.lines)
  if capped then
    this.lines = capped
    this.buf:set_lines(capped)
  else
    this.buf:line(line)
  end
  this.win:set_cursor(this.buf:len())
end

local function append_exit(code)
  local this = pane
  if not this then
    return
  end
  local line = JobPane.exit_line(code)
  this.lines[#this.lines + 1] = line
  this.buf:line(line)
  this.win:set_cursor(this.buf:len())
end

-- Only exit. If the job is still running, clearing the callbacks detaches us;
-- the owner plugin re-adopts its streams on its next reload, and until then
-- the tails keep recording.
local function finish()
  local this = pane
  if not this then
    return
  end
  pane = nil
  if not this.exited then
    maki.fn.jobattach(this.job.id, {
      session = this.job.session,
      on_stdout = false,
      on_stderr = false,
      on_exit = false,
    })
  end
  if this.win:is_open() then
    this.win:close()
  end
end

-- Opens over the current float and takes focus; the float manager hands focus
-- back to the picker underneath when the pane closes, so the picker keeps its
-- loop and selection.
function JobPane.open(job)
  if pane then
    return
  end
  local opts = { session = job.session }
  local info, err = maki.fn.jobinfo(job.id, opts)
  if err then
    maki.ui.flash(err)
    return
  end

  local lines = JobPane.initial_lines(info)

  local buf = maki.ui.buf({ scratch = true })
  buf:set_lines(lines)
  local win = maki.ui.open_win(buf, {
    title = " " .. (job.name or job.command) .. " ",
    width = "70%",
    height = "70%",
    border = "rounded",
    footer = { { "Esc", "close" } },
  })
  win:set_cursor(buf:len())

  local this = {
    job = job,
    buf = buf,
    win = win,
    lines = lines,
    exited = info.exit_code ~= nil,
  }
  pane = this

  -- A job that exits between jobinfo and attach replays its exit here, so the
  -- pane never waits on a line that already happened.
  local _, attach_err = maki.fn.jobattach(job.id, {
    session = job.session,
    on_stdout = function(_, line)
      append("stdout", line)
    end,
    on_stderr = function(_, line)
      append("stderr", line)
    end,
    on_exit = function(_, code)
      this.exited = true
      append_exit(code)
    end,
  })
  if attach_err then
    pane = nil
    maki.ui.flash(attach_err)
    win:close()
    return
  end

  while pane == this do
    local ev = win:recv(TICK_MS)
    if not ev or ev.type == "close" then
      finish()
    elseif ev.type == "key" and CLOSE_KEYS[ev.key] then
      finish()
    end
  end
end

return JobPane
