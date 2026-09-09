"""Run with Python + lupa (LuaJIT 2.1); no Kindle or display access required."""
from pathlib import Path
import random
import unittest
from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1] / "einkmotionlab.koplugin"


def runtime():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute("""
local ffi = require("ffi")
local function class(t)
    t = t or {}
    function t:extend(o)
        o = o or {}; setmetatable(o, {__index=self}); return class(o)
    end
    function t:new(o)
        o = o or {}; setmetatable(o, {__index=self})
        if o.init then o:init() end
        return o
    end
    return t
end
clock, driver, max_pending, restored, freed = 0, 0.001, 0, 0, 0
events, pending, completion, calls, logs = {}, {}, {}, {}, {}
UI = {
    show = function() end,
    close = function(self, w) if w.onCloseWidget then w:onCloseWidget() end end,
    setDirty = function() end,
    scheduleIn = function(self, delay, fn) events[#events+1] = {at=clock+delay, fn=fn} end,
    unschedule = function(self, fn)
        for i=#events,1,-1 do if events[i].fn==fn then table.remove(events,i) end end
    end,
}
function advance()
    if #events==0 then return false end
    table.sort(events, function(a,b) return a.at<b.at end)
    local e=table.remove(events,1)
    clock=math.max(clock,e.at); e.fn(); return true
end
function wait(marker)
    clock=math.max(clock,completion[marker] or clock)
    pending[marker]=nil; return 0
end
Screen = {marker=0,bb={
    getWidth=function() return 1072 end, getHeight=function() return 1448 end,
    copy=function() return {free=function() freed=freed+1 end} end,
    blitFrom=function() end,
}}
function submit(kind,...)
    if fail_refresh then error("injected refresh failure") end
    Screen.marker=Screen.marker+1
    pending[Screen.marker]=true
    completion[Screen.marker]=clock+driver
    local count=0;for _ in pairs(pending) do count=count+1 end
    max_pending=math.max(max_pending,count)
    calls[#calls+1]={kind=kind,args={...},at=clock}
    return Screen.marker
end
for _,kind in ipairs({"refreshA2","refreshFast","refreshUI","refreshPartial"}) do
    local selected=kind
    Screen[kind]=function(self,...) submit(selected,...) end
end
Screen.refreshWaitForLast=function() wait(Screen.marker) end
package.preload["device"]=function() return {screen=Screen} end
package.preload["ui/uimanager"]=function() return UI end
package.preload["ui/widget/container/inputcontainer"]=function() return class() end
package.preload["ui/widget/container/widgetcontainer"]=function() return class() end
package.preload["ui/geometry"]=function() return class() end
package.preload["ui/gesturerange"]=function() return class() end
package.preload["ui/widget/infomessage"]=function() return class() end
package.preload["ffi/blitbuffer"]=function() return {gray=function(v) return v end} end
package.preload["ffi/util"]=function() return {gettime=function()
    local s=math.floor(clock);return s,(clock-s)*1000000
end} end
for _,name in ipairs({"dispatcher","datastorage","logger"}) do
    package.preload[name]=function() return {} end
end
package.preload["gettext"]=function() return function(s) return s end end
package.preload["ffi/mxcfb_kindle_h"]=function()
    ffi.cdef[[
    static const int WAVEFORM_MODE_AUTO = 257;
    static const int WAVEFORM_MODE_GC16 = 2;
    static const int WAVEFORM_MODE_ZELDA_A2 = 6;
    static const int WAVEFORM_MODE_DU = 1;
    static const int EPDC_FLAG_USE_DITHERING_ORDERED = 3;
    static const int EPDC_FLAG_USE_DITHERING_FLOYD_STEINBERG = 1;
    static const int EPDC_FLAG_USE_DITHERING_ATKINSON = 2;
    ]]
    return true
end
settings={}
G_reader_settings={
    readSetting=function(self,k) return settings[k] end,
    saveSetting=function(self,k,v) settings[k]=v end,
}
function buffer(w,h)
    return {data=ffi.new("uint8_t[?]",w*h),stride=w,
        getWidth=function() return w end,getHeight=function() return h end}
end
function fillbuffer(bb,values)
    for i=1,#values do bb.data[i-1]=values[i] end
end
function readbuffer(bb)
    local out={};for i=0,bb.stride*bb:getHeight()-1 do out[#out+1]=tonumber(bb.data[i]) end
    return out
end
lab={ui={},patch_size=96,
    getPatchRect=function() return 0,0,96 end,
    cleanPatch=function() end,waitMarker=function(self,m) return wait(m) end,
    rawRexUpdate=function(self,wave,x,y,w,h,opts)
        if fail_raw then return nil,"injected raw failure" end
        return submit("raw",wave,x,y,w,h,opts)
    end,
    restorePatch=function() restored=restored+1 end,
    appendLog=function(self,lines) for _,s in ipairs(lines) do logs[#logs+1]=s end end,
    showInfo=function(self,s) report=s end,
    timingSummary=function() return "timings" end}
function animation()
    return {width=96,height=64,cache_bytes=18432,
        frames={{bb={},delay=.04},{bb={},delay=.08},{bb={},delay=.12}},
        free=function(self) self.frames={};freed=freed+1 end}
end
""")
    return lua


