"""
Lightroom Classic MCP server.

Lets Claude see and edit photos in Lightroom Classic through the
"Claude Editor Bridge" plugin. The plugin and this server talk through a
small file queue in  ~/.claude-lightroom-bridge/ :

    requests/<id>.json   written here, picked up by the plugin
    responses/<id>.json  written by the plugin, read here
    previews/            JPEG renders made by the plugin
    heartbeat.json       updated by the plugin every 2 s while it runs
    backups/<id>.json    develop settings saved before Claude's first edit

Run by the Claude desktop app (see install.py). Requires: mcp>=2, pillow.
"""

from __future__ import annotations

import asyncio
import io
import json
import os
import re
import sys
import time
import uuid
from pathlib import Path
from typing import Any

from mcp.server.mcpserver import Image, MCPServer
from mcp.server.mcpserver.exceptions import ToolError

BRIDGE_DIR = Path(os.environ.get("CLAUDE_LR_BRIDGE_DIR", Path.home() / ".claude-lightroom-bridge"))
REQUESTS = BRIDGE_DIR / "requests"
RESPONSES = BRIDGE_DIR / "responses"
PREVIEWS = BRIDGE_DIR / "previews"
BACKUPS = BRIDGE_DIR / "backups"
HEARTBEAT = BRIDGE_DIR / "heartbeat.json"
OWNER = BRIDGE_DIR / "owner.txt"

HEARTBEAT_STALE_SECONDS = 15

# Valid ranges for the develop settings Claude normally uses (process version 2012+).
RANGES: dict[str, tuple[float, float]] = {
    # Basic
    "Exposure2012": (-5, 5),
    "Contrast2012": (-100, 100),
    "Highlights2012": (-100, 100),
    "Shadows2012": (-100, 100),
    "Whites2012": (-100, 100),
    "Blacks2012": (-100, 100),
    "Texture": (-100, 100),
    "Clarity2012": (-100, 100),
    "Dehaze": (-100, 100),
    "Vibrance": (-100, 100),
    "Saturation": (-100, 100),
    # White balance: Kelvin for raw, incremental for JPEG/HEIC/TIFF
    "Temperature": (2000, 50000),
    "Tint": (-150, 150),
    "IncrementalTemperature": (-100, 100),
    "IncrementalTint": (-100, 100),
    # Parametric tone curve
    "ParametricShadows": (-100, 100),
    "ParametricDarks": (-100, 100),
    "ParametricLights": (-100, 100),
    "ParametricHighlights": (-100, 100),
    "ParametricShadowSplit": (10, 70),
    "ParametricMidtoneSplit": (20, 80),
    "ParametricHighlightSplit": (30, 90),
    # Color grading
    "SplitToningShadowHue": (0, 360),
    "SplitToningShadowSaturation": (0, 100),
    "SplitToningHighlightHue": (0, 360),
    "SplitToningHighlightSaturation": (0, 100),
    "SplitToningBalance": (-100, 100),
    "ColorGradeMidtoneHue": (0, 360),
    "ColorGradeMidtoneSat": (0, 100),
    "ColorGradeGlobalHue": (0, 360),
    "ColorGradeGlobalSat": (0, 100),
    "ColorGradeShadowLum": (-100, 100),
    "ColorGradeMidtoneLum": (-100, 100),
    "ColorGradeHighlightLum": (-100, 100),
    "ColorGradeGlobalLum": (-100, 100),
    "ColorGradeBlending": (0, 100),
    # Detail
    "Sharpness": (0, 150),
    "SharpenRadius": (0.5, 3),
    "SharpenDetail": (0, 100),
    "SharpenEdgeMasking": (0, 100),
    "LuminanceSmoothing": (0, 100),
    "LuminanceNoiseReductionDetail": (0, 100),
    "LuminanceNoiseReductionContrast": (0, 100),
    "ColorNoiseReduction": (0, 100),
    "ColorNoiseReductionDetail": (0, 100),
    "ColorNoiseReductionSmoothness": (0, 100),
    # Effects
    "PostCropVignetteAmount": (-100, 100),
    "PostCropVignetteMidpoint": (0, 100),
    "PostCropVignetteRoundness": (-100, 100),
    "PostCropVignetteFeather": (0, 100),
    "PostCropVignetteHighlightContrast": (0, 100),
    "GrainAmount": (0, 100),
    "GrainSize": (0, 100),
    "GrainFrequency": (0, 100),
    # Crop / straighten (crop edges are 0..1 fractions of the image)
    "CropAngle": (-45, 45),
    "CropTop": (0, 1),
    "CropLeft": (0, 1),
    "CropBottom": (0, 1),
    "CropRight": (0, 1),
    # Lens / transform
    "LensProfileDistortionScale": (0, 200),
    "LensProfileVignettingScale": (0, 200),
    "PerspectiveVertical": (-100, 100),
    "PerspectiveHorizontal": (-100, 100),
    "PerspectiveRotate": (-10, 10),
    "PerspectiveScale": (50, 150),
    "PerspectiveAspect": (-100, 100),
}
for _color in ("Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"):
    for _kind in ("HueAdjustment", "SaturationAdjustment", "LuminanceAdjustment"):
        RANGES[f"{_kind}{_color}"] = (-100, 100)

