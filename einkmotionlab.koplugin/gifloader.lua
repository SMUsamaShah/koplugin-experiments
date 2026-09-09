-- Native GIF decoding and sequential compositing, then cached BB8 frames.
-- No decoding or per-pixel conversion runs during playback.
local ffi = require("ffi")
local bit = require("bit")
local BB = require("ffi/blitbuffer")
local module_dir = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local Dither = dofile(module_dir .. "gifdither.lua")
local Loader = {}
local MAX_FILE = 8 * 1024 * 1024
local MAX_RASTER = 32 * 1024 * 1024
local MAX_CACHE = 32 * 1024 * 1024

-- Bound allocations before DGifSlurp decompresses all indexed frames.
function Loader.inspect(path)
    local f, err = io.open(path, "rb")
    if not f then error("Cannot open GIF: " .. tostring(err)) end
    local data = f:read(MAX_FILE + 1)
    f:close()
    if #data > MAX_FILE then error("GIF exceeds 8 MiB. Choose a smaller GIF.") end
    local function byte(p)
        local b = data:byte(p)
        if not b then error("Truncated GIF.") end
        return b
    end
    local function word(p) return byte(p) + 256 * byte(p + 1) end
    local signature = data:sub(1, 6)
    if signature ~= "GIF87a" and signature ~= "GIF89a" then error("This is not a GIF file.") end
    local w, h = word(7), word(9)
    if w < 1 or h < 1 or w * h > 4 * 1024 * 1024 then
        error("GIF canvas is empty or exceeds 4 megapixels.")
    end
    local packed = byte(11)
    byte(13)
    local p = 14
    if bit.band(packed, 128) ~= 0 then p = p + 3 * 2 ^ (bit.band(packed, 7) + 1) end
    local count, raster = 0, 0
    local function blocks()
        while true do
            local n = byte(p)
            p = p + 1
            if n == 0 then return end
            byte(p + n - 1)
            p = p + n
        end
    end
    while true do
        local tag = byte(p)
        if tag == 0x3b then break end
        if tag == 0x21 then
            byte(p + 1)
            p = p + 2
            blocks()
        elseif tag == 0x2c then
            local x, y, fw, fh = word(p+1), word(p+3), word(p+5), word(p+7)
            packed = byte(p+9)
            if fw < 1 or fh < 1 or x + fw > w or y + fh > h then
                error("GIF frame lies outside its canvas.")
            end
            count, raster = count + 1, raster + fw * fh
            if count > 512 or raster > MAX_RASTER then
                error("GIF has too many or too-large frames. Use a shorter or smaller GIF.")
            end
            p = p + 10
            if bit.band(packed, 128) ~= 0 then p = p + 3 * 2 ^ (bit.band(packed, 7) + 1) end
            local code_size = byte(p)
            if code_size < 2 or code_size > 8 then error("Invalid GIF LZW code size.") end
            p = p + 1
            blocks()
        else
            error("Invalid GIF block.")
        end
    end
    if count == 0 then error("GIF contains no image frames.") end
    return { width = w, height = h, count = count }
end

