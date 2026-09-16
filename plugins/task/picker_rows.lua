-- Row building for the /tasks picker in picker.lua: filtering, ordering and
-- sections, with no host calls and no globals. Every refresh throws the old
-- rows away and builds them again, so nothing here can drift from the host
-- list.

local ListPicker = require("maki.list_picker")

local RUN_ICON = "· "
local OK_ICON = "✓ "
local BAD_ICON = "✗ "

local RUNNING_SECTION = "Running"
local JOBS_SECTION = "Jobs"
local FINISHED_SECTION = "Finished"
local JOB_INDENT = "  "

local M = {}

-- An idle plugin task is waiting for its next prompt, not finished.
local function alive(status)
  return status == "working" or status == "idle"
end

-- Both hosts hand their lists over in chat order, which is spawn order.
local function newest_first(list)
  local flipped = {}
  for i = #list, 1, -1 do
    flipped[#flipped + 1] = list[i]
  end
  return flipped
end

-- The main chat comes first and has no status. The subagents follow, live
-- ones above finished ones so a long job never gets buried under the ones
-- that already returned. Each subagent's jobs render right under it, so a job
-- a subagent spawned stays visually attached to its spawner; the main chat's
-- jobs share the flat Jobs section. Within a section, newest first (`tasks`
-- and `jobs` both arrive in chat order, which is spawn order), so the row at
-- hand is the latest one.
--
-- Returns { rows, sections }. A row carries a section header only when it opens
-- one, and `sections` counts what survived the filter.
function M.build(tasks, jobs, query)
  local words = ListPicker.split_words(query)
  local main, running, finished = nil, {}, {}
  local task_by_id = {}
  for _, task in ipairs(tasks) do
    task_by_id[task.id] = task
    if ListPicker.matches(task.name, words) then
      if not task.status then
        main = task
      elseif alive(task.status) then
        running[#running + 1] = task
      else
        finished[#finished + 1] = task
      end
    end
  end

  -- A job matches on its own text or on its spawner's name, so filtering by
  -- the subagent keeps its jobs visible.
  local main_live, main_exited = {}, {}
  local sub_live, sub_exited = {}, {}
  local orphan_ids = {}
  for _, job in ipairs(jobs or {}) do
    local spawner = job.spawned_by and task_by_id[job.spawned_by]
    local matches = ListPicker.matches(job.name or job.command, words)
      or (spawner ~= nil and ListPicker.matches(spawner.name, words))
    if matches then
      local live, exited, key
      if job.spawned_by then
        live, exited, key = sub_live, sub_exited, job.spawned_by
        if not spawner and not sub_live[key] and not sub_exited[key] then
          orphan_ids[#orphan_ids + 1] = key
        end
      else
        live, exited, key = main_live, main_exited, "main"
      end
      if job.status == "running" then
        live[key] = live[key] or {}
        local bucket = live[key]
        bucket[#bucket + 1] = job
      else
        exited[key] = exited[key] or {}
        local bucket = exited[key]
        bucket[#bucket + 1] = job
      end
    end
  end

  -- Newest first everywhere: the sections and the job groups below all read
  -- latest at the top.
  running, finished = newest_first(running), newest_first(finished)
  for _, buckets in ipairs({ main_live, main_exited, sub_live, sub_exited }) do
    for key, bucket in pairs(buckets) do
      buckets[key] = newest_first(bucket)
    end
  end

  local rows = {}
  if main then
    rows[#rows + 1] = { task = main }
  end
  for i, task in ipairs(running) do
    rows[#rows + 1] = { task = task, section = i == 1 and RUNNING_SECTION or nil }
  end
  -- Subagent job groups follow the Running tasks and precede the Finished
  -- ones, mirroring where the flat Jobs section sat.
  local task_order = {}
  for _, task in ipairs(running) do
    task_order[#task_order + 1] = task
  end
  for _, task in ipairs(finished) do
    task_order[#task_order + 1] = task
  end
  for _, task in ipairs(task_order) do
    local live = sub_live[task.id] or {}
    local exited = sub_exited[task.id] or {}
    if #live + #exited > 0 then
      local header = JOB_INDENT .. task.name
      for _, job in ipairs(live) do
        rows[#rows + 1] = { job = job, section = header }
        header = nil
      end
      for _, job in ipairs(exited) do
        rows[#rows + 1] = { job = job, section = header }
        header = nil
      end
    end
  end
  -- A spawned_by id with no task row (the row is filtered out, or the host
  -- never sent one) still gets its own group under the raw id.
  for _, id in ipairs(orphan_ids) do
    local live = sub_live[id] or {}
    local exited = sub_exited[id] or {}
    local header = JOB_INDENT .. id
    for _, job in ipairs(live) do
      rows[#rows + 1] = { job = job, section = header }
      header = nil
    end
    for _, job in ipairs(exited) do
      rows[#rows + 1] = { job = job, section = header }
      header = nil
    end
  end
  for _, group in ipairs({
    { header = JOBS_SECTION, items = main_live.main or {}, key = "job" },
    -- Same section as the live ones, so the header repeats only when a
    -- filter emptied the live half.
    { header = #(main_live.main or {}) == 0 and JOBS_SECTION or nil, items = main_exited.main or {}, key = "job" },
  }) do
    local header = group.header
    for _, job in ipairs(group.items) do
      rows[#rows + 1] = { [group.key] = job, section = header }
      header = nil
    end
  end
  for i, task in ipairs(finished) do
    rows[#rows + 1] = { task = task, section = i == 1 and FINISHED_SECTION or nil }
  end
  local job_count = #(main_live.main or {}) + #(main_exited.main or {})
  for _, bucket in pairs(sub_live) do
    job_count = job_count + #bucket
  end
  for _, bucket in pairs(sub_exited) do
    job_count = job_count + #bucket
  end
  return {
    rows = rows,
    sections = {
      running = #running,
      jobs = job_count,
      finished = #finished,
    },
  }
end

-- Same glyph language as the task rows: the live spinner, then check or
-- cross by exit code.
function M.job_icon(job)
  if job.status == "running" then
    return RUN_ICON, "accent", true
  elseif job.exit_code == 0 then
    return OK_ICON, "success"
  end
  return BAD_ICON, "error"
end

function M.row_id(row)
  return row.task and row.task.id or row.job.id
end

function M.row_name(row)
  if row.task then
    return row.task.name
  end
  return row.job.name or row.job.command
end

-- Only a finished subagent may leave the list. The main chat is the session
-- itself, and dropping a live task would orphan its transcript. The host has
-- the final say. This check only decides which rows ask "are you sure".
function M.deletable(task)
  return task.status ~= nil and not alive(task.status)
end

-- Position of {id} among {rows}, or nil. The selection is kept as an id and
-- resolved here at render time, so a task moving between sections never drags
-- the cursor with it.
function M.index_of(rows, id)
  for i, row in ipairs(rows) do
    if M.row_id(row) == id then
      return i
    end
  end
  return nil
end

return M
