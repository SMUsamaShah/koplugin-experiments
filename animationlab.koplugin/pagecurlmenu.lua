local PageCurl = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "pagecurl.lua")

local Menu = {}
local Screen = require("device").screen

function Menu.augment(AnimationLab, radioItem)
    local Dispatcher = require("dispatcher")
    local UIManager = require("ui/uimanager")
    local _ = require("gettext")

    local old_init = AnimationLab.init
    function AnimationLab:init()
        old_init(self)
        self.page_waveform = G_reader_settings:readSetting("animationlab_page_waveform") or "du"
        self.page_dither = G_reader_settings:readSetting("animationlab_page_dither") or "gray"
        self.page_scheduler = G_reader_settings:readSetting("animationlab_page_scheduler") or "free"
        self.page_target_fps = tonumber(G_reader_settings:readSetting("animationlab_page_target_fps")) or 20
        self.page_queue_depth = tonumber(G_reader_settings:readSetting("animationlab_page_queue_depth")) or 4
        self.page_frames = tonumber(G_reader_settings:readSetting("animationlab_page_frames")) or 12
        self.page_delay_ms = tonumber(G_reader_settings:readSetting("animationlab_page_delay_ms")) or 4
        self:onAnimationLabRegisterActions()
    end

    function AnimationLab:setPageSetting(key, value)
        self[key] = value
        G_reader_settings:saveSetting("animationlab_" .. key, value)
    end

    function AnimationLab:getPageTurnConfig()
        return {
            waveform = self.page_waveform,
            dither = self.page_dither,
            scheduler = self.page_scheduler,
            target_fps = self.page_target_fps,
            queue_depth = self.page_queue_depth,
            frames = self.page_frames,
            delay_ms = self.page_delay_ms,
        }
    end

    function AnimationLab:onAnimationLabRegisterActions()
        Dispatcher:registerAction("animationlab_animated_next", {
            category = "none",
            event = "AnimationLabAnimatedNext",
            title = _("Animated page turn: next page"),
            reader = true,
        })
        Dispatcher:registerAction("animationlab_animated_previous", {
            category = "none",
            event = "AnimationLabAnimatedPrevious",
            title = _("Animated page turn: previous page"),
            reader = true,
        })
    end

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
            if not ok then
                local sw, sh = Screen.bb:getWidth(), Screen.bb:getHeight()
                Screen.bb:blitFrom(new, 0, 0, 0, 0, sw, sh)
                Screen:refreshPartial(0, 0, sw, sh)
                if Screen.refreshWaitForLast then Screen:refreshWaitForLast() end
                old:free()
                new:free()
                self:showInfo("Animated page turn failed:\n\n" .. tostring(result))
                return
            end

            self._last_page_turn_result = result
            old:free()
            new:free()
        end)
    end

    function AnimationLab:onAnimationLabAnimatedNext()
        self:runConfiguredPageTurn(1)
    end

    function AnimationLab:onAnimationLabAnimatedPrevious()
        self:runConfiguredPageTurn(-1)
    end

    local function settingRadio(self, text, field, value)
        return radioItem(text,
            function() return self[field] == value end,
            function() self:setPageSetting(field, value) end)
    end

    function AnimationLab:pageTurnSettingsItem()
        return {
            text = _("Page-turn animation settings"),
            sub_item_table = {
                {
                    text = _("Waveform"),
                    sub_item_table = {
                        settingRadio(self, _("DU / Fast"), "page_waveform", "du"),
                        settingRadio(self, _("A2"), "page_waveform", "a2"),
                    },
                },
                {
                    text = _("Dithering"),
                    sub_item_table = {
                        settingRadio(self, _("Grayscale / no dither"), "page_dither", "gray"),
                        settingRadio(self, _("SW Bayer"), "page_dither", "sw_bayer"),
                        settingRadio(self, _("SW stochastic"), "page_dither", "sw_stochastic"),
                        settingRadio(self, _("SW Floyd-Steinberg"), "page_dither", "sw_floyd_steinberg"),
                        settingRadio(self, _("SW Atkinson"), "page_dither", "sw_atkinson"),
                        settingRadio(self, _("Plain B/W threshold"), "page_dither", "threshold"),
                        settingRadio(self, _("Rex HW ordered"), "page_dither", "hw_ordered"),
                        settingRadio(self, _("Rex HW Floyd-Steinberg"), "page_dither", "hw_floyd_steinberg"),
                        settingRadio(self, _("Rex HW Atkinson"), "page_dither", "hw_atkinson"),
                    },
                },
                {
                    text = _("Scheduling"),
                    sub_item_table = {
                        settingRadio(self, _("Free-running"), "page_scheduler", "free"),
                        settingRadio(self, _("Fixed clock / skip late frames"), "page_scheduler", "fixed"),
                        settingRadio(self, _("Bounded EPDC queue"), "page_scheduler", "bounded"),
                        settingRadio(self, _("Synchronized"), "page_scheduler", "sync"),
                    },
                },
                {
                    text = _("Target FPS (fixed clock)"),
                    sub_item_table = {
                        settingRadio(self, "10", "page_target_fps", 10),
                        settingRadio(self, "15", "page_target_fps", 15),
                        settingRadio(self, "20", "page_target_fps", 20),
                        settingRadio(self, "30", "page_target_fps", 30),
                        settingRadio(self, "45", "page_target_fps", 45),
                        settingRadio(self, "60", "page_target_fps", 60),
                    },
                },
                {
                    text = _("Queue depth (bounded)"),
                    sub_item_table = {
                        settingRadio(self, "1", "page_queue_depth", 1),
                        settingRadio(self, "2", "page_queue_depth", 2),
                        settingRadio(self, "3", "page_queue_depth", 3),
                        settingRadio(self, "4", "page_queue_depth", 4),
                        settingRadio(self, "6", "page_queue_depth", 6),
                        settingRadio(self, "8", "page_queue_depth", 8),
                    },
                },
                {
                    text = _("Animation frames"),
                    sub_item_table = {
                        settingRadio(self, "6", "page_frames", 6),
                        settingRadio(self, "8", "page_frames", 8),
                        settingRadio(self, "10", "page_frames", 10),
                        settingRadio(self, "12", "page_frames", 12),
                        settingRadio(self, "16", "page_frames", 16),
                        settingRadio(self, "20", "page_frames", 20),
                    },
                },
                {
                    text = _("Free/bounded frame delay"),
                    sub_item_table = {
                        settingRadio(self, "0 ms", "page_delay_ms", 0),
                        settingRadio(self, "2 ms", "page_delay_ms", 2),
                        settingRadio(self, "4 ms", "page_delay_ms", 4),
                        settingRadio(self, "8 ms", "page_delay_ms", 8),
                        settingRadio(self, "12 ms", "page_delay_ms", 12),
                    },
                },
            },
        }
    end

    local old_add = AnimationLab.addToMainMenu
    function AnimationLab:addToMainMenu(menu_items)
        old_add(self, menu_items)
        local items = menu_items.animationlab.sub_item_table

        if items[1] then items[1].text = _("Legacy previews: next page") end
        if items[2] then items[2].text = _("Legacy previews: previous page") end

        table.insert(items, 1, self:pageTurnSettingsItem())
        table.insert(items, 1, {
            text = _("Animated previous page"),
            callback = function() self:runConfiguredPageTurn(-1) end,
        })
        table.insert(items, 1, {
            text = _("Animated next page"),
            callback = function() self:runConfiguredPageTurn(1) end,
        })
    end
end

return Menu
