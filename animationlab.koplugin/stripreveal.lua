local Device = require("device")
local ffiUtil = require("ffi/util")

local Screen = Device.screen
local StripReveal = {}

function StripReveal.preflight()
    if not Screen.refreshUI then
        return nil, "UI refresh is unavailable on this device."
    end
    return true
end

-- Exact KPW4-modified animation from the uploaded patch:
-- 6 equal progress steps, 40ms delay, and only the newly revealed full-height
-- strip is physically refreshed. Previously revealed pixels persist by e-ink
-- bistability; the common hook performs the final full-screen UI settle.
function StripReveal.run(old, new, direction)
    local sw, sh = Screen.bb:getWidth(), Screen.bb:getHeight()
    local steps = 6
    local delay_us = 40000
    local prev_dx = 0

    Screen.bb:blitFrom(old, 0, 0, 0, 0, sw, sh)

    for i = 1, steps do
        local dx = math.floor(sw * (i / steps))
        local strip_w = dx - prev_dx

        if direction > 0 then
            -- Forward: reveal destination from the right, moving right-to-left.
            if sw - dx > 0 then
                Screen.bb:blitFrom(old, 0, 0, 0, 0, sw - dx, sh)
            end
            if dx > 0 then
                Screen.bb:blitFrom(new, sw - dx, 0, sw - dx, 0, dx, sh)
            end
            if strip_w > 0 then
                Screen:refreshUI(sw - dx, 0, strip_w, sh)
            end
        else
            -- Backward: reveal destination from the left, moving left-to-right.
            if dx > 0 then
                Screen.bb:blitFrom(new, 0, 0, 0, 0, dx, sh)
            end
            if sw - dx > 0 then
                Screen.bb:blitFrom(old, dx, 0, dx, 0, sw - dx, sh)
            end
            if strip_w > 0 then
                Screen:refreshUI(prev_dx, 0, strip_w, sh)
            end
        end

        prev_dx = dx
        ffiUtil.usleep(delay_us)
    end

    Screen.bb:blitFrom(new, 0, 0, 0, 0, sw, sh)
    return {
        style = "strip",
        frames = steps,
        delay_ms = 40,
    }
end

return StripReveal
