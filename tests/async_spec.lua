--[[
    Async gateway specs: queue ordering, completion/error/cancel callback
    contract, and executor selection. The stub ffi/util has no
    runInSubProcess, so the auto-detected executor is the inline one --
    tasks run synchronously, which is exactly what the harness relies on.
    The subprocess executor itself is device-only (fork + pipes) and is
    exercised on-device, like the rest of the UI layer.
]]

local spec_helper = require("spec_helper")

describe("async.lua", function()
    local Async

    before_each(function()
        spec_helper.setup()
        Async = require("async")
    end)

    after_each(function()
        spec_helper.teardown()
    end)

    it("runs a task and delivers (result, err) to on_done", function()
        local async = Async.new{}
        local got_result, got_err = nil, "unset"
        async:run(function() return { value = 42 }, nil end, function(result, err)
            got_result, got_err = result, err
        end)
        assert.same({ value = 42 }, got_result)
        assert.is_nil(got_err)
    end)

    it("passes a task's error second value through", function()
        local async = Async.new{}
        local got_result, got_err
        async:run(function() return nil, "HTTP 503" end, function(result, err)
            got_result, got_err = result, err
        end)
        assert.is_nil(got_result)
        assert.equals("HTTP 503", got_err)
    end)

    it("reports a crashed task as an error, not an exception", function()
        local async = Async.new{}
        local got_err
        async:run(function() error("boom") end, function(_result, err)
            got_err = err
        end)
        assert.truthy(got_err:match("^task crashed:"))
        assert.truthy(got_err:match("boom"))
    end)

    it("runs queued tasks strictly in FIFO order", function()
        local async = Async.new{}
        local order = {}
        async:run(function() return "a" end, function(r) table.insert(order, r) end)
        async:run(function() return "b" end, function(r) table.insert(order, r) end)
        async:run(function() return "c" end, function(r) table.insert(order, r) end)
        assert.same({ "a", "b", "c" }, order)
    end)

    it("keeps serving the queue when an on_done callback crashes", function()
        local async = Async.new{}
        local second_ran = false
        async:run(function() return 1 end, function() error("callback boom") end)
        async:run(function() return 2 end, function() second_ran = true end)
        assert.is_true(second_ran)
    end)

    it("cancels a queued job without executing it", function()
        -- A custom executor that defers completion keeps job 1 'running'
        -- so job 2 stays queued and can be cancelled before execution.
        local finish_first
        local deferred_executor = function(async, job)
            if not finish_first then
                finish_first = function() async:_finish(job, "first", nil) end
            else
                async:_finish(job, "should not run", nil)
            end
        end
        local async = Async.new{ executor = deferred_executor }
        local executed = {}
        async:run(function() return "first" end, function(r) table.insert(executed, r) end)
        local cancelled_result, cancelled_err = "unset", nil
        local job2 = async:run(function() return "second" end, function(r, e)
            cancelled_result, cancelled_err = r, e
        end)
        async:cancel(job2)
        assert.is_nil(cancelled_result)
        assert.equals("cancelled", cancelled_err)
        finish_first()
        assert.same({ "first" }, executed)
    end)

    it("cancel of the running job fires on_done once and advances the queue", function()
        local started = {}
        local hang_executor = function(async, job)
            table.insert(started, job)
            -- never finishes on its own (simulates an in-flight subprocess)
        end
        local async = Async.new{ executor = hang_executor }
        local done_count, got_err = 0, nil
        local job = async:run(function() end, function(_r, e)
            done_count = done_count + 1
            got_err = e
        end)
        local second_started = false
        async:run(function() end, function() end, {})
        assert.is_false(#started == 2)
        async:cancel(job)
        second_started = #started == 2
        assert.equals(1, done_count)
        assert.equals("cancelled", got_err)
        assert.is_true(second_started)
        -- A late double-finish from the dead executor must be ignored.
        async:_finish(job, "late", nil)
        assert.equals(1, done_count)
    end)

    it("isBusy reflects queue and in-flight state", function()
        local finish
        local deferred_executor = function(async, job)
            finish = function() async:_finish(job, true, nil) end
        end
        local async = Async.new{ executor = deferred_executor }
        assert.is_false(async:isBusy())
        async:run(function() end, function() end)
        assert.is_true(async:isBusy())
        finish()
        assert.is_false(async:isBusy())
    end)

    it("auto-detects the inline executor when ffi/util lacks subprocess support", function()
        local async = Async.new{}
        -- Synchronous completion proves the inline path: the callback has
        -- fired before run() returns, with no UIManager ticks drained.
        local done = false
        async:run(function() return true end, function() done = true end)
        assert.is_true(done)
    end)

    describe("sanitizeForIPC", function()
        -- Guards the cross-fork serialization: a JSON-null userdata sentinel
        -- (rapidjson.null) in an API response must not make the whole payload
        -- unencodable -- that was the bug that silently stuck the library
        -- offline. Sanitize drops non-serializable values; JSON null -> absent.
        it("passes through plain JSON-shaped data unchanged", function()
            local books = {
                { id = 1, metadata = { title = "A", authors = { "x", "y" } }, read = true },
                { id = 2, metadata = { title = "B", seriesNumber = 3.5 } },
            }
            assert.same(books, Async.sanitizeForIPC(books))
        end)

        it("drops a userdata null sentinel (and the cdata/function family)", function()
            local sentinel = io.stdout  -- a userdata stand-in for rapidjson.null
            local cleaned = Async.sanitizeForIPC({
                id = 7,
                seriesName = sentinel,        -- JSON null -> dropped
                cb = function() end,          -- not serializable -> dropped
                nested = { ok = true, bad = sentinel },
            })
            assert.same({ id = 7, nested = { ok = true } }, cleaned)
        end)

        it("drops non-string/number table keys without crashing", function()
            local cleaned = Async.sanitizeForIPC({ [io.stdout] = "x", good = 1 })
            assert.same({ good = 1 }, cleaned)
        end)
    end)
end)