function Loader.load(path, target_size, mode)
    local info = Loader.inspect(path)
    local scale = target_size / math.max(info.width, info.height)
    local width = math.max(1, math.floor(info.width * scale + 0.5))
    local height = math.max(1, math.floor(info.height * scale + 0.5))
    if width * height * info.count > MAX_CACHE then
        error("GIF frame cache exceeds 32 MiB. Reduce Patch size or use a shorter GIF.")
    end
    require("ffi/giflib_h")
    local giflib = ffi.loadlib("gif", "7")
    local err = ffi.new("int[1]")
    local gif = giflib.DGifOpenFileName(path, err)
    if gif == nil then error("GIF decoder could not open this file.") end
    local animation = { width = width, height = height, frames = {}, source = info,
        cache_bytes = width * height * info.count }
    function animation:free()
        for _, frame in ipairs(self.frames) do frame.bb:free() end
        self.frames = {}
    end
    local ok, failure = pcall(function()
        if giflib.DGifSlurp(gif) ~= ffi.C.GIF_OK then error("GIF decoding failed.") end
        if gif.SWidth ~= info.width or gif.SHeight ~= info.height or gif.ImageCount ~= info.count then
            error("GIF metadata changed while loading.")
        end
        local w, h = info.width, info.height
        local canvas = ffi.new("uint8_t[?]", w * h)
        local function gray(c)
            return math.floor((77 * c.Red + 150 * c.Green + 29 * c.Blue + 128) / 256)
        end
        local control = ffi.new("GraphicsControlBlock")
        local background = 255 -- Transparent GIFs are composited on white.
        local transparent_canvas = giflib.DGifSavedExtensionToGCB(gif, 0, control) == ffi.C.GIF_OK
            and control.TransparentColor >= 0
        if not transparent_canvas and gif.SColorMap ~= nil
            and gif.SBackGroundColor < gif.SColorMap.ColorCount then
            background = gray(gif.SColorMap.Colors[gif.SBackGroundColor])
        end
        ffi.fill(canvas, w * h, background)
        local xs = {}
        for x = 0, width - 1 do xs[x] = math.min(w - 1, math.floor(x * w / width)) end
        for i = 0, info.count - 1 do
            local saved = gif.SavedImages[i]
            local desc = saved.ImageDesc
            local disposal, transparent, delay = 0, -1, 0.1
            if giflib.DGifSavedExtensionToGCB(gif, i, control) == ffi.C.GIF_OK then
                disposal, transparent = tonumber(control.DisposalMode), tonumber(control.TransparentColor)
                if control.DelayTime > 0 then delay = math.max(0.02, control.DelayTime / 100) end
            end
            if disposal > 3 then error("Unsupported GIF disposal mode.") end
            local previous
            if disposal == 3 then
                previous = ffi.new("uint8_t[?]", w * h)
                ffi.copy(previous, canvas, w * h)
            end
            local cmap = desc.ColorMap ~= nil and desc.ColorMap or gif.SColorMap
            if cmap == nil or saved.RasterBits == nil then error("GIF frame has no palette or pixels.") end
            local palette = {}
            for c = 0, cmap.ColorCount - 1 do palette[c] = gray(cmap.Colors[c]) end
            local fw, fh, left, top = tonumber(desc.Width), tonumber(desc.Height),
                tonumber(desc.Left), tonumber(desc.Top)
            for y = 0, fh - 1 do
                for x = 0, fw - 1 do
                    local index = tonumber(saved.RasterBits[y * fw + x])
                    if index ~= transparent then
                        if palette[index] == nil then error("GIF pixel has an invalid palette index.") end
                        canvas[(top + y) * w + left + x] = palette[index]
                    end
                end
            end
            local bb = BB.new(width, height, BB.TYPE_BB8)
            animation.frames[#animation.frames + 1] = { bb = bb, delay = delay }
            local dest = ffi.cast("uint8_t*", bb.data)
            for y = 0, height - 1 do
                local sy = math.min(h - 1, math.floor(y * h / height))
                for x = 0, width - 1 do
                    local v = tonumber(canvas[sy * w + xs[x]])
                    dest[y * bb.stride + x] = v
                end
            end
            Dither.apply(bb, mode)
            -- Disposal applies AFTER displaying this frame, before the next.
            if disposal == 2 then
                for y = top, top + fh - 1 do ffi.fill(canvas + y * w + left, fw, background) end
            elseif disposal == 3 then
                ffi.copy(canvas, previous, w * h)
            end
        end
    end)
    local closed = giflib.DGifCloseFile(gif, err)
    if not ok or closed ~= ffi.C.GIF_OK then
        animation:free()
        error(ok and "GIF decoder could not close the file." or failure)
    end
    return animation
end

return Loader
