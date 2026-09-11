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

return AnimationLab
