-- Software conversion happens once during preparation, never during playback.
local ffi = require("ffi")
local bit = require("bit")
local Dither = {}
local BAYER = {0,8,2,10,12,4,14,6,3,11,1,9,15,7,13,5}

-- Same bounded mixing as the validated noise hash; a fixed spatial mask.
local function thresholdAt(x, y)
    local h = bit.bxor(bit.tobit(x), bit.rol(bit.tobit(y), 16),
        bit.rol(97, 8), 0x9e3779b9)
    h = bit.bxor(h, bit.lshift(h, 13))
    h = bit.bxor(h, bit.rshift(h, 17))
    h = bit.bxor(h, bit.lshift(h, 5))
    h = bit.tobit(h + bit.lshift(h, 10))
    h = bit.bxor(h, bit.rshift(h, 6))
    h = bit.tobit(h + bit.lshift(h, 3))
    h = bit.bxor(h, bit.rshift(h, 11))
    h = bit.tobit(h + bit.lshift(h, 15))
    return bit.band(h, 0x7fffffff) * (255 / 2147483647)
end

function Dither.apply(bb, mode)
    if mode == "gray" then return end
    if mode == "bayer" then mode = "ordered_binary" end
    assert(mode == "ordered_binary" or mode == "stochastic_binary"
        or mode == "floyd_steinberg" or mode == "atkinson" or mode == "threshold",
        "Unsupported GIF software conversion: " .. tostring(mode))
    local w, h = bb:getWidth(), bb:getHeight()
    local data = ffi.cast("uint8_t*", bb.data)
    if mode == "floyd_steinberg" or mode == "atkinson" then
        local row_bytes = (w + 4) * ffi.sizeof("double")
        local current = ffi.new("double[?]", w + 4)
        local next_row = ffi.new("double[?]", w + 4)
        local after_next = ffi.new("double[?]", w + 4)
        for y = 0, h - 1 do
            for x = 0, w - 1 do
                local pos, epos = y * bb.stride + x, x + 2
                local v = tonumber(data[pos]) + current[epos]
                local output = v >= 127.5 and 255 or 0
                data[pos] = output
                local err = v - output
                if mode == "floyd_steinberg" then
                    err = err / 16
                    current[epos + 1] = current[epos + 1] + err * 7
                    next_row[epos - 1] = next_row[epos - 1] + err * 3
                    next_row[epos] = next_row[epos] + err * 5
                    next_row[epos + 1] = next_row[epos + 1] + err
                else
                    -- Atkinson distributes 6/8 of the quantization error.
                    err = err / 8
                    current[epos + 1] = current[epos + 1] + err
                    current[epos + 2] = current[epos + 2] + err
                    next_row[epos - 1] = next_row[epos - 1] + err
                    next_row[epos] = next_row[epos] + err
                    next_row[epos + 1] = next_row[epos + 1] + err
                    after_next[epos] = after_next[epos] + err
                end
            end
            if mode == "floyd_steinberg" then
                current, next_row = next_row, current
                ffi.fill(next_row, row_bytes, 0)
            else
                current, next_row, after_next = next_row, after_next, current
                ffi.fill(after_next, row_bytes, 0)
            end
        end
        return
    end
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local pos = y * bb.stride + x
            local v = tonumber(data[pos])
            local threshold = 128
            if mode == "ordered_binary" then
                threshold = (BAYER[(y % 4) * 4 + x % 4 + 1] + 0.5) * 16
            elseif mode == "stochastic_binary" then
                threshold = thresholdAt(x, y)
            end
            local white = mode == "ordered_binary" and v > threshold
                or mode ~= "ordered_binary" and v >= threshold
            data[pos] = (v == 255 or (v > 0 and white)) and 255 or 0
        end
    end
end

return Dither
