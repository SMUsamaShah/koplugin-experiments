local plugin_dir = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local PageCurl = dofile(plugin_dir .. "pagecurl.lua")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")

local Cleanup = {}

function Cleanup.augment(AnimationLab)
    function AnimationLab:runConfiguredPageTurn(direction)
        local config = self:getPageTurnConfig()
        local ready, why = PageCurl.preflight(config)
        if not ready then
            self:showInfo(why)
            return
        end

        UIManager:nextTick(function()
            local old, new, boundary = self:captureRealPagePair(direction)
            if not old then
                if boundary then self:showInfo(boundary) end
                return
            end

            local ok, result = pcall(PageCurl.run, old, new, direction, config)
            local sw, sh = Screen.bb:getWidth(), Screen.bb:getHeight()
            if not ok then
                Screen.bb:blitFrom(new, 0, 0, 0, 0, sw, sh)
                Screen:refreshPartial(0, 0, sw, sh)
                if Screen.refreshWaitForLast then Screen:refreshWaitForLast() end
                old:free()
                new:free()
                self:showInfo("Animated page turn failed:\n\n" .. tostring(result))
                return
            end

            -- The curl contact line is deliberately dark while moving. At t=1
            -- its mathematically tiny fold can still round to one physical pixel,
            -- so refresh the terminal edge from the already-restored destination
            -- framebuffer to guarantee there is no persistent seam.
            local cleanup_w = math.min(4, sw)
            local cleanup_x = direction > 0 and 0 or (sw - cleanup_w)
            if config.waveform == "a2" then
                Screen:refreshA2(cleanup_x, 0, cleanup_w, sh)
            else
                Screen:refreshFast(cleanup_x, 0, cleanup_w, sh)
            end
            if Screen.refreshWaitForLast then Screen:refreshWaitForLast() end

            self._last_page_turn_result = result
            old:free()
            new:free()
        end)
    end
end

return Cleanup
