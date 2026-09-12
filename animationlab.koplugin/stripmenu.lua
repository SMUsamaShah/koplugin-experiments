local Menu = {}

function Menu.augment(AnimationLab, radioItem)
    local Dispatcher = require("dispatcher")
    local _ = require("gettext")

    local old_init = AnimationLab.init
    function AnimationLab:init()
        old_init(self)
        self.page_dither = G_reader_settings:readSetting("animationlab_page_dither") or "gray"
        self.page_scheduler = G_reader_settings:readSetting("animationlab_page_scheduler") or "free"
        self.page_queue_depth = tonumber(G_reader_settings:readSetting("animationlab_page_queue_depth")) or 4
        self.page_delay_ms = tonumber(G_reader_settings:readSetting("animationlab_page_delay_ms")) or 40
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
            dither = self.page_dither,
            scheduler = self.page_scheduler,
            queue_depth = self.page_queue_depth,
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

    function AnimationLab:pageTurnSettingsItem()
        return {
            text = _("Page-turn animation settings"),
            sub_item_table = {
                {
                    text = _("Dithering"),
                    sub_item_table = {
                        settingRadio(self, _("Original grayscale / no dither"), "page_dither", "gray"),
                        settingRadio(self, _("SW Bayer"), "page_dither", "sw_bayer"),
                        settingRadio(self, _("SW stochastic"), "page_dither", "sw_stochastic"),
                        settingRadio(self, _("SW Floyd-Steinberg"), "page_dither", "sw_floyd_steinberg"),
                        settingRadio(self, _("SW Atkinson"), "page_dither", "sw_atkinson"),
                        settingRadio(self, _("Plain B/W threshold"), "page_dither", "threshold"),
                    },
                },
                {
                    text = _("Scheduling"),
                    sub_item_table = {
                        settingRadio(self, _("Free-running (ZIP original)"), "page_scheduler", "free"),
                        settingRadio(self, _("Fixed interval"), "page_scheduler", "fixed"),
                        settingRadio(self, _("Bounded EPDC queue"), "page_scheduler", "bounded"),
                        settingRadio(self, _("Synchronized"), "page_scheduler", "sync"),
                    },
                },
                {
                    text = _("Queue depth (bounded)"),
                    enabled_func = function() return self.page_scheduler == "bounded" end,
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
                    text = _("Strip delay"),
                    sub_item_table = {
                        settingRadio(self, "0 ms", "page_delay_ms", 0),
                        settingRadio(self, "5 ms", "page_delay_ms", 5),
                        settingRadio(self, "10 ms", "page_delay_ms", 10),
                        settingRadio(self, "20 ms", "page_delay_ms", 20),
                        settingRadio(self, "30 ms", "page_delay_ms", 30),
                        settingRadio(self, "40 ms (ZIP original)", "page_delay_ms", 40),
                        settingRadio(self, "50 ms", "page_delay_ms", 50),
                        settingRadio(self, "60 ms", "page_delay_ms", 60),
                        settingRadio(self, "80 ms", "page_delay_ms", 80),
                        settingRadio(self, "100 ms", "page_delay_ms", 100),
                    },
                },
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
                    help_text = _("Animate normal one-page taps, swipes and page-turn keys with the KPW4 six-strip reveal."),
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
