-- Inherit the noise test's refresh API, waveform and hardware-dither settings.
-- Rendering block sizes and test lengths belong to noise, not GIF playback.
local Modes = {}
local aliases = {
    a2 = "noise:KOReader A2 + SW Bayer binary dither",
    du = "noise:KOReader DU + SW Bayer binary dither",
    gray = "noise:KOReader UI/AUTO",
}

function Modes.build(noise_tests, raw_ok)
    local modes = {}
    for _, source in ipairs(noise_tests) do
        local spec = {}
        for k, v in pairs(source) do spec[k] = v end
        spec.id = "noise:" .. source.name
        spec.render_mode = source.render_mode or "gray"
        spec.burst = source.delay_ms == 0
        spec.frames, spec.block_size, spec.delay_ms = nil, nil, nil
        modes[#modes + 1] = spec
    end
    local extra = {
        { id = "du_stochastic", name = "KOReader DU + SW stochastic binary dither",
            api = "fast", render_mode = "stochastic_binary" },
        { id = "a2_sw_fs", name = "KOReader A2 + SW Floyd-Steinberg",
            api = "a2", render_mode = "floyd_steinberg" },
        { id = "du_sw_fs", name = "KOReader DU + SW Floyd-Steinberg",
            api = "fast", render_mode = "floyd_steinberg" },
        { id = "a2_sw_atkinson", name = "KOReader A2 + SW Atkinson",
            api = "a2", render_mode = "atkinson" },
        { id = "du_sw_atkinson", name = "KOReader DU + SW Atkinson",
            api = "fast", render_mode = "atkinson" },
        { id = "a2_threshold", name = "KOReader A2 + plain B/W threshold",
            api = "a2", render_mode = "threshold" },
        { id = "du_threshold", name = "KOReader DU + plain B/W threshold",
            api = "fast", render_mode = "threshold" },
    }
    if raw_ok then
        extra[#extra + 1] = {
            id = "raw_gc16_sync", name = "Raw GC16 synchronized grayscale",
            waveform = require("ffi").C.WAVEFORM_MODE_GC16,
            render_mode = "gray", wait_each = true,
        }
    end
    for _, spec in ipairs(extra) do modes[#modes + 1] = spec end
    return modes
end

function Modes.find(modes, id)
    id = aliases[id] or id
    local fallback
    for _, spec in ipairs(modes) do
        if spec.id == id then return spec end
        if spec.id == aliases.a2 then fallback = spec end
    end
    return assert(fallback or modes[1], "No GIF modes available.")
end

return Modes
