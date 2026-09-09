-- Private off-screen renderers: no device framebuffer or refresh calls.
-- Original math and paint loop copied from main.lua at 4be836858db88f9022521fbd14638bc4a1caa262.
-- The replacement hash changes the noise pattern; this is a timing comparison.
local Blitbuffer = require("ffi/blitbuffer")
local ffiUtil = require("ffi/util")
local bit = require("bit")
local Diagnostic = {}
local function now()
    local s, us = ffiUtil.gettime()
    return s + us / 1000000
end
local function makeOriginalRenderer(bb, size, block, mode)
local Screen = { bb = bb }
local MotionLab = {}
local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function smooth(t)
    return t * t * (3 - 2 * t)
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

-- Fast deterministic integer hash; good enough for visual value noise.
local function hash2(ix, iy, seed)
    local n = (ix * 73856093 + iy * 19349663 + seed * 83492791) % 2147483647
    n = (n * 48271 + 1) % 2147483647
    return n / 2147483647
end

local function valueNoise(x, y, seed)
    local x0 = math.floor(x)
    local y0 = math.floor(y)
    local tx = smooth(x - x0)
    local ty = smooth(y - y0)

    local a = hash2(x0,     y0,     seed)
    local b = hash2(x0 + 1, y0,     seed)
    local c = hash2(x0,     y0 + 1, seed)
    local d = hash2(x0 + 1, y0 + 1, seed)

    return lerp(lerp(a, b, tx), lerp(c, d, tx), ty)
end

local function fractalNoise(x, y)
    return valueNoise(x, y, 11) * 0.55
        + valueNoise(x * 2.03, y * 2.03, 29) * 0.30
        + valueNoise(x * 4.07, y * 4.07, 53) * 0.15
end


local GRAYS = {}
for i = 0, 31 do
    -- Blitbuffer.gray() uses 0 = white, 1 = black.
    GRAYS[i] = Blitbuffer.gray(i / 31)
end

local WHITE = Blitbuffer.gray(0)
local BLACK = Blitbuffer.gray(1)

-- 4x4 Bayer threshold matrix.  With a 2 px render block this produces
-- very fine black/white texture on a 300 dpi PW4 while keeping Lua-side
-- rendering cheap enough to animate.
local BAYER4 = {
     0,  8,  2, 10,
    12,  4, 14,  6,
     3, 11,  1,  9,
    15,  7, 13,  5,
}


function MotionLab:paintNoise(x, y, size, phase, block, render_mode)
    block = math.max(1, block or self.block_size)
    render_mode = render_mode or "gray"
    local scale = 3.15
    local drift_x = phase * 0.43
    local drift_y = phase * 0.27

    local yy = 0
    local cy = 0
    while yy < size do
        local bh = math.min(block, size - yy)
        local xx = 0
        local cx = 0
        while xx < size do
            local bw = math.min(block, size - xx)
            local nx = (xx + bw * 0.5) / size * scale + drift_x
            local ny = (yy + bh * 0.5) / size * scale + drift_y
            local v = fractalNoise(nx, ny)

            -- Keep some headroom from absolute white/black so subtle motion
            -- remains visible even on aggressive waveforms.
            v = clamp(0.05 + v * 0.90, 0, 1)

            local color
            if render_mode == "ordered_binary" then
                local bi = (cy % 4) * 4 + (cx % 4) + 1
                local threshold = (BAYER4[bi] + 0.5) / 16
                color = v >= threshold and BLACK or WHITE
            elseif render_mode == "stochastic_binary" then
                -- Static per-cell threshold: noise moves through the pattern,
                -- but the dither mask itself does not sparkle frame-to-frame.
                local threshold = hash2(cx, cy, 97)
                color = v >= threshold and BLACK or WHITE
            else
                local gi = math.floor(v * 31 + 0.5)
                color = GRAYS[gi]
            end

            Screen.bb:paintRect(x + xx, y + yy, bw, bh, color)
            xx = xx + block
            cx = cx + 1
        end
        yy = yy + block
        cy = cy + 1
    end
