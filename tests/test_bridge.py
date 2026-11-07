from harness import *  # noqa: F401,F403
from harness import pump, srv, lua, TMP
import asyncio, json

async def pumper(stop):
    while not stop.is_set():
        pump(); await asyncio.sleep(0.02)

async def main():
    stop = asyncio.Event()
    t = asyncio.create_task(pumper(stop))
    await asyncio.sleep(0.1)
    print("status:", await srv.lightroom_status())
    lst = await srv.list_photos()
    print("list_photos:", lst["count"], [p["fileName"] for p in lst["photos"]])
    lf = await srv.list_folder_photos("sample trip", limit=10, sort="name")
    print("list_folder:", lf["folder"], lf["count"], [p["fileName"] for p in lf["photos"]])
    s = await srv.get_develop_settings(101)
    print("settings:", s["settings"])
    prev = await srv.preview_photo(101, size=800)
    print("preview:", type(prev[0]).__name__, len(prev[0].data), "bytes\n" + prev[1])
    r = await srv.apply_develop_settings([101, 102], {"Exposure2012": 9, "Highlights2012": -55, "ToneCurvePV2012": [0, 10, 128, 120, 255, 250]})
    print("apply:", json.dumps(r))
    prev2 = await srv.preview_photo(101, size=800)
    print("after edit:\n" + prev2[1])
    print("snapshot:", await srv.create_snapshot(101, "Before Claude"))
    print("select:", await srv.select_photos([101, 102]))
    print("revert:", await srv.revert_claude_edits(101))
    s2 = await srv.get_develop_settings(101, keys=["Exposure2012", "Highlights2012"])
    print("after revert:", s2)
    assert s2["settings"] == {"Exposure2012": 0, "Highlights2012": 0}
    try:
        await srv.get_develop_settings(999)
    except srv.LightroomError as e:
        print("error path OK:", e)
    # Restart: old loop must exit, new one handles requests
    lua.execute(open(PLUGIN / "MenuRestart.lua").read())
    await asyncio.sleep(0.2)
    alive = pump()
    print("loops alive after restart:", alive)
    assert alive == 1
    print("ping after restart:", (await srv.lightroom_status())["pong"])
    # Stop: server should report a helpful error
    lua.execute(open(PLUGIN / "Shutdown.lua").read())
    await asyncio.sleep(0.2)
    srv.HEARTBEAT_STALE_SECONDS = 0
    try:
        await asyncio.wait_for(srv.lightroom_status(), 30)
    except srv.LightroomError as e:
        print("stopped error OK:", e)
    stop.set(); await t
    left = [p.name for p in (TMP / ".claude-lightroom-bridge").rglob("*") if p.is_file()]
    print("files left in bridge dir:", left)

asyncio.run(main())
print("ALL TESTS PASSED")
