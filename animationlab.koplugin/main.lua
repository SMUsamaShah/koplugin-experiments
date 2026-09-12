local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local plugin_dir = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"

local AnimationLab = WidgetContainer:extend{
    name = "animationlab",
    is_doc_only = true,
}

function AnimationLab:init()
    self.ui.menu:registerToMainMenu(self)
end

function AnimationLab:turnPageForTest(direction)
    UIManager:nextTick(function()
        if self.ui then
            self._animationlab_force_once = true
            self.ui:handleEvent(Event:new("GotoViewRel", direction))
        end
    end)
end

local function radioItem(text, checked, callback)
    return {
        text = text,
        radio = true,
        checked_func = checked,
        callback = callback,
    }
end

local StripReveal = dofile(plugin_dir .. "stripreveal.lua")
dofile(plugin_dir .. "stripmenu.lua").augment(AnimationLab, radioItem)
dofile(plugin_dir .. "pageturnhook.lua").augment(AnimationLab, StripReveal)

local updater = dofile(plugin_dir .. "pluginupdater.lua").new{
    repository = "SMUsamaShah/koplugin-experiments",
    branch = "main",
    folder = "animationlab.koplugin",
}

local old_add = AnimationLab.addToMainMenu
function AnimationLab:addToMainMenu(menu_items)
    old_add(self, menu_items)
    local items = menu_items.animationlab and menu_items.animationlab.sub_item_table
    if items then items[#items + 1] = updater:menuItem() end
end

return AnimationLab