# Non-range keys that are still useful to see when editing.
EXTRA_EDIT_KEYS = [
    "ProcessVersion", "CameraProfile", "WhiteBalance", "ConvertToGrayscale",
    "ToneCurveName2012", "ToneCurvePV2012", "ToneCurvePV2012Red",
    "ToneCurvePV2012Green", "ToneCurvePV2012Blue", "HasCrop", "CropConstrainToWarp",
    "LensProfileEnable", "AutoLateralCA", "EnableColorAdjustments", "EnableDetail",
    "EnableEffects", "EnableSplitToning", "EnableGrayscaleMix", "EnableToneCurve",
    "EnableLensCorrections", "UprightVersion", "UprightTransform",
]

RAW_FORMATS = {"RAW", "DNG"}

mcp = MCPServer(
    "lightroom",
    instructions=(
        "Tools for editing photos in the user's Lightroom Classic. Typical flow: "
        "list_photos -> preview_photo (look + read the analysis) -> "
        "apply_develop_settings -> preview_photo again to check -> refine. "
        "Edits are non-destructive and revert_claude_edits restores the original settings."
    ),
)


class LightroomError(ToolError):
    """Expected failures; the message is shown to Claude."""


# ---------------------------------------------------------------------------
# Bridge plumbing
# ---------------------------------------------------------------------------

def _read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def _heartbeat_age() -> float | None:
    # The plugin replaces heartbeat.json every 2 s, so it can be briefly missing.
    for _ in range(5):
        try:
            beat = _read_json(HEARTBEAT)
            return time.time() - float(beat.get("time", 0))
        except Exception:
            time.sleep(0.15)
    return None


async def _ensure_alive() -> None:
    age = _heartbeat_age()
    if age is None:
        raise LightroomError(
            "Lightroom bridge not found. Open Lightroom Classic and make sure the "
            "'Claude Editor Bridge' plugin is installed and enabled (File > Plug-in Manager)."
        )
    if age <= HEARTBEAT_STALE_SECONDS:
        return
    # Lightroom may just be busy (e.g. rendering); give it a moment.
    for _ in range(20):
        await asyncio.sleep(0.5)
        age = _heartbeat_age()
        if age is not None and age <= HEARTBEAT_STALE_SECONDS:
            return
    owner = OWNER.read_text(encoding="utf-8").strip() if OWNER.exists() else ""
    hint = (
        "The bridge was stopped; use Library > Plug-in Extras > Claude Bridge: Restart."
        if owner == "stopped"
        else "Lightroom Classic seems closed, or the plugin is not running. Open Lightroom, "
        "then use Library > Plug-in Extras > Claude Bridge: Restart."
    )
    raise LightroomError(f"No heartbeat from Lightroom for {int(age or 0)} s. {hint}")


