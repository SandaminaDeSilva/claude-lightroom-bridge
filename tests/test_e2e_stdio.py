"""Full stack: mock Lightroom (Lua plugin) in this process, real MCP server over stdio."""
import asyncio, sys, os
import harness as env  # sets up Lua + mock catalog
from mcp.client.stdio import stdio_client, StdioServerParameters
from mcp import ClientSession

async def main():
    stop = asyncio.Event()
    async def pumper():
        while not stop.is_set():
            env.pump(); await asyncio.sleep(0.02)
    t = asyncio.create_task(pumper())
    await asyncio.sleep(0.1)
    params = StdioServerParameters(command=sys.executable, args=[str(env.ROOT / "server" / "lightroom_mcp.py")],
                                   env={"CLAUDE_LR_BRIDGE_DIR": os.environ["CLAUDE_LR_BRIDGE_DIR"]})
    async with stdio_client(params) as (r, w):
        async with ClientSession(r, w) as s:
            await s.initialize()
            res = await s.call_tool("preview_photo", {"photo_id": 102, "size": 600})
            print("preview content types:", [c.type for c in res.content], "error:", res.is_error)
            print(res.content[1].text.splitlines()[1])
            res = await s.call_tool("apply_develop_settings", {"photo_ids": [102], "settings": {"IncrementalTemperature": 12, "Vibrance": 20}})
            print("apply:", res.is_error, res.content[0].text[:160])
    stop.set(); await t
asyncio.run(main())
