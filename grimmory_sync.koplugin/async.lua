--[[
    NOTE: kept in sync with grimmory.koplugin/async.lua. The two plugins share
    nothing at runtime (separate package paths on device), so the gateway is
    duplicated rather than shared. Change both copies together.

    Serialized async task gateway: runs blocking work (network, shell) in a
    forked subprocess so the UI loop never waits on a socket. The parent
    polls for completion on UIManager ticks; the child writes its serialized
    result to a pipe and exits.

    Why a queue: Grimmory rotates refresh tokens, so two concurrent tasks
    that both hit the 401-refresh path would invalidate each other's tokens.
    Tasks run strictly one at a time, FIFO, which makes the whole
    refresh/retry state machine race-free without cross-process locking.

    Task contract: task() runs IN THE CHILD PROCESS. It may block as long as
    it likes, must return (result, err) where result is serializable (plain
    tables/strings/numbers/booleans -- no functions, no userdata), and must
    not touch UI state or flush settings (the parent owns all files; return
    data and let the on_done callback persist it).

    Executor selection: uses ffi/util.runInSubProcess when available (the
    device), else falls back to running tasks inline (the off-device test
    harness, whose ffi/util stub has no subprocess support -- callbacks then
    fire synchronously, which keeps specs deterministic). Tests can also
    inject opts.executor directly.

    Standalone module -- requires UIManager/ffiutil lazily, only on the
    subprocess path, so specs exercise it without KOReader present.
]]

local logger = require("logger")

local Async = {}
Async.__index = Async

local DEFAULT_POLL_SECONDS = 0.25
-- Reap a cancelled child every 5s, no hurry (mirrors Trapper).
local COLLECT_SECONDS = 5

-- Child and parent must pick the same codec; both run the same process
-- image, so a capability probe is deterministic across the fork.
local function getCodec()
    local ok_buf, buffer = pcall(require, "string.buffer")
    if ok_buf and buffer and buffer.encode then
        return buffer.encode, buffer.decode
    end
    local dump = require("dump")
    local encode = function(t) return "return " .. dump(t) end
    local decode = function(s)
        local chunk = loadstring(s)
        if not chunk then error("payload did not parse") end
        return chunk()
    end
    return encode, decode
end

-- Deep-copy a value keeping ONLY what survives the cross-fork codec: strings,
-- numbers, booleans, and plain tables. Everything else -- functions, threads,
-- and crucially the userdata/cdata sentinel some JSON decoders (e.g.
-- rapidjson.null) return for JSON null -- is dropped. string.buffer.encode and
-- the dump fallback both throw on userdata/cdata, so an API response carrying
-- a null sentinel would otherwise fail to serialize and the task would come
-- back as an error (manifesting as the library silently falling offline).
-- Dropping a JSON-null value is the correct semantics anyway: absent == null.
local function sanitizeForIPC(v, depth)
    local t = type(v)
    if t == "string" or t == "number" or t == "boolean" then
        return v
    elseif t == "table" then
        depth = depth or 0
        if depth > 100 then return nil end -- guard against pathological nesting
        local out = {}
        for k, val in pairs(v) do
            local tk = type(k)
            if tk == "string" or tk == "number" then
                local sv = sanitizeForIPC(val, depth + 1)
                if sv ~= nil then out[k] = sv end
            end
        end
        return out
    end
    return nil -- userdata / cdata / function / thread: not serializable
end
Async.sanitizeForIPC = sanitizeForIPC

function Async.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Async)
    self.executor = opts.executor
    self.poll_seconds = opts.poll_seconds or DEFAULT_POLL_SECONDS
    self._queue = {}
    self._current = nil
    return self
end

--- Enqueue a task. on_done(result, err) fires in the parent exactly once:
-- with the task's return values, (nil, "task crashed: ...") if it raised,
-- or (nil, "cancelled") if cancelled before completion.
-- @param task function: runs in the child; returns (result, err)
-- @param on_done function(result, err)
-- @param opts table|nil: { on_progress = function() } called on each parent
--        poll tick while the task runs (subprocess executor only)
-- @return table: job handle usable with cancel()
function Async:run(task, on_done, opts)
    local job = {
        task = task,
        on_done = on_done or function() end,
        opts = opts or {},
        finished = false,
    }
    table.insert(self._queue, job)
    self:_startNext()
    return job
end

function Async:isBusy()
    return self._current ~= nil or #self._queue > 0
end

--- Cancel a job. Queued jobs are dropped; the running job's subprocess is
-- killed and reaped in the background. on_done(nil, "cancelled") fires
-- unless the job already finished.
function Async:cancel(job)
    if not job or job.finished then return end
    for i, queued in ipairs(self._queue) do
        if queued == job then
            table.remove(self._queue, i)
            self:_finish(job, nil, "cancelled")
            return
        end
    end
    if self._current == job then
        job.cancel_requested = true
        if job.kill then job.kill() end
        -- _finish flips _current and starts the next job; the killed
        -- child is collected by the executor's reap loop.
        self:_finish(job, nil, "cancelled")
    end
end

function Async:_finish(job, result, err)
    if job.finished then return end
    job.finished = true
    if self._current == job then
        self._current = nil
    end
    local ok, cb_err = pcall(job.on_done, result, err)
    if not ok then
        logger.warn("Grimmory async: on_done callback crashed:", tostring(cb_err))
    end
    self:_startNext()
end

function Async:_startNext()
    if self._current then return end
    local job = table.remove(self._queue, 1)
    if not job then return end
    self._current = job
    local executor = self.executor or self:_defaultExecutor()
    local ok, exec_err = pcall(executor, self, job)
    if not ok then
        logger.warn("Grimmory async: executor crashed:", tostring(exec_err))
        self:_finish(job, nil, "executor crashed: " .. tostring(exec_err))
    end