end


return function(frame)
    MotionLab:paintNoise(0, 0, size, (frame - 1) * 0.19, block, mode)
end
end
local function makeBoundedRenderer(bb, size, block, mode)
local Screen = { bb = bb }
local MotionLab = {}
local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function smooth(t)
    return t * t * (3 - 2 * t)
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

-- Fast deterministic integer hash; good enough for visual value noise.
local function hash2(ix, iy, seed)
    -- Integer mixing through bit operations; no growing large products.
    local h = bit.bxor(bit.tobit(ix), bit.rol(bit.tobit(iy), 16),
        bit.rol(bit.tobit(seed), 8), 0x9e3779b9)
    h = bit.bxor(h, bit.lshift(h, 13))
    h = bit.bxor(h, bit.rshift(h, 17))
    h = bit.bxor(h, bit.lshift(h, 5))
    h = bit.tobit(h + bit.lshift(h, 10))
    h = bit.bxor(h, bit.rshift(h, 6))
    h = bit.tobit(h + bit.lshift(h, 3))
    h = bit.bxor(h, bit.rshift(h, 11))
    h = bit.tobit(h + bit.lshift(h, 15))
    return bit.band(h, 0x7fffffff) / 2147483647
end

local function valueNoise(x, y, seed)
    local x0 = math.floor(x)
    local y0 = math.floor(y)
    local tx = smooth(x - x0)
    local ty = smooth(y - y0)

    local a = hash2(x0,     y0,     seed)
    local b = hash2(x0 + 1, y0,     seed)
    local c = hash2(x0,     y0 + 1, seed)
    local d = hash2(x0 + 1, y0 + 1, seed)

    return lerp(lerp(a, b, tx), lerp(c, d, tx), ty)
end

local function fractalNoise(x, y)
    return valueNoise(x, y, 11) * 0.55
        + valueNoise(x * 2.03, y * 2.03, 29) * 0.30
        + valueNoise(x * 4.07, y * 4.07, 53) * 0.15
end


local GRAYS = {}
for i = 0, 31 do
    -- Blitbuffer.gray() uses 0 = white, 1 = black.
    GRAYS[i] = Blitbuffer.gray(i / 31)
end

local WHITE = Blitbuffer.gray(0)
local BLACK = Blitbuffer.gray(1)

-- 4x4 Bayer threshold matrix.  With a 2 px render block this produces
-- very fine black/white texture on a 300 dpi PW4 while keeping Lua-side
-- rendering cheap enough to animate.
local BAYER4 = {
     0,  8,  2, 10,
    12,  4, 14,  6,
     3, 11,  1,  9,
    15,  7, 13,  5,
}


function MotionLab:paintNoise(x, y, size, phase, block, render_mode)
    block = math.max(1, block or self.block_size)
    render_mode = render_mode or "gray"
    local scale = 3.15
    local drift_x = phase * 0.43
    local drift_y = phase * 0.27

    local yy = 0
    local cy = 0
    while yy < size do
        local bh = math.min(block, size - yy)
        local xx = 0
        local cx = 0
        while xx < size do
            local bw = math.min(block, size - xx)
            local nx = (xx + bw * 0.5) / size * scale + drift_x
            local ny = (yy + bh * 0.5) / size * scale + drift_y
            local v = fractalNoise(nx, ny)

            -- Keep some headroom from absolute white/black so subtle motion
            -- remains visible even on aggressive waveforms.
            v = clamp(0.05 + v * 0.90, 0, 1)

            local color
            if render_mode == "ordered_binary" then
                local bi = (cy % 4) * 4 + (cx % 4) + 1
                local threshold = (BAYER4[bi] + 0.5) / 16
                color = v >= threshold and BLACK or WHITE
            elseif render_mode == "stochastic_binary" then
                -- Static per-cell threshold: noise moves through the pattern,
                -- but the dither mask itself does not sparkle frame-to-frame.
                local threshold = hash2(cx, cy, 97)
                color = v >= threshold and BLACK or WHITE
            else
                local gi = math.floor(v * 31 + 0.5)
                color = GRAYS[gi]
            end

            Screen.bb:paintRect(x + xx, y + yy, bw, bh, color)
            xx = xx + block
            cx = cx + 1
        end
        yy = yy + block
        cy = cy + 1
    end
