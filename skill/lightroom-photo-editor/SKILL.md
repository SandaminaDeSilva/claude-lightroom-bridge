---
name: lightroom-photo-editor
description: Edit photos in Lightroom Classic through the lightroom MCP tools like a professional retoucher, choosing the look from the photo's context. Use when asked to edit, grade, fix or match photos in Lightroom.
---

# Lightroom photo editor

You edit photos in the user's Lightroom Classic through the `lightroom` MCP server
(plugin: Claude Editor Bridge). Edits are non-destructive and appear in Lightroom's History.
Aim for professional, client-ready results: a timid or muddy edit reads as amateur.

## Workflow

1. `lightroom_status`. If it fails, tell the user the fix from the error (open Lightroom; Library > Plug-in Extras > Claude Bridge: Restart).
2. `list_photos` (selected photos), or `list_folder_photos` for a folder. Note `fileFormat` (RAW/DNG vs JPG/HEIC/TIFF) and the metadata: capture time, ISO, lens, focal length.
3. For each photo:
   - `get_develop_settings` to see what's already applied. Don't wipe the user's own work unless asked; if you do, `create_snapshot` "Before Claude (original edit)" first.
   - `preview_photo` (size 600-1600). Look at the image AND read the analysis numbers.
   - **Identify the context** (see Context profiles) from the frame plus metadata, and say it in one line, e.g. "Indoor conference, candid moment, warm hotel lighting".
   - Edit from that profile in this order: lens corrections → white balance → exposure → tone → curve → presence → colour (HSL, calibration) → grading → detail/noise → crop → vignette.
   - `apply_develop_settings` with a descriptive `history_name`.
   - `preview_photo` again, compare against the targets, refine 1-2 times, then stop.
4. Batches: group photos by context, perfect one per group, apply the shared look, then adjust exposure / WB per photo.
5. Summarise per photo: the context, what changed and why, and any manual local step (masks, healing) that would finish it.

## Context profiles

Starting points: adapt to the actual light. Always: LensProfileEnable 1, AutoLateralCA 1 (RAW); noise reduction scaled to ISO (ISO 800: LuminanceSmoothing ~15, ColorNoiseReduction 20-25; ISO 3200+: 30-40; ISO 6400: 40-50 with SharpenEdgeMasking ~70).

### 1. Conference / corporate event, people
Cues: lanyards, podiums, round tables, audiences, hotel ballrooms.
Clean, cool-neutral, cinematic: neutralise the orange hotel light (JPEG: IncrementalTemperature ~-35..-50, Tint +12..+16), Contrast +30, Highlights -60..-70, Shadows +15..+20, Whites -15..-25, Blacks -20..-35, Clarity -5, Texture +8, Vibrance +10, Saturation -10..-15, Orange sat -22 / lum +10, Yellow sat -40, grading shadows hue 200 / sat 10, highlights hue 15 / sat 6, vignette -18.
Alternative "vivid event" look (if the user prefers it): warmer WB with a magenta lean, Contrast +25, Clarity -14 (glow), Vibrance +30, Saturation +8, Orange sat +10 / lum +14, Blue primary hue -10 / sat +25.

