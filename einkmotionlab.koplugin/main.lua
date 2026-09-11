local plugin_dir = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local MotionLab = dofile(plugin_dir .. "legacy.lua")

-- v0.1.15 added GIF/demo work after the diagnostic settings string was last
-- updated. Keep the implementation unchanged, but make new logs identify the
-- installed plugin version correctly.
local oldCurrentSettingsLines = MotionLab.currentSettingsLines
function MotionLab:currentSettingsLines(...)
    local lines = oldCurrentSettingsLines(self, ...)
    if lines and lines[1] then lines[1] = "plugin_version=0.1.15" end
    return lines
end

return MotionLab