end


return function(frame)
    MotionLab:paintNoise(0, 0, size, (frame - 1) * 0.19, block, mode)
end
end

function Diagnostic.run(lab)
    local lines = {
        "================================================================",
        "RENDER DIAGNOSTIC " .. os.date("%Y-%m-%d %H:%M:%S"),
        "plugin_version=0.1.11",
        "offscreen=true; refresh_calls=0; private_renderers=true",
        "Each position rendered 3 times; wall and process CPU time reported.",
        "Replacement hash changes the noise pattern, not just its execution.",
    }
    local jit_ok, jitlib = pcall(require, "jit")
    lines[#lines + 1] = "jit_version=" .. (jit_ok and jitlib.version or "unavailable")
    lines[#lines + 1] = "jit_enabled=" .. tostring(jit_ok and jitlib.status())
    lines[#lines + 1] = "SYSTEM START " .. lab:systemStateText(lab:readSystemState())
    lab:appendLog(lines)
    local report = { "Renderer diagnostic complete." }
    -- Fixed workload independent of the user's scheduler and menu settings.
    local cases = {
        { name = "gray", block = 8 },
        { name = "ordered_binary", block = 2 },
    }
    local positions = { 1, 40, 60, 90, 120, 1, 120, 1 }
    for _, case in ipairs(cases) do
        for _, variant in ipairs({
            { name = "original", make = makeOriginalRenderer },
            { name = "bounded_bit_hash", make = makeBoundedRenderer },
        }) do
            local bb = Blitbuffer.new(512, 512, Blitbuffer.TYPE_BB8)
            local results = {}
            local ok, err = pcall(function()
                local render = variant.make(bb, 512, case.block, case.name)
                local memory_start = collectgarbage("count")
                -- A small, explicit warmup at the early position.
                render(1)
                render(1)
                for visit, frame in ipairs(positions) do
                    local t0 = now()
                    local c0 = os.clock()
                    for repeat_index = 1, 3 do render(frame) end
                    local cpu_ms = (os.clock() - c0) * 1000 / 3
                    local wall_ms = (now() - t0) * 1000 / 3
                    results[#results + 1] = {
                        frame = frame, wall_ms = wall_ms, cpu_ms = cpu_ms,
                        state = lab:telemetryStateText(lab:readTelemetryState()),
                    }
                end
                lines = {
                    "-- OFFSCREEN CASE --",
                    "render_mode=" .. case.name,
                    "hash=" .. variant.name,
                    "size=512; block=" .. case.block .. "; repeats_per_position=3; warmup_frames=2",
                    string.format("lua_kb_start=%.1f; lua_kb_end=%.1f",
                        memory_start, collectgarbage("count")),
                }
                for visit, r in ipairs(results) do
                    lines[#lines + 1] = string.format(
                        "visit=%d logical=%d wall=%.2fms cpu=%.2fms | %s",
                        visit, r.frame, r.wall_ms, r.cpu_ms, r.state)
                end
                lab:appendLog(lines)
            end)
            bb:free()
            if not ok then
                lab:appendLog({ "DIAGNOSTIC ERROR " .. tostring(err) })
                error(err)
            end
            report[#report + 1] = string.format(
                "%s / %s: frame 1 %.1f ms, frame 120 %.1f ms, back to 1 %.1f ms",
                case.name, variant.name, results[1].wall_ms,
                results[5].wall_ms, results[6].wall_ms)
        end
    end
    lab:appendLog({
        "-- RENDER DIAGNOSTIC END --",
        lab:systemStateText(lab:readSystemState()),
    })
    report[#report + 1] = ""
    report[#report + 1] = "Send einkmotionlab.log. Normal animations now use bounded_bit_hash."
    report[#report + 1] = lab.log_path
    return table.concat(report, "\n")
end

return Diagnostic