end

function Async:_defaultExecutor()
    if self._detected_executor then return self._detected_executor end
    local ok, ffiutil = pcall(require, "ffi/util")
    if ok and type(ffiutil) == "table" and ffiutil.runInSubProcess then
        self._detected_executor = Async.subprocessExecutor
    else
        self._detected_executor = Async.inlineExecutor
    end
    return self._detected_executor
end

--- Run the task in this process, synchronously. Test harness / fallback
-- path: blocks like the pre-async code did, but preserves the callback API.
function Async.inlineExecutor(self, job)
    local ok, result, err = pcall(job.task)
    if not ok then
        self:_finish(job, nil, "task crashed: " .. tostring(result))
    else
        self:_finish(job, result, err)
    end
end

--- Fork; child runs the task and writes the encoded (result, err) pair to
-- the pipe; parent polls done-or-readable on UIManager ticks (the Trapper
-- collect pattern), so the UI loop keeps running for the whole task.
--
-- Robustness: if the subprocess cannot deliver a clean result for an
-- INFRASTRUCTURE reason -- fork unavailable on this device, a truncated or
-- undecodable pipe payload, an encode failure in the child -- the job is
-- re-run inline (synchronously) so correctness never depends on the fork
-- working. The blocking fallback can briefly freeze the UI, but a working
-- (if slower) result beats silently degrading -- which is what surfaced as
-- the library getting stuck offline. Our forked tasks are read-only or
-- idempotent (GETs, latest-wins progress pushes, a temp-file download), so a
-- re-run after a failed return is safe. A genuine task-level error (a network
-- failure, a 404) comes back as payload.ok=true with an inner err and is NOT
-- retried -- only the fork machinery failing triggers the fallback.
function Async.subprocessExecutor(self, job)
    local ffiutil = require("ffi/util")
    local UIManager = require("ui/uimanager")
    local encode, decode = getCodec()

    local function fallbackInline(reason)
        logger.warn("Grimmory async: subprocess path failed (" .. tostring(reason)
            .. "); running task inline")
        Async.inlineExecutor(self, job)
    end

    local pid, parent_read_fd = ffiutil.runInSubProcess(function(_pid, child_write_fd)
        local payload
        local ok, result, err = pcall(job.task)
        if not ok then
            payload = { ok = false, err = "task crashed: " .. tostring(result) }
        else
            -- Strip anything the codec can't encode (e.g. JSON-null userdata
            -- sentinels) so a valid result never fails to cross the pipe.
            payload = { ok = true, result = sanitizeForIPC(result), err = err }
        end
        local enc_ok, str = pcall(encode, payload)
        if not enc_ok then
            str = encode({ ok = false, err = "result not serializable: " .. tostring(str) })
        end
        ffiutil.writeToFD(child_write_fd, str, true)
    end, true) -- with_pipe

    if not pid then
        fallbackInline("fork failed: " .. tostring(parent_read_fd))
        return
    end

    -- Reap the (possibly killed) child and drain/close the pipe in the
    -- background so it never becomes a zombie. Used after cancel, and
    -- after normal completion when the child has not quite exited yet.
    local function collectAndClean()
        if ffiutil.isSubProcessDone(pid) then
            if parent_read_fd then
                ffiutil.readAllFromFD(parent_read_fd)
                parent_read_fd = nil
            end
            return
        end
        if parent_read_fd and ffiutil.getNonBlockingReadSize(parent_read_fd) ~= 0 then
            -- Child is blocked writing into a full pipe: drain so it can
            -- finish its write() and exit.
            ffiutil.readAllFromFD(parent_read_fd)
            parent_read_fd = nil
        end
        UIManager:scheduleIn(COLLECT_SECONDS, collectAndClean)
    end

    job.kill = function()
        ffiutil.terminateSubProcess(pid)
        UIManager:scheduleIn(COLLECT_SECONDS, collectAndClean)
    end

    local function poll()
        if job.finished then return end -- cancelled; collector owns the child
        if job.opts.on_progress then
            pcall(job.opts.on_progress)
        end
        local done = ffiutil.isSubProcessDone(pid)
        local readable = parent_read_fd
            and ffiutil.getNonBlockingReadSize(parent_read_fd) ~= 0
        if not (done or readable) then
            UIManager:scheduleIn(self.poll_seconds, poll)
            return
        end
        local payload_str = ""
        if parent_read_fd then
            -- Blocks only until the child closes its end, which follows
            -- its single final write within milliseconds.
            payload_str = ffiutil.readAllFromFD(parent_read_fd) or ""
            parent_read_fd = nil
        end
        if not done then
            UIManager:scheduleIn(COLLECT_SECONDS, collectAndClean)
        end
        if payload_str == "" then
            fallbackInline("subprocess returned no result")
            return
        end
        local ok, payload = pcall(decode, payload_str)
        if not ok or type(payload) ~= "table" then
            fallbackInline("could not decode subprocess result: " .. tostring(payload))
            return
        end
        if payload.ok then
            self:_finish(job, payload.result, payload.err)
        else
            -- The task crashed in the child or its result couldn't cross the
            -- pipe. Re-run inline: no serialization is needed there, and a
            -- task that genuinely raises will do so once more and surface its
            -- error (inlineExecutor catches it and finishes -- no loop).
            fallbackInline(payload.err or "subprocess task failed")
        end
    end

    UIManager:scheduleIn(self.poll_seconds, poll)
end

return Async
