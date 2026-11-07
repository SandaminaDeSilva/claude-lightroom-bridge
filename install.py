"""
Installer for the Claude <-> Lightroom Classic bridge (Windows).

1. Installs the Python packages the server needs (mcp, pillow).
2. Registers the server in the Claude desktop app's config file
   (makes a backup of the existing config first).
"""
import glob
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SERVER = HERE / "server" / "lightroom_mcp.py"
REQUIREMENTS = HERE / "server" / "requirements.txt"
PLUGIN = HERE / "ClaudeEditor.lrplugin"
SERVER_NAME = "lightroom"


def step(msg):
    print(f"\n==> {msg}")


def config_paths():
    paths = []
    appdata = os.environ.get("APPDATA")
    if appdata:
        paths.append(Path(appdata) / "Claude" / "claude_desktop_config.json")
    local = os.environ.get("LOCALAPPDATA")
    if local:
        # Microsoft Store / MSIX installs keep a redirected copy of AppData.
        for pkg in glob.glob(os.path.join(local, "Packages", "Claude_*")):
            paths.append(Path(pkg) / "LocalCache" / "Roaming" / "Claude" / "claude_desktop_config.json")
    if sys.platform == "darwin":
        paths.append(Path.home() / "Library" / "Application Support" / "Claude" / "claude_desktop_config.json")
    return paths


def register(path: Path):
    config = {}
    if path.exists():
        raw = path.read_text(encoding="utf-8-sig").strip()
        if raw:
            try:
                config = json.loads(raw)
            except json.JSONDecodeError as e:
                print(f"   ! {path} isn't valid JSON ({e}); skipping it. Fix it and run again.")
                return False
        backup = path.with_name(f"claude_desktop_config.backup-{time.strftime('%Y%m%d-%H%M%S')}.json")
        shutil.copy2(path, backup)
        print(f"   backup saved: {backup.name}")
    else:
        path.parent.mkdir(parents=True, exist_ok=True)

    config.setdefault("mcpServers", {})[SERVER_NAME] = {
        "command": "py" if os.name == "nt" and shutil.which("py") else sys.executable,
        "args": (["-3"] if os.name == "nt" and shutil.which("py") else []) + [str(SERVER)],
    }
    path.write_text(json.dumps(config, indent=2), encoding="utf-8")
    print(f"   registered '{SERVER_NAME}' in {path}")
    return True


def main():
    print("Claude <-> Lightroom Classic bridge installer")
    print(f"Python: {sys.executable} ({sys.version.split()[0]})")
    if sys.version_info < (3, 10):
        print("! Python 3.10 or newer is needed. Get it from https://www.python.org/downloads/")
        return 1

    step("Installing Python packages (mcp, pillow)")
    r = subprocess.run([sys.executable, "-m", "pip", "install", "--upgrade", "-r", str(REQUIREMENTS)])
    if r.returncode != 0:
        print("! pip install failed. Check your internet connection and try again.")
        return 1

    step("Checking the server loads")
    r = subprocess.run([sys.executable, "-c",
                        "import importlib.util,sys;"
                        f"spec=importlib.util.spec_from_file_location('lr', r'{SERVER}');"
                        "m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);print('   ok')"])
    if r.returncode != 0:
        print("! The server failed to load; see the error above.")
        return 1

    step("Registering the server with the Claude desktop app")
    if os.name == "nt":
        running = subprocess.run(["tasklist", "/FI", "IMAGENAME eq claude.exe"], capture_output=True, text=True).stdout
        while "claude.exe" in running.lower():
            print("   ! Claude is running. It would overwrite this change when it quits.")
            input("     Quit Claude fully (system tray > Quit), then press Enter...")
            running = subprocess.run(["tasklist", "/FI", "IMAGENAME eq claude.exe"], capture_output=True, text=True).stdout
    done = [p for p in config_paths() if (p.parent.exists() or p == config_paths()[0]) and register(p)]
    if not done:
        print("! Couldn't find the Claude desktop config. In Claude: Settings > Developer > Edit Config,")
        print(f'  and add under "mcpServers": "{SERVER_NAME}": {{"command": "{sys.executable}", "args": ["{SERVER}"]}}')

    step("Next steps")
    print(f"  1. Lightroom Classic: File > Plug-in Manager > Add > choose\n     {PLUGIN}")
    print("  2. Fully quit the Claude desktop app (also from the system tray) and open it again.")
    print("  3. Ask Claude: 'check my Lightroom connection'.")
    return 0


if __name__ == "__main__":
    code = main()
    if os.name == "nt":
        input("\nPress Enter to close...")
    sys.exit(code)
