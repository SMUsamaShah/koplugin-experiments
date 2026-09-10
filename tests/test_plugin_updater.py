"""Python + lupa (LuaJIT 2.1): real temporary files, mocked network/KOReader UI."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest

from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1] / "einkmotionlab.koplugin"
REVISION = "1" * 40
TREE = "2" * 40
API = "https://api.github.com/repos/owner/repo"


def blob(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


class UpdaterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.plugin = self.root / "sample.koplugin"
        self.plugin.mkdir()
        shutil.copy(ROOT / "pluginupdater.lua", self.plugin)
        (self.plugin / "main.lua").write_text("return {old=true}\n")
        (self.plugin / "_meta.lua").write_text("return {version='old'}\n")
        (self.plugin / "obsolete.txt").write_text("old data")
        self.before = self.snapshot(self.plugin)
        self.other = self.root / "other.koplugin"
        self.other.mkdir()
        (self.other / "keep.txt").write_text("do not touch")
        self.lua = LuaRuntime(unpack_returned_tuples=True, encoding=None)
        self.g = self.lua.globals()
        self.responses = {}
        self.requests = []
        self.g.py_response = self.response
        self.g.py_json = lambda data: self.table(json.loads(data))
        self.g.py_sha1 = lambda data: hashlib.sha1(data).hexdigest().encode()
        self.g.py_mode = self.mode
        self.g.py_dir = lambda p: self.table([".", ".."] + os.listdir(os.fsdecode(p)))
        self.g.py_mkdir = lambda p: self.fs_call(os.mkdir, p)
        self.g.py_rmdir = lambda p: self.fs_call(os.rmdir, p)
        self.g.py_makepath = lambda p: self.fs_call(lambda p: os.makedirs(p, exist_ok=True), p)
        self.lua.execute(b'''
messages, restart_messages, cert_names = {}, {}, {"api.github.com", "*.githubusercontent.com"}
package.preload["socket.http"] = function() return {request=function(req)
    assert(req.redirect == false)
    local conn = req.create()
    local ok, err = conn:connect(req.url:match("^https://([^/]+)/"), 443)
    if not ok then return nil, err end
    local data, code = py_response(req.url)
    if not data then return nil, code end
    for i=1,#data,11 do
        local accepted, sink_err = req.sink(data:sub(i,i+10))
        if not accepted then return nil, sink_err end
    end
    req.sink(nil)
    return 1, code
end} end
package.preload["ssl.https"] = function() return {tcp=function(options)
    assert(options.verify == "peer" and options.cafile == "data/ca-bundle.crt")
    return function() return {
        connect=function() if fail_tls then return nil,"certificate verify failed" end; return 1 end,
        close=function() tls_closed=true end,
        getpeercertificate=function() return {extensions=function()
            return {["2.5.29.17"]={dNSName=cert_names}} end} end,
    } end
end} end
package.preload["socketutil"] = function() return {
    block_timeout=7,total_timeout=11,USER_AGENT="updater-tests",
    set_timeout=function(self,b,t) self.block_timeout=b;self.total_timeout=t end,
    table_sink=function(chunks) return function(chunk)
        if chunk then chunks[#chunks+1]=chunk end; return 1 end end,
} end
package.preload["rapidjson"] = function() return {decode=py_json} end
package.preload["ffi/sha2"] = function() return {sha1=py_sha1} end
package.preload["libs/libkoreader-lfs"] = function() return {
    symlinkattributes=py_mode, mkdir=py_mkdir, rmdir=py_rmdir,
    dir=function(path) local names=py_dir(path);local i=0;return function()
        i=i+1;return names[i] end end,
} end
package.preload["util"] = function() return {makePath=py_makepath} end
package.preload["ffi/posix_h"] = function() require("ffi").cdef[[int chmod(const char*, unsigned int);]] end
package.preload["ui/network/manager"] = function() return {runWhenConnected=function(self,fn)
    wifi_called=true; if not cancel_wifi then fn() end end} end
package.preload["ui/trapper"] = function() return {
    wrap=function(self,fn) fn() end,
    dismissableRunInSubprocess=function(self,fn)
        if cancel_download then return false end
        if child_failed then return true end
        return true,fn()
    end,
} end
package.preload["ui/uimanager"] = function() return {
    show=function(self,w) messages[#messages+1]=w.text end,
    askForRestart=function(self,text) restart_messages[#restart_messages+1]=text end,
} end
package.preload["ui/widget/infomessage"] = function() return {new=function(self,o) return o end} end
local real_rename, real_open = os.rename, io.open
os.rename=function(src,dest)
    if fail_swap and src:match("%.update%-stage$") then return nil,"injected swap failure" end
    if fail_backup and dest:match("%.update%-backup$") then return nil,"injected backup failure" end
    if fail_restore and src:match("%.update%-backup$") then return nil,"injected restore failure" end
    return real_rename(src,dest)
end
io.open=function(path,mode)
    if fail_write and mode=="wb" then return {
        write=function() return nil,"injected disk full" end,close=function() return true end,
    } end
    if fail_close and mode=="wb" then return {
        write=function() return true end,close=function() return nil,"injected flush failure" end,
    } end
    return real_open(path,mode)
end
''')
        module = self.lua.eval(b"dofile")(os.fsencode(self.plugin / "pluginupdater.lua"))
        self.updater = module.new(self.table({"repository": "owner/repo", "branch": "main",
                                             "folder": "sample.koplugin"}))
        self.set_remote()

    def tearDown(self):
        self.temp.cleanup()

    def table(self, value):
        if isinstance(value, str):
            return value.encode()
        if isinstance(value, dict):
            return self.lua.table_from({self.table(k): self.table(v) for k, v in value.items()})
        if isinstance(value, list):
            return self.lua.table_from([self.table(v) for v in value])
        return value

    @staticmethod
    def mode(path, attribute):
        p = Path(os.fsdecode(path))
        if p.is_symlink():
            return b"link"
        return b"directory" if p.is_dir() else b"file" if p.is_file() else None

    @staticmethod
    def fs_call(fn, path):
        try:
            fn(os.fsdecode(path))
            return True
        except OSError as exc:
            return None, str(exc).encode()

    @staticmethod
    def snapshot(path):
        return {str(p.relative_to(path)): p.read_bytes() for p in path.rglob("*") if p.is_file()}

    def response(self, url):
        url = url.decode()
        self.requests.append(url)
        if url not in self.responses:
            raise AssertionError("Unexpected request: " + url)
        return self.responses[url]

    def set_remote(self, prefix="sample.koplugin/"):
        self.files = {"main.lua": b"return {new=true}\n", "_meta.lua": b"return {version='new'}\n",
                      "assets/dot gif.bin": b"GIF\x00\xff\x80", "helper.lua": b"return 42\n"}
        self.entries = [{"path": prefix + p, "type": "blob", "mode": "100644",
                         "size": len(d), "sha": blob(d)} for p, d in self.files.items()]
        if prefix:
            self.entries += [{"path": "other.koplugin/keep.txt", "type": "blob", "mode": "100644",
                              "size": 5, "sha": "9" * 40}]
        self.responses.clear()
        self.responses[API + "/commits/main"] = (json.dumps({"sha": REVISION,
            "commit": {"tree": {"sha": TREE}}}).encode(), 200)
        self.sync_tree()
        from urllib.parse import quote
        for path, data in self.files.items():
            url = f"https://raw.githubusercontent.com/owner/repo/{REVISION}/{quote(prefix+path)}"
            self.responses[url] = (data, 200)

    def sync_tree(self, truncated=False):
        self.responses[API + "/git/trees/" + TREE + "?recursive=1"] = (
            json.dumps({"tree": self.entries, "truncated": truncated}).encode(), 200)

    def run_update(self):
        self.updater.start(self.updater)
        self.assertFalse(self.updater.busy)

    def assert_original(self):
        self.assertEqual(self.snapshot(self.plugin), self.before)
        self.assertEqual((self.other / "keep.txt").read_text(), "do not touch")
        self.assertFalse(Path(str(self.plugin) + ".update-stage").exists())

    def test_success_replaces_only_plugin_keeps_backup_and_binary_assets(self):
        self.run_update()
        self.assertEqual(self.snapshot(self.plugin), self.files)
        self.assertEqual(self.snapshot(Path(str(self.plugin) + ".update-backup")), self.before)
        self.assertEqual((self.other / "keep.txt").read_text(), "do not touch")
        self.assertEqual(len(self.g.restart_messages), 1)
        self.assertEqual(len(self.g.messages), 0)
        self.assertTrue(self.g.wifi_called)
        self.assertFalse(any("other.koplugin" in p for p in self.requests))
        count = len(self.requests)
        self.run_update()  # Already installed in this session: ask for restart, don't download again.
        self.assertEqual(len(self.requests), count)
        self.assertEqual(len(self.g.restart_messages), 2)

    def test_root_repository_and_executable_file(self):
        self.updater.folder = b""
        self.set_remote(prefix="")
        self.entries[3]["mode"] = "100755"
        self.sync_tree()
        self.run_update()
        self.assertEqual(self.snapshot(self.plugin), self.files)
        self.assertTrue(os.stat(self.plugin / "helper.lua").st_mode & 0o100)

    def test_cancellation_and_child_crash_do_not_write_files(self):
        for flag in [b"cancel_wifi", b"cancel_download", b"child_failed"]:
            with self.subTest(flag=flag):
                self.g[flag] = True
                self.run_update()
                self.assert_original()
                self.assertEqual(len(self.g.restart_messages), 0)
                self.g[flag] = False

    def test_failed_or_corrupt_download_retains_original(self):
        raw = next(url for url in self.responses if "raw.githubusercontent" in url)
        original = self.responses[raw]
        for response in [(b"rate limited", 403), (None, b"timeout"), (b"bad", 200),
                         (b"x" * len(original[0]), 200)]:
            with self.subTest(response=response):
                self.responses[raw] = response
                self.run_update()
                self.assert_original()
        self.assertEqual(len(self.g.messages), 4)
        self.assertEqual(len(self.g.restart_messages), 0)
        self.lua.execute(b'assert(require("socketutil").block_timeout==7 and require("socketutil").total_timeout==11)')

    def test_invalid_manifests_and_lua_leave_original(self):
        good = [dict(e) for e in self.entries]
        cases = []
        for key, value in [("path", "sample.koplugin/../escape"), ("mode", "120000"),
                           ("type", "commit"), ("size", 9 * 1024 * 1024)]:
            entries = [dict(e) for e in good]
            entries[0][key] = value
            cases.append(entries)
        cases += [good[1:], good + [dict(good[0])]]
        for entries in cases:
            self.entries = entries
            self.sync_tree()
            self.run_update()
            self.assert_original()
        self.entries = good
        self.sync_tree(truncated=True)
        self.run_update()
        self.assert_original()
        invalid_lua = b"function broken(\n"
        self.entries[0].update(size=len(invalid_lua), sha=blob(invalid_lua))
        self.sync_tree()
        raw = next(url for url in self.responses if url.endswith("/main.lua"))
        self.responses[raw] = invalid_lua, 200
        self.run_update()
        self.assert_original()
        self.assertEqual(len(self.g.restart_messages), 0)

    def test_write_flush_backup_and_swap_failures_restore_old_folder(self):
        for flag in [b"fail_write", b"fail_close", b"fail_backup", b"fail_swap"]:
            with self.subTest(flag=flag):
                self.g[flag] = True
                self.run_update()
                self.assert_original()
                self.g[flag] = False
        self.assertEqual(len(self.g.messages), 4)

    def test_manifest_total_and_file_count_limits_before_asset_downloads(self):
        good = [dict(e) for e in self.entries]
        for count, size in [(513, 0), (5, 8 * 1024 * 1024)]:
            self.entries = good + [{"path": f"sample.koplugin/extra-{i}.bin", "type": "blob",
                                    "mode": "100644", "size": size, "sha": "9"*40}
                                   for i in range(count)]
            self.sync_tree()
            self.run_update()
            self.assert_original()
        self.assertFalse(any("raw.githubusercontent" in p for p in self.requests))

    def test_rollback_failure_retains_recoverable_backup(self):
        self.g.fail_swap, self.g.fail_restore = True, True
        self.run_update()
        backup = Path(str(self.plugin) + ".update-backup")
        self.assertEqual(self.snapshot(backup), self.before)
        self.assertIn(os.fsencode(backup), self.g.messages[1])
        self.assertEqual((self.other / "keep.txt").read_text(), "do not touch")

    def test_cleanup_does_not_follow_symlinks(self):
        stage = Path(str(self.plugin) + ".update-stage")
        backup = Path(str(self.plugin) + ".update-backup")
        stage.symlink_to(self.other, target_is_directory=True)
        backup.mkdir()
        (backup / "external").symlink_to(self.other, target_is_directory=True)
        self.run_update()
        self.assertEqual(self.snapshot(self.plugin), self.files)
        self.assertEqual((self.other / "keep.txt").read_text(), "do not touch")

    def test_tls_chain_and_hostname_fail_closed(self):
        self.g.fail_tls = True
        self.run_update()
        self.assert_original()
        self.g.fail_tls = False
        for names in [["wrong.example"], ["*github.com"], ["*.com"], ["api.github.com.evil.example"]]:
            self.g.cert_names = self.table(names)
            self.run_update()
            self.assert_original()
        self.assertEqual(len(self.requests), 0)
        self.assertTrue(self.g.tls_closed)

    def test_actual_menu_item_is_last_and_disabled_during_gif_playback(self):
        from test_gif_modes import runtime, load
        lua = runtime()
        main = load(lua, "main.lua")
        main.raw_ok = False
        items = lua.table()
        main.addToMainMenu(main, items)
        menu = items.einkmotionlab.sub_item_table
        last = menu[len(menu)]
        self.assertEqual(last.text, "update plugin")
        self.assertTrue(last.keep_menu_open)
        self.assertTrue(last.enabled_func())
        main._gif_player = lua.table()
        self.assertFalse(last.enabled_func())
        main._gif_player, main._gif_loading = None, True
        self.assertFalse(last.enabled_func())


if __name__ == "__main__":
    unittest.main()
