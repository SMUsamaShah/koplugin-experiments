local plugin_dir = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local PageCurl = dofile(plugin_dir .. "pagecurl.lua")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Cleanup = {}

function Cleanup.augment(AnimationLab)
    function AnimationLab:runConfiguredPageTurn(direction, quiet)
        if self._page_turn_running then return false end

        local config = self:getPageTurnConfig()
        local ready, why = PageCurl.preflight(config)
        if not ready then
            if not quiet then self:showInfo(why) end
            return false
        end

        self._page_turn_running = true
        UIManager:nextTick(function()
            local old, new
            local ok, err = pcall(function()
                local boundary
                old, new, boundary = self:captureRealPagePair(direction)
                if not old then
                    if boundary and not quiet then self:showInfo(boundary) end
                    return
                end

                local run_ok, result = pcall(PageCurl.run, old, new, direction, config)
                local sw, sh = Screen.bb:getWidth(), Screen.bb:getHeight()
                if not run_ok then
                    Screen.bb:blitFrom(new, 0, 0, 0, 0, sw, sh)
                    Screen:refreshPartial(0, 0, sw, sh)
                    if Screen.refreshWaitForLast then Screen:refreshWaitForLast() end
                    error(result, 0)
                end

                -- Clear the final contact line from the destination framebuffer.
                local cleanup_w = math.min(4, sw)
                local cleanup_x = direction > 0 and 0 or (sw - cleanup_w)
                if config.waveform == "a2" then
                    Screen:refreshA2(cleanup_x, 0, cleanup_w, sh)
                else
                    Screen:refreshFast(cleanup_x, 0, cleanup_w, sh)
                end
                if Screen.refreshWaitForLast then Screen:refreshWaitForLast() end

                self._last_page_turn_result = result
            end)

            if old then old:free() end
            if new then new:free() end
            self._page_turn_running = false

            if not ok then
                logger.warn("AnimationLab animated page turn failed:", err)
                if not quiet then
                    self:showInfo("Animated page turn failed:\n\n" .. tostring(err))
                end
            end
        end)

        return true
    end
end

return Cleanup