def load(lua, name):
    return lua.eval("dofile")(str(ROOT / name))


def finish(lua):
    for _ in range(1000):
        if not lua.globals().advance():
            return
    raise AssertionError("Unbounded playback callbacks")


def reference_diffusion(values, w, h, mode):
    errors = [0.0] * len(values)
    result = []
    kernel = ([(1,0,7),(-1,1,3),(0,1,5),(1,1,1)] if mode=="floyd_steinberg"
              else [(1,0,1),(2,0,1),(-1,1,1),(0,1,1),(1,1,1),(0,2,1)])
    divisor = 16 if mode=="floyd_steinberg" else 8
    for y in range(h):
        for x in range(w):
            i=y*w+x
            value=values[i]+errors[i]
            output=255 if value>=127.5 else 0
            result.append(output)
            err=(value-output)/divisor
            for dx,dy,weight in kernel:
                xx,yy=x+dx,y+dy
                if 0<=xx<w and yy<h:
                    errors[yy*w+xx]+=err*weight
    return result


class GifModesTests(unittest.TestCase):
    def test_catalog_parity_and_old_selections(self):
        for raw,expected in [(True,22),(False,14)]:
            lua=runtime()
            main=load(lua,"main.lua")
            main.raw_ok,main.bayer_block_size=raw,2
            noise=main.getVisualTests(main)
            modes=main.getGifModes(main)
            self.assertEqual(len(modes),expected)
            ids=[m.id for m in modes.values()]
            self.assertEqual(len(ids),len(set(ids)))
            for i in range(1,len(noise)+1):
                for key in ("api","waveform","dither_mode","quant_bit","flags","wait_each","dither"):
                    self.assertEqual(modes[i][key],noise[i][key],(i,key))
                self.assertEqual(modes[i].name,noise[i].name)
                self.assertEqual(modes[i].burst,noise[i].delay_ms==0)
                self.assertIsNone(modes[i].frames)
            for old,api,render in [("a2","a2","ordered_binary"),("du","fast","ordered_binary"),("gray","ui","gray")]:
                main.gif_mode=old
                selected=main.getGifMode(main)
                self.assertEqual((selected.api,selected.render_mode),(api,render))

    def test_all_refresh_routes(self):
        for index in range(1,23):
            lua=runtime()
            main=load(lua,"main.lua");main.raw_ok=True;main.bayer_block_size=2
            spec=main.getGifModes(main)[index]
            player=load(lua,"gifplayer.lua")
            options=lua.table_from(dict(path="test.gif",spec=spec,clock_mode="original",
                                       target_fps=20,queue_depth=2,loops=1,prepare_ms=0))
            widget=player.start(lua.globals().lab,lua.globals().animation(),options)
            finish(lua)
            self.assertTrue(widget.done,spec.name)
            self.assertEqual(widget.submitted+widget.skipped,3,spec.name)
            self.assertGreater(widget.submitted,0,spec.name)
            self.assertLessEqual(lua.globals().max_pending,1 if spec.wait_each else 2)
            self.assertEqual(lua.globals().freed,2,spec.name)
            call=lua.globals().calls[1]
            if spec.api:
                self.assertEqual(call.kind,{"a2":"refreshA2","fast":"refreshFast","ui":"refreshUI"}[spec.api])
                self.assertEqual(call.args[3],96)
                self.assertEqual(call.args[4],64)
            else:
                self.assertEqual(call.kind,"raw")
                self.assertEqual(call.args[1],spec.waveform)
                for k in ("dither_mode","quant_bit","flags","update_mode"):
                    self.assertEqual(call.args[6][k],spec[k],(spec.name,k))
            self.assertIn(spec.name,"\n".join(lua.globals().logs.values()))

    def test_clock_burst_and_slow_display(self):
        for burst in (False,True):
            lua=runtime();lua.globals().driver=.16
            spec=lua.table_from(dict(id="test",name="Test",api="a2",render_mode="gray",burst=burst))
            player=load(lua,"gifplayer.lua")
            options=lua.table_from(dict(path="test.gif",spec=spec,clock_mode="fixed",
                                       target_fps=20,queue_depth=1,loops=3,prepare_ms=0))
            widget=player.start(lua.globals().lab,lua.globals().animation(),options)
            finish(lua)
            self.assertEqual(widget.submitted+widget.skipped,9)
            self.assertEqual(lua.globals().max_pending,1)
            if burst:
                self.assertEqual(widget.skipped,0)
                self.assertEqual(widget.submitted,9)
            else:
                self.assertGreater(widget.skipped,0)

    def test_stop_and_raw_error_cleanup(self):
        for fail in (False,True):
            lua=runtime();lua.globals().fail_raw=fail
            spec=lua.table_from(dict(id="raw",name="Raw",waveform=6,render_mode="gray"))
            options=lua.table_from(dict(path="test.gif",spec=spec,clock_mode="original",
                                       target_fps=20,queue_depth=2,loops=1,prepare_ms=0))
            player=load(lua,"gifplayer.lua")
            widget=player.start(lua.globals().lab,lua.globals().animation(),options)
            lua.globals().advance()
            if not fail: widget.onStop(widget)
            self.assertFalse(lua.globals().advance())
            self.assertEqual(lua.globals().freed,2)
            self.assertEqual(lua.globals().restored,1)
            if fail: self.assertIn("injected raw failure",lua.globals().report)

    def test_synchronized_modes_keep_every_frame(self):
        for api in (None,"partial"):
            lua=runtime();lua.globals().driver=.3
            spec=lua.table_from(dict(id="sync",name="Sync",waveform=2,
                                    render_mode="gray",wait_each=True))
            if api: spec.api=api
            options=lua.table_from(dict(path="test.gif",spec=spec,clock_mode="original",
                                       target_fps=20,queue_depth=2,loops=1,prepare_ms=0))
            widget=load(lua,"gifplayer.lua").start(lua.globals().lab,lua.globals().animation(),options)
            finish(lua)
            self.assertEqual((widget.submitted,widget.skipped),(3,0))
            self.assertEqual(lua.globals().max_pending,1)
            self.assertGreater(lua.globals().clock,.9)
            self.assertEqual(lua.globals().calls[1].kind,"refreshPartial" if api else "raw")

    def test_diffusion_and_deterministic_masks(self):
        lua=runtime();dither=load(lua,"gifdither.lua")
        rng=random.Random(123)
        for w,h in [(1,1),(1,12),(12,1),(17,13)]:
            values=[rng.randrange(256) for _ in range(w*h)]
            for mode in ["floyd_steinberg","atkinson","ordered_binary","stochastic_binary","threshold","gray"]:
                bb=lua.globals().buffer(w,h)
                lua.globals().fillbuffer(bb,lua.table_from(values))
                dither.apply(bb,mode)
                actual=list(lua.globals().readbuffer(bb).values())
                if mode in ("floyd_steinberg","atkinson"):
                    self.assertEqual(actual,reference_diffusion(values,w,h,mode))
                elif mode=="gray":
                    self.assertEqual(actual,values)
                else:
                    self.assertTrue(set(actual)<= {0,255})
                lua.globals().fillbuffer(bb,lua.table_from(values))
                dither.apply(bb,mode)
                self.assertEqual(actual,list(lua.globals().readbuffer(bb).values()))
        for mode in ["floyd_steinberg","atkinson","ordered_binary","stochastic_binary","threshold"]:
            for value in (0,255):
                bb=lua.globals().buffer(11,9)
                lua.globals().fillbuffer(bb,lua.table_from([value]*99))
                dither.apply(bb,mode)
                self.assertEqual(list(lua.globals().readbuffer(bb).values()),[value]*99)


if __name__=="__main__":
    unittest.main(verbosity=2)