### 2. Stage / LED screen
Keep the coloured stage light (don't neutralise toward grey); expose for the speaker's face; keep blues/purples rich but not clipped. If coloured LEDs tint faces or walls purple, pull Purple/Magenta saturation down rather than changing WB.

### 3. Outdoor portrait / trip
Natural, clean skin: correct green cast from foliage (Tint +6..+12), Contrast +12, Highlights -60..-90 in harsh sun, Shadows +30..+45, Clarity -5, Texture +6, Greens to olive (Green hue -15..-18, sat -25), Yellow sat -20, Orange lum +12..+15, highlights grading hue 40 / sat 8, vignette -10..-12. Faces in shade under caps: Exposure up rather than more Shadows.

### 4. Studio / headshot
Neutral accurate WB, clean backdrop (whites just under clipping), Contrast +10, Texture +10, light grading, crisp sharpening.

### 5. Landscape / mountain / travel
Dehaze +15..+30 (flat hazy scenes), Clarity +12, Texture +12, Contrast +20, Blacks -30..-45, Highlights -50..-60, Vibrance +20, warm the cold-blue cast slightly, Blue lum -15 for skies, grading shadows 210 / highlights 40. Keep atmospheric mist between ridge layers (lighter dehaze there).

### 6. Architecture (e.g. white monuments)
Deep blue sky (Blue sat +25, lum -25), bright clean whites (Whites +15..+25), Dehaze +18, Texture/Clarity +15, Contrast +25.

### 7. Night street / blue hour
Keep the blue sky vs warm lights contrast; brighten +1..+2 EV for dark high-ISO frames, Highlights -80 to protect lamps, heavy noise reduction, Vibrance +15, grading shadows 215 / highlights 38.

### 8. Macro / flowers / product
Subject colour rich but true, background greens muted (Green sat -30), Texture +15, Clarity +10, deeper blacks, vignette -18. Products: neutral WB, bright and crisp.

### 9. Shop / tungsten interior
Neutralise strong orange (RAW: Temperature ~4000, Tint +6), recover blown highlights, Texture/Clarity up for craft detail.

## Rules

- Values are absolute, not relative. Read current values before changing.
- RAW/DNG: `Temperature` (Kelvin) + `Tint`. JPEG/HEIC/TIFF: `IncrementalTemperature` / `IncrementalTint` (-100..100). WhiteBalance must be "Custom" for a WB change to apply (the server sets this automatically).
- Skin first: whatever the profile, skin must look healthy, never orange, green or grey.
- Brightness targets (analysis mean): daylight ~100-130, bright events ~110-140, moody forest / night / stage ~60-100 by design.
- Clipping in the source is only partly recoverable, especially in JPEGs: contain it and say so. RAW recovers far more.
- Avoid the flat HDR look: don't combine Highlights below -70 with Shadows above +50; use Exposure and the tone curve instead.
- Verify after every apply (mean, zones, clipping, saturation, colour cast). One small correction if needed, not another full pass. Watch for over-correction (e.g. cooling until it turns blue).
- Flag unfixable issues: motion blur, missed focus, near-black frames.
- If the user dislikes a result, `revert_claude_edits` restores the original.
- Not possible through the SDK: masks, AI masks, healing, local brushes, AI denoise. Suggest the manual step (e.g. Select Subject +0.2 exposure).

## Setting names

Basic: Exposure2012, Contrast2012, Highlights2012, Shadows2012, Whites2012, Blacks2012, Texture, Clarity2012, Dehaze, Vibrance, Saturation
Curve: ParametricShadows/Darks/Lights/Highlights, ToneCurveName2012 + ToneCurvePV2012 (flat list x1,y1,x2,y2… 0-255)
HSL: HueAdjustment<Color>, SaturationAdjustment<Color>, LuminanceAdjustment<Color> for Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta
Calibration: RedHue, RedSaturation, GreenHue, GreenSaturation, BlueHue, BlueSaturation
Colour grading: SplitToningShadowHue/Saturation, SplitToningHighlightHue/Saturation, SplitToningBalance, ColorGradeMidtoneHue/Sat, ColorGradeBlending
Detail: Sharpness, SharpenRadius, SharpenDetail, SharpenEdgeMasking, LuminanceSmoothing, LuminanceNoiseReductionDetail, ColorNoiseReduction
Effects: PostCropVignetteAmount/Midpoint/Feather, GrainAmount/Size/Frequency
Geometry: CropAngle, CropLeft/Top/Right/Bottom (0..1, HasCrop true), PerspectiveVertical/Horizontal, LensProfileEnable, AutoLateralCA
Profile / B&W: CameraProfile ("Adobe Color"), ConvertToGrayscale

## House style

(Add your own preferences here: default looks per client or event type, how warm or faded you like images, things to never do.)
