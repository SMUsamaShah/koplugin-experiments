-- KOReader's generated ffi/mxcfb_kindle_h.lua intentionally exports only the
-- constants its own framebuffer backend currently uses. A few older Kindle
-- ioctl macros that Motion Lab probes are present in the public kernel header
-- but are not emitted into that generated FFI declaration. Define those
-- numeric constants here when they are missing so ffi.C lookups in main.lua
-- work on current KOReader builds.
local ok_ffi, ffi = pcall(require, "ffi")
if ok_ffi then
    local C = ffi.C

    local function ensure_const(name, value)
        local exists = pcall(function()
            return C[name]
        end)
        if not exists then
            -- Match KOReader's generated FFI style. `unsigned` matters for
            -- ioctl values whose high bit is set (e.g. 0x80044639).
            pcall(ffi.cdef, string.format(
                "static const unsigned %s = %u;", name, value))
        end
    end

    -- Linux generic ioctl encoding for the Kindle mxcfb header:
    --   _IOW('F', 0x33/34/35, uint32_t)
    --   _IOR('F', 0x39, uint32_t)
    ensure_const("MXCFB_SET_PAUSE",         1074021939) -- 0x40044633
    ensure_const("MXCFB_GET_PAUSE",         1074021940) -- 0x40044634 (header uses _IOW)
    ensure_const("MXCFB_SET_RESUME",        1074021941) -- 0x40044635
    ensure_const("MXCFB_GET_WAVEFORM_TYPE", 2147763769) -- 0x80044639

    -- Return values documented by mxcfb-kindle.h.
    ensure_const("WAVEFORM_TYPE_4BIT", 1)
    ensure_const("WAVEFORM_TYPE_5BIT", 2)
end

local _ = require("gettext")
return {
    name = "einkmotionlab",
    fullname = _("E-Ink Motion / Grayscale Lab"),
    version = "0.1.5",
    description = _([[Animate a small Perlin-like grayscale field and compare KOReader and raw Kindle Rex E-Ink refresh paths, dithering, region sizes, and experimental GC16 pause/resume behavior.]]),
}
