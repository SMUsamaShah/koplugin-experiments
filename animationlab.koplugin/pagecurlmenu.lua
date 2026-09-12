local Menu = {}

function Menu.augment(AnimationLab, radioItem)
    local Dispatcher = require("dispatcher")
    local _ = require("gettext")

    local old_init = AnimationLab.init
    function AnimationLab:init()
        old_init(self)
        self.page_style = G_reader_settings:readSetting("animationlab_page_style") or "strip"
        self.page_waveform = G_reader_settings:readSetting("animationlab_page_waveform") or "du"
        self.page_dither = G_reader_settings:readSetting("animationlab_page_dither") or "gray"
        self.page_scheduler = G_reader_settings:readSetting("animationlab_page_scheduler") or "bounded"
        self.page_target_fps = tonumber(G_reader_settings:readSetting("animationlab_page_target_fps")) or 20
        self.page_queue_depth = tonumber(G_reader_settings:readSetting("animationlab_page_queue_depth")) or 4
        self.page_frames = tonumber(G_reader_settings:readSetting("animationlab_page_frames")) or 12
        self.page_delay_ms = tonumber(G_reader_settings:readSetting("animationlab_page_delay_ms")) or 4
        local saved_auto = G_reader_settings:readSetting("animationlab_auto_page_turn")
        self.auto_page_turn = saved_auto == nil and true or saved_auto == true
        self:onAnimationLabRegisterActions()
    end

    function AnimationLab:setPageSetting(key, value)
        self[key] = value
        G_reader_settings:saveSetting("animationlab_" .. key, value)
    end

    function AnimationLab:setAutoPageTurn(enabled)
        self.auto_page_turn = enabled and true or false
        G_reader_settings:saveSetting("animationlab_auto_page_turn", self.auto_page_turn)
    end

    function AnimationLab:getPageTurnConfig()
        return {
            style = self.page_style,
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

    function AnimationLab:onAnimationLabAnimatedNext()
        self:turnPageForTest(1)
    end

    function AnimationLab:onAnimationLabAnimatedPrevious()
        self:turnPageForTest(-1)
    end

    local function settingRadio(self, text, field, value)
        return radioItem(text,
            function() return self[field] == value end,
            function() self:setPageSetting(field, value) end)
    end

    function AnimationLab:thinCurlSettingsItem()
        return {
            text = _("Thin curl settings"),
            enabled_func = function() return self.page_style == "thin_curl" end,
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

    function AnimationLab:pageTurnSettingsItem()
        return {
            text = _("Page-turn animation settings"),
            sub_item_table = {
                {
                    text = _("Animation style"),
                    sub_item_table = {
                        settingRadio(self, _("KPW4 strip reveal (ZIP exact)"), "page_style", "strip"),
                        settingRadio(self, _("Thin page curl"), "page_style", "thin_curl"),
                    },
                },
                self:thinCurlSettingsItem(),
            },
        }
    end

    function AnimationLab:addToMainMenu(menu_items)
        menu_items.animationlab = {
            text = _("E-Ink Animation Lab"),
            sorting_hint = "more_tools",
            sub_item_table = {
                {
                    text = _("Animate normal page turns"),
                    checked_func = function() return self.auto_page_turn end,
                    callback = function() self:setAutoPageTurn(not self.auto_page_turn) end,
                    help_text = _("Animate normal one-page taps, swipes and page-turn keys after KOReader has rendered the destination page."),
                },
                self:pageTurnSettingsItem(),
                {
                    text = _("Test animated next page"),
                    callback = function() self:turnPageForTest(1) end,
                },
                {
                    text = _("Test animated previous page"),
                    callback = function() self:turnPageForTest(-1) end,
                },
            },
        }
    end
end

return Menu
