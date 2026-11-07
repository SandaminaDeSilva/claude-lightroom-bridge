# Claude ↔ Lightroom Classic Bridge

Let Claude see and edit your photos in **Adobe Lightroom Classic**: it identifies what kind of
photo it is (event, portrait, landscape, night street…), applies real develop settings, checks
the result, and refines. Everything is non-destructive and shows up in Lightroom's History.

```
Lightroom Classic ⇄ ClaudeEditor.lrplugin ⇄ ~/.claude-lightroom-bridge (file queue) ⇄ server/lightroom_mcp.py (MCP) ⇄ Claude desktop app
```

| Part | What it does |
|---|---|
| `ClaudeEditor.lrplugin/` | Lightroom Classic plugin (Lua). Reads photos, renders previews, applies settings, makes snapshots. |
| `server/lightroom_mcp.py` | MCP server (Python). Exposes the tools to Claude and analyses previews (exposure, clipping, colour cast). |
| `skill/lightroom-photo-editor/` | Claude skill: the editing workflow and context-based looks. |
| `install.py` / `install.bat` | Installs Python deps and registers the server with the Claude desktop app. |

## Requirements

- Lightroom Classic (SDK 6+; snapshots need 9+)
- Python 3.10+
- Claude desktop app (Windows or macOS)

## Install

1. **Quit the Claude desktop app completely** (system tray / menu bar → Quit). Otherwise it overwrites the config change when it exits.
2. Windows: double-click `install.bat`. macOS: `python3 install.py`.
3. Lightroom Classic: **File → Plug-in Manager → Add** → choose `ClaudeEditor.lrplugin`. It should say *Installed and running*.
4. Open Claude and check **Settings → Developer**: `lightroom` should be listed and running.
5. Optional: add the skill. Upload `skill/lightroom-photo-editor` as a skill in Claude, or copy it into your skills folder.

If the installer can't find the config, use Claude → Settings → Developer → **Edit Config** and add:

```json
{
  "mcpServers": {
    "lightroom": {
      "command": "python",
      "args": ["C:\\path\\to\\claude-lightroom-bridge\\server\\lightroom_mcp.py"]
    }
  }
}
```

(On Windows you can use `"command": "py", "args": ["-3", "...lightroom_mcp.py"]`.)

## Use

Select photos in Lightroom and ask Claude:

- "Edit the selected photos"
- "Edit photos 1–20 in the *Trip 2026* folder"
- "Make these cleaner and cooler, like this reference" (attach an image)
- "Revert your edits on IMG_1234"

### Tools

`lightroom_status`, `list_photos`, `list_folder_photos`, `get_develop_settings`, `preview_photo`,
`apply_develop_settings`, `revert_claude_edits`, `create_snapshot`, `select_photos`.

## Limitations

- Lightroom must be open. The bridge polls every 0.2 s.
- The Lightroom SDK has no access to **masks, AI masks, healing, local brushes or AI denoise**. Claude suggests those as manual steps.
- JPEGs have limited highlight recovery. RAW works best.

## Privacy

- Everything runs locally. The plugin and server only talk through `~/.claude-lightroom-bridge`.
- Preview JPEGs are deleted right after they're read. They are sent to Claude so it can see the photo, the same as attaching an image in chat.
- Original develop settings are backed up to `~/.claude-lightroom-bridge/backups/` before Claude's first edit of each photo.

## Troubleshooting

| Problem | Fix |
|---|---|
| "Lightroom bridge not found" | Open Lightroom; check Plug-in Manager. |
| "No heartbeat" | Library → Plug-in Extras → Claude Bridge: Restart. |
| Tools missing in Claude | Re-run the installer with Claude quit, then restart Claude. |
| "Unknown command" after updating the plugin | Plug-in Manager → Plug-in Author Tools → Reload plug-in. |
| Plugin log | `Documents/LrClassicLogs/ClaudeEditor.log` |

## Development

```bash
pip install lupa pillow "mcp>=2.3,<3"
python tests/test_bridge.py      # plugin (Lua) + server against a mock Lightroom SDK
python tests/test_e2e_stdio.py   # full stack over MCP stdio
```

## License

MIT. See [LICENSE](LICENSE). Not affiliated with Adobe or Anthropic.
