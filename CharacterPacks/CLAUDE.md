# CharacterPacks - Claude Instructions

When creating character packs from sprite sheets:

## Quick Reference

### Single Sprite Sheet (Grid Layout)
Use `origin` to specify [x, y] offset for each animation row.

**Coordinates use top-left origin** (standard image coordinates):
- Top row → Y = 0
- Each subsequent row → Y = row_number * frame_height

For a 320x320 image with 4 rows of 64px frames:
- Row 0 (top): origin Y = 0
- Row 1: origin Y = 64
- Row 2: origin Y = 128
- Row 3: origin Y = 192

```json
{
  "id": "character_id",
  "name": "Display Name",
  "frameSize": [FRAME_WIDTH, FRAME_HEIGHT],
  "scale": 1.5,
  "defaultFps": 8,
  "animations": {
    "idle": { "file": "spritesheet.png", "frames": N, "origin": [0, 0] },
    "walk": { "file": "spritesheet.png", "frames": N, "origin": [0, FRAME_HEIGHT] },
    "cast": { "file": "spritesheet.png", "frames": N, "origin": [0, FRAME_HEIGHT * 2] }
  },
  "states": {
    "idle": "idle",
    "working": "walk",
    "moving": "walk",
    "waitingForInput": "idle",
    "waitingForPermission": "idle",
    "error": "idle",
    "done": "idle",
    "dragging": "walk",
    "falling": "idle"
  }
}
```

### Calculating Frame Size and Origins
```
frame_width = image_width / columns
frame_height = image_height / rows
origin_y_for_row_N = frame_height * N
```

### Required States
All of these must be mapped to an animation:
- `idle`, `working`, `moving`, `waitingForInput`, `waitingForPermission`, `error`, `done`, `dragging`, `falling`

### Animation Options
- `fps`: Override frame rate (default uses `defaultFps`)
- `loop`: Set to `false` for one-shot animations (hurt, attack)
- `vertical`: Set to `true` if frames are stacked vertically

## Workflow

1. Calculate frame dimensions from image size and grid layout
2. Create pack folder in `CharacterPacks/`
3. Copy sprite sheet to pack folder
4. Create `{name}.json` (e.g., `fenwick.json`) with appropriate origins for each row
   - Use `character.json` only for single-character packs with hue rotation
   - Use `{name}.json` for multi-character packs (add more characters later)
5. Map states to animations based on visual appearance

See README.md for full documentation.
