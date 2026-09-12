local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Screen = Device.screen
local Hook = {}

-- UIManager caches the public Screen.refresh* functions at module load, while
-- those functions still dispatch to refresh*Imp dynamically. Intercept the Imp
-- methods so a plugin loaded later can replace the physical repaint reliably.
local REFRESH_IMP_METHODS = {
    "refreshFullImp",
    "refreshPartialImp",
    "refreshNoMergePartialImp",
    "refreshFlashPartialImp",
    "refreshUIImp",
    "refreshNoMergeUIImp",
    "refreshFlashUIImp",
    "refreshFastImp",
    "refreshA2Imp",
}

local function freeBuffer(bb)
    if bb then pcall(function() bb:free() end) end
end

local function restoreDestination(screen, new_bb)
    local w, h = screen.bb:getWidth(), screen.bb:getHeight()
    screen.bb:blitFrom(new_bb, 0, 0, 0, 0, w, h)
end

function Hook.augment(AnimationLab, Renderers)
    local state = Screen._animationlab_page_turn_hook
    if not state then
        state = {
            originals = {},
            owner = nil,
            old_bb = nil,
            direction = nil,
            armed = false,
            suppress = false,
            bypass = false,
        }
        Screen._animationlab_page_turn_hook = state

        state.original_beforePaint = Screen.beforePaint
        Screen.beforePaint = function(screen, ...)
            local first_paint = not screen.painting
            local owner = state.owner
            local enabled = owner and (owner.auto_page_turn or owner._animationlab_force_once)
            if first_paint and not state.bypass and enabled and owner._animationlab_pending_direction then
                freeBuffer(state.old_bb)
                state.old_bb = screen.bb:copy()
                state.direction = owner._animationlab_pending_direction
                owner._animationlab_pending_direction = nil
                owner._animationlab_force_once = nil
                state.armed = true
                state.suppress = false
                logger.info("AnimationLab: armed page-turn capture, direction", state.direction,
                    "style", owner.page_style)
            end
            return state.original_beforePaint(screen, ...)
        end

        state.original_afterPaint = Screen.afterPaint
        Screen.afterPaint = function(screen, ...)
            local result = state.original_afterPaint(screen, ...)
            freeBuffer(state.old_bb)
            state.old_bb = nil
            state.direction = nil
            state.armed = false
            state.suppress = false
            return result
        end

        local function interceptRefreshImp(name, original)
            return function(screen, ...)
                if state.bypass then return original(screen, ...) end
                if state.suppress then return end
                if not state.armed or not state.old_bb then return original(screen, ...) end

                local owner = state.owner
                if not owner then
                    state.armed = false
                    freeBuffer(state.old_bb)
                    state.old_bb = nil
                    state.direction = nil
                    return original(screen, ...)
                end

                local config = owner:getPageTurnConfig()
                local renderer = Renderers[config.style] or Renderers.strip
                local ready, why = renderer.preflight(config)
                if not ready then
                    logger.warn("AnimationLab: page-turn preflight failed:", why)
                    state.armed = false
                    freeBuffer(state.old_bb)
                    state.old_bb = nil
                    state.direction = nil
                    return original(screen, ...)
                end

                local old_bb = state.old_bb
                local new_bb = screen.bb:copy()
                local direction = state.direction or 1
                state.old_bb = nil
                state.direction = nil
                state.armed = false
                state.suppress = true
                state.bypass = true
                logger.info("AnimationLab: intercepted repaint via", name,
                    "direction", direction, "style", config.style)

                local ok, result = pcall(renderer.run, old_bb, new_bb, direction, config)
                if ok then
                    restoreDestination(screen, new_bb)
                    -- Both styles end with the exact destination in Screen.bb.
                    -- The uploaded KPW4 patch does one final UI-quality settle.
                    if screen.refreshUI then
                        screen:refreshUI(0, 0, screen.bb:getWidth(), screen.bb:getHeight())
                    elseif screen.refreshPartial then
                        screen:refreshPartial(0, 0, screen.bb:getWidth(), screen.bb:getHeight())
                    end
                    if screen.refreshWaitForLast then screen:refreshWaitForLast() end

                    if UIManager.refresh_count and UIManager.refresh_count > 0 then
                        UIManager.refresh_count = UIManager.refresh_count - 1
                    end
                    owner._last_page_turn_result = result
                else
                    logger.warn("AnimationLab page-turn animation failed:", result)
                    restoreDestination(screen, new_bb)
                    state.suppress = false
                    original(screen, ...)
                end

                state.bypass = false
                freeBuffer(old_bb)
                freeBuffer(new_bb)
                return
            end
        end

        for _, name in ipairs(REFRESH_IMP_METHODS) do
            local original = Screen[name]
            if type(original) == "function" then
                state.originals[name] = original
                Screen[name] = interceptRefreshImp(name, original)
            end
        end
    end

    local function installNavigationHook(owner, nav)
        if not nav or nav._animationlab_direction_hook then return end
        local original = nav.onGotoViewRel
        if type(original) ~= "function" then return end
        nav._animationlab_direction_hook = original

        nav.onGotoViewRel = function(nav_self, diff, no_page_turn)
            local step = tonumber(diff)
            local enabled = owner.auto_page_turn or owner._animationlab_force_once
            local eligible = enabled and no_page_turn ~= true and (step == 1 or step == -1)

            local before = nav_self.current_page
            if eligible then
                local direction = step
                local view = owner.ui and owner.ui.view
                if view and view.inverse_reading_order then direction = -direction end
                owner._animationlab_pending_direction = direction
            end

            local result = original(nav_self, diff, no_page_turn)
            if eligible and before ~= nil and nav_self.current_page ~= nil and before == nav_self.current_page then
                owner._animationlab_pending_direction = nil
                owner._animationlab_force_once = nil
            end
            return result
        end
    end

    local old_init = AnimationLab.init
    function AnimationLab:init()
        old_init(self)
        state.owner = self
        installNavigationHook(self, self.ui and self.ui.paging)
        installNavigationHook(self, self.ui and self.ui.rolling)
        UIManager:nextTick(function()
            if state.owner == self and self.ui then
                installNavigationHook(self, self.ui.paging)
                installNavigationHook(self, self.ui.rolling)
            end
        end)
    end

    local old_close = AnimationLab.onCloseDocument
    function AnimationLab:onCloseDocument(...)
        self._animationlab_pending_direction = nil
        self._animationlab_force_once = nil
        if state.owner == self then
            state.owner = nil
            freeBuffer(state.old_bb)
            state.old_bb = nil
            state.direction = nil
            state.armed = false
            state.suppress = false
            state.bypass = false
        end
        if old_close then return old_close(self, ...) end
    end
end

return Hook
