"""Runs the Lua plugin against a mock Lightroom SDK (via lupa) and drives it with the
real MCP server functions. Usage: pip install lupa pillow "mcp>=2.3,<3"; python tests/test_bridge.py
"""
import asyncio, json, os, shutil, sys, time, tempfile
from pathlib import Path
import lupa.lua51 as lupa

TMP = Path(tempfile.mkdtemp())
os.environ["CLAUDE_LR_BRIDGE_DIR"] = str(TMP / ".claude-lightroom-bridge")
ROOT = Path(__file__).resolve().parents[1]
TESTS = Path(__file__).resolve().parent
PLUGIN = ROOT / "ClaudeEditor.lrplugin"
sys.path.insert(0, str(ROOT / "server"))

from PIL import Image as PILImage
import lightroom_mcp as srv

# ---- Lua runtime with mock SDK ----
lua = lupa.LuaRuntime(unpack_returned_tuples=True)
def listfiles(p):
    p = Path(p)
    return lua.table_from([str(x).replace("\\", "/") for x in p.iterdir() if x.is_file()]) if p.exists() else lua.table_from([])
def move(a, b):
    if Path(b).exists(): return False
    shutil.move(a, b); return True
def delete(p):
    p = Path(p)
    if p.is_dir(): shutil.rmtree(p)
    elif p.exists(): p.unlink()
    return True
def render(out, exposure, size):
    v = int(max(0, min(255, 110 + 60 * (exposure or 0))))
    PILImage.new("RGB", (int(size), int(size * 2 / 3)), (v + 10, v, v - 10)).save(out, "JPEG")
py = lua.table_from({"exists": lambda p: Path(p).exists(), "delete": delete, "move": move,
                     "mkdirs": lambda p: Path(p).mkdir(parents=True, exist_ok=True) or True,
                     "listfiles": listfiles, "now": time.time, "render": render})
lua.globals().PY = py
lua.globals().HOME = str(TMP)
lua.execute(f"package.path = '{PLUGIN.as_posix()}/?.lua;{TESTS.as_posix()}/?.lua;' .. package.path")
mock = lua.eval("require('mock_lr')")

# json round-trip tests
lj = lua.eval("require('json')")
for s in ['{"a":[1,2.5,-3e2],"b":"x\\n\\"y\\u00e9\\ud83d\\ude00","c":true,"d":null,"e":{}}', '[]', '"plain"', '1.5']:
    out = lj.encode(lj.decode(s))
    a, b = json.loads(s), json.loads(out)
    if isinstance(a, dict): a.pop("d", None); a["e"] = b.get("e")  # null dropped, {} -> []
    assert a == b or (a == {} and b == []), (s, out)
print("json.lua round-trips OK")
bad_ok, msg = lua.eval("function(s) return pcall(require('json').decode, s) end")('{"a":}')
assert not bad_ok; print("json.lua rejects bad input:", msg)

# start plugin (Init.lua)
lua.execute(open(PLUGIN / "Info.lua").read())
lua.execute(open(PLUGIN / "Init.lua").read())

lua.execute("""
function pumpAll()
  local alive = 0
  for _, co in ipairs(require('mock_lr').tasks) do
    if coroutine.status(co) ~= 'dead' then
      local ok, err = coroutine.resume(co)
      if not ok then error('task crashed: ' .. tostring(err)) end
      if coroutine.status(co) ~= 'dead' then alive = alive + 1 end
    end
  end
  return alive
end""")
pumpAll = lua.globals().pumpAll
def pump():
    return pumpAll()