async def call_lightroom(command: str, params: dict | None = None, timeout: float = 60) -> Any:
    await _ensure_alive()
    for d in (REQUESTS, RESPONSES, PREVIEWS):
        d.mkdir(parents=True, exist_ok=True)

    req_id = uuid.uuid4().hex
    payload = json.dumps({"id": req_id, "command": command, "params": params or {}})
    tmp = REQUESTS / f"{req_id}.tmp"
    tmp.write_text(payload, encoding="utf-8")
    os.replace(tmp, REQUESTS / f"{req_id}.json")

    resp_path = RESPONSES / f"{req_id}.json"
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if resp_path.exists():
            try:
                resp = _read_json(resp_path)
            except (json.JSONDecodeError, OSError):
                await asyncio.sleep(0.1)
                continue
            try:
                resp_path.unlink()
            except OSError:
                pass
            if not resp.get("ok"):
                msg = re.sub(r"^.*?\.lua:\d+: ", "", str(resp.get("error", "unknown error")))
                raise LightroomError(f"Lightroom: {msg}")
            return resp.get("result")
        await asyncio.sleep(0.1)

    # Clean up a request the plugin never picked up.
    try:
        (REQUESTS / f"{req_id}.json").unlink()
    except OSError:
        pass
    raise LightroomError(
        f"Lightroom didn't answer '{command}' within {int(timeout)} s. It may be busy "
        "or showing a dialog; check the Lightroom window."
    )


def _clean_old_files() -> None:
    cutoff = time.time() - 24 * 3600
    for d in (PREVIEWS, RESPONSES, REQUESTS):
        if not d.exists():
            continue
        for p in d.iterdir():
            try:
                if p.is_file() and p.stat().st_mtime < cutoff:
                    p.unlink()
            except OSError:
                pass


# ---------------------------------------------------------------------------
# Settings helpers
# ---------------------------------------------------------------------------

