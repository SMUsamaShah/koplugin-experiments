local plugin_dir = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local AnimationLab = dofile(plugin_dir .. "legacy.lua")

local function radioItem(text, checked, callback)
    return {
        text = text,
        radio = true,
        checked_func = checked,
        callback = callback,
    }
end

dofile(plugin_dir .. "pagecurlmenu.lua").augment(AnimationLab, radioItem)
dofile(plugin_dir .. "pagecurlcleanup.lua").augment(AnimationLab)

-- Reuse the exact same self-updater used by E-Ink Motion Lab. Keep this
-- wrapping last so "update plugin" is always the final Animation Lab menu item.
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
