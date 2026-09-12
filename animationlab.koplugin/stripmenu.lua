local Menu = {}

function Menu.augment(AnimationLab, radioItem)
    local Dispatcher = require("dispatcher")
    local _ = require("gettext")

    local old_init = AnimationLab.init
    function AnimationLab:init()
        old_init(self)
        -- New key on purpose: do not inherit the old curl-era page_waveform
        -- setting, which could otherwise silently force DU after upgrading.
        self.strip_waveform = G_reader_settings:readSetting("animationlab_strip_waveform") or "auto"
        self.strip_shape = G_reader_settings:readSetting("animationlab_strip_shape") or "straight"
        if self.strip_shape ~= "straight" and self.strip_shape ~= "diagonal"
                and self.strip_shape ~= "bottom_curve" then
            self.strip_shape = "straight"
        end
        self.page_scheduler = G_reader_settings:readSetting("animationlab_page_scheduler") or "free"
        if self.page_scheduler ~= "free" and self.page_scheduler ~= "fixed" then
            self.page_scheduler = "free"
        end
        self.page_delay_ms = tonumber(G_reader_settings:readSetting("animationlab_page_delay_ms")) or 40
        local saved_full_refresh = G_reader_settings:readSetting("animationlab_strip_full_refresh")
        self.strip_full_refresh = saved_full_refresh == true
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
            waveform = self.strip_waveform,
            shape = self.strip_shape,
            scheduler = self.page_scheduler,
            delay_ms = self.page_delay_ms,
            full_refresh = self.strip_full_refresh,
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
                    text = _("Reveal shape"),
                    sub_item_table = {
                        settingRadio(self, _("Straight vertical (ZIP original)"), "strip_shape", "straight"),
                        settingRadio(self, _("Diagonal — bottom first"), "strip_shape", "diagonal"),
                        settingRadio(self, _("Curved bottom flip"), "strip_shape", "bottom_curve"),
                    },
                },
                {
                    text = _("Waveform"),
                    sub_item_table = {
                        settingRadio(self, _("AUTO / UI (ZIP original)"), "strip_waveform", "auto"),
                        settingRadio(self, _("DU / Fast"), "strip_waveform", "du"),
                        settingRadio(self, _("A2"), "strip_waveform", "a2"),
                    },
                },
                {
                    text = _("Scheduling"),
                    sub_item_table = {
                        settingRadio(self, _("Free-running (ZIP original)"), "page_scheduler", "free"),
                        settingRadio(self, _("Fixed interval"), "page_scheduler", "fixed"),
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
                {
                    text = _("Full clean refresh afterwards"),
                    checked_func = function() return self.strip_full_refresh end,
                    callback = function()
                        self:setPageSetting("strip_full_refresh", not self.strip_full_refresh)
                    end,
                    help_text = _("After the animation, force a full-screen refreshFull() cleanup. Useful with A2 ghosting, but slower and may visibly flash. When disabled, the normal full-screen UI settle is still used."),
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
                    help_text = _("Animate normal one-page taps, swipes and page-turn keys with the KPW4 six-step reveal."),
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