def _clamp_settings(settings: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    clean: dict[str, Any] = {}
    notes: list[str] = []
    for key, value in settings.items():
        if key in RANGES and isinstance(value, (int, float)) and not isinstance(value, bool):
            lo, hi = RANGES[key]
            clamped = max(lo, min(hi, value))
            if clamped != value:
                notes.append(f"{key}: {value} clamped to {clamped}")
            clean[key] = clamped
        else:
            clean[key] = value
    return clean, notes


def _edit_subset(settings: dict[str, Any]) -> dict[str, Any]:
    keys = list(RANGES) + EXTRA_EDIT_KEYS
    return {k: settings[k] for k in keys if k in settings}


def _backup_path(photo_id: int) -> Path:
    return BACKUPS / f"{int(photo_id)}.json"


async def _backup_once(photo_id: int) -> bool:
    """Save the photo's full settings the first time Claude edits it."""
    path = _backup_path(photo_id)
    if path.exists():
        return False
    BACKUPS.mkdir(parents=True, exist_ok=True)
    result = await call_lightroom("get_settings", {"photo_id": photo_id})
    path.write_text(json.dumps(result["settings"], indent=1), encoding="utf-8")
    return True


# ---------------------------------------------------------------------------
# Image analysis
# ---------------------------------------------------------------------------

def _analyze(jpeg: bytes) -> str:
    try:
        from PIL import Image as PILImage, ImageStat
    except ImportError:
        return "(Install Pillow for exposure/colour analysis: pip install pillow)"

    img = PILImage.open(io.BytesIO(jpeg)).convert("RGB")
    img.thumbnail((800, 800))
    lum = img.convert("L")
    hist = lum.histogram()
    total = sum(hist)

    def pct(lo: int, hi: int) -> float:
        return 100 * sum(hist[lo:hi + 1]) / total

    def percentile(p: float) -> int:
        target, acc = total * p, 0
        for i, c in enumerate(hist):
            acc += c
            if acc >= target:
                return i
        return 255

    # Colour cast: average RGB over mid-tone pixels only.
    mask = lum.point(lambda v: 255 if 40 <= v <= 215 else 0)
    stat = ImageStat.Stat(img, mask)
    r, g, b = stat.mean if stat.count[0] else (0, 0, 0)
    avg = (r + g + b) / 3 or 1
    hsv = img.convert("HSV")
    sat_mean = ImageStat.Stat(hsv).mean[1] / 255 * 100

    zones = [pct(0, 50), pct(51, 102), pct(103, 153), pct(154, 204), pct(205, 255)]
    cast = []
    if (r - b) / avg > 0.08:
        cast.append("warm (R>B)")
    elif (b - r) / avg > 0.08:
        cast.append("cool (B>R)")
    if (g - (r + b) / 2) / avg > 0.05:
        cast.append("green tint")
    elif ((r + b) / 2 - g) / avg > 0.05:
        cast.append("magenta tint")

    return "\n".join([
        f"Size: {img.width}x{img.height} (analysis copy)",
        f"Luminance: mean {ImageStat.Stat(lum).mean[0]:.0f}/255, "
        f"p1 {percentile(0.01)}, median {percentile(0.5)}, p99 {percentile(0.99)}",
        f"Clipping: shadows (<=2) {pct(0, 2):.2f}%, highlights (>=253) {pct(253, 255):.2f}%",
        "Tonal zones (blacks/shadows/mids/lights/whites): "
        + " / ".join(f"{z:.0f}%" for z in zones),
        (f"Mid-tone mean RGB: {r:.0f}, {g:.0f}, {b:.0f} -> {', '.join(cast) if cast else 'neutral'}"
         if stat.count[0] else "Mid-tone colour: n/a (almost no mid-tones)"),
        f"Mean saturation: {sat_mean:.0f}%",
    ])


# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------

@mcp.tool()
async def lightroom_status() -> dict:
    """Check that Lightroom Classic and the Claude Editor Bridge plugin are running."""
    result = await call_lightroom("ping", timeout=15)
    age = _heartbeat_age()
    result["heartbeat_age_seconds"] = round(age, 1) if age is not None else None
    result["bridge_dir"] = str(BRIDGE_DIR)
    return result


@mcp.tool()
async def list_photos(scope: str = "selected", limit: int = 50) -> dict:
    """List photos in Lightroom with their ids and camera info.

    scope: "selected" = the photos selected in Lightroom (or every photo in the
    filmstrip when nothing is selected); "active" = only the main selected photo.
    """
    return await call_lightroom("list_photos", {"scope": scope, "limit": limit})


@mcp.tool()
async def list_folder_photos(
    folder: str, offset: int = 0, limit: int = 50, sort: str = "capture", include_subfolders: bool = False
) -> dict:
    """List photos in a Lightroom catalog folder by folder name (or full path), without
    the user having to select them. sort: "capture" (capture time, default) or "name".
    Use offset/limit to page, e.g. the first 10 photos = offset 0, limit 10.
    """
    return await call_lightroom(
        "list_folder",
        {"folder": folder, "offset": offset, "limit": limit, "sort": sort,
         "include_subfolders": include_subfolders},
    )


@mcp.tool()
async def get_develop_settings(photo_id: int, detail: str = "edit", keys: list[str] | None = None) -> dict:
    """Read a photo's current develop settings.

    detail: "edit" (default) = the sliders that matter for editing; "all" = every setting.
    keys: optional list of exact setting names to return instead.
    """
    params: dict[str, Any] = {"photo_id": photo_id}
    if keys:
        params["keys"] = keys
    result = await call_lightroom("get_settings", params)
    if not keys and detail != "all":
        result["settings"] = _edit_subset(result["settings"])
    return result


@mcp.tool(structured_output=False)
async def preview_photo(photo_id: int, size: int = 1600, analyze: bool = True) -> list:
    """Render the photo as it currently looks in Lightroom (with all edits) and return it.

    size: long edge in pixels (400-3000). analyze: also return exposure, clipping and
    colour-cast measurements.
    """
    size = max(400, min(3000, int(size)))
    result = await call_lightroom("export_preview", {"photo_id": photo_id, "size": size}, timeout=120)
    path = Path(result["path"])
    data = path.read_bytes()
    try:
        path.unlink()
    except OSError:
        pass
    out: list[Any] = [Image(data=data, format="jpeg")]
    if analyze:
        out.append(f"Photo {photo_id} analysis:\n{_analyze(data)}")
    return out


@mcp.tool()
async def apply_develop_settings(
    photo_ids: list[int],
    settings: dict[str, Any],
    history_name: str = "Claude edit",
) -> dict:
    """Apply develop settings to one or more photos (non-destructive, appears in History).

    settings uses Lightroom's own names, e.g. {"Exposure2012": 0.4, "Highlights2012": -60,
    "Shadows2012": 35, "Temperature": 5600, "Tint": 8, "Vibrance": 15,
    "SaturationAdjustmentGreen": -25, "ParametricDarks": -10}.
    Raw/DNG files use Temperature (Kelvin) and Tint; JPEG/HEIC/TIFF files use
    IncrementalTemperature and IncrementalTint (-100..100).
    Values are absolute (not added to the current value). Out-of-range values are clamped.
    The original settings are backed up before Claude's first edit of each photo.
    """
    if not photo_ids:
        raise LightroomError("photo_ids is empty")
    clean, notes = _clamp_settings(settings)
    # Lightroom ignores a temperature/tint change while WhiteBalance is "As Shot".
    if any(k in clean for k in ("Temperature", "Tint", "IncrementalTemperature", "IncrementalTint")):
        clean.setdefault("WhiteBalance", "Custom")
    backed_up = [pid for pid in photo_ids if await _backup_once(pid)]
    result = await call_lightroom(
        "apply_settings",
        {"photo_ids": photo_ids, "settings": clean, "history_name": history_name[:60]},
    )
    if notes:
        result["clamped"] = notes
    if backed_up:
        result["original_settings_backed_up_for"] = backed_up
    return result


@mcp.tool()
async def revert_claude_edits(photo_id: int, forget_backup: bool = False) -> dict:
    """Restore the develop settings the photo had before Claude first edited it.

    forget_backup: also delete the backup, so the next edit starts a fresh backup.
    """
    path = _backup_path(photo_id)
    if not path.exists():
        raise LightroomError(f"No backup for photo {photo_id}; Claude hasn't edited it (or it was cleared).")
    original = _read_json(path)
    result = await call_lightroom(
        "apply_settings",
        {"photo_ids": [photo_id], "settings": original, "history_name": "Claude: revert"},
    )
    if forget_backup:
        path.unlink()
    return {"photo_id": photo_id, "reverted": True, "status": result.get("status")}


@mcp.tool()
async def create_snapshot(photo_id: int, name: str) -> dict:
    """Save a named Develop snapshot of the photo's current state (Lightroom Classic 9+)."""
    return await call_lightroom("create_snapshot", {"photo_id": photo_id, "name": name[:60]})


@mcp.tool()
async def select_photos(photo_ids: list[int]) -> dict:
    """Select photos in Lightroom so the user can see which ones Claude is working on."""
    return await call_lightroom("select_photo", {"photo_ids": photo_ids})


def main() -> None:
    BRIDGE_DIR.mkdir(parents=True, exist_ok=True)
    _clean_old_files()
    print(f"Lightroom MCP server using bridge folder {BRIDGE_DIR}", file=sys.stderr)
    mcp.run()


if __name__ == "__main__":
    main()
