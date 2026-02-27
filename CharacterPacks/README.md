# Character Packs

This directory contains character packs for AgentSprites. Each pack is a folder containing sprite sheets and a JSON configuration.

## Pack Types

### Single Character Pack
A folder with a `character.json` file defining one character. Uses hue rotation to differentiate instances.

```
mycharacter/
  character.json
  spritesheet.png      # or separate animation files
```

### Multi-Character Pack
A folder with multiple `{name}.json` files, each defining a different character. Characters are assigned to sessions based on path hash.

```
pokemon/
  pikachu.json
  pikachu_idle.png
  pikachu_walk.png
  bulbasaur.json
  bulbasaur_idle.png
  ...
```

## character.json Format

```json
{
  "id": "mychar",
  "name": "My Character",
  "frameSize": [64, 64],
  "scale": 2.0,
  "defaultFps": 10,
  "animations": {
    "idle": { ... },
    "walk": { ... }
  },
  "states": {
    "idle": "idle",
    "working": "walk",
    ...
  }
}
```

### Top-Level Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique identifier (lowercase, no spaces) |
| `name` | string | Yes | Display name |
| `frameSize` | [width, height] | Yes | Size of each animation frame in pixels |
| `scale` | number | Yes | Display scale multiplier (1.0 = original size) |
| `defaultFps` | number | No | Default frame rate for animations (default: 10) |
| `animations` | object | Yes | Map of animation name to definition |
| `states` | object | Yes | Map of app state to animation name |

### Animation Definition

```json
{
  "file": "spritesheet.png",
  "frames": 5,
  "origin": [0, 80],
  "fps": 12,
  "loop": true,
  "vertical": false
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `file` | string | Yes | Path to sprite sheet image (relative to pack folder) |
| `frames` | number | Yes | Number of frames in this animation |
| `origin` | [x, y] | No | Starting position in sprite sheet (default: [0, 0]) |
| `fps` | number | No | Frame rate override for this animation |
| `loop` | boolean | No | Whether animation loops (default: true) |
| `vertical` | boolean | No | Frames stacked vertically instead of horizontally (default: false) |

### App States

These states map to animations:

| State | Trigger | Suggested Animation |
|-------|---------|---------------------|
| `idle` | Waiting for user input | idle, stand |
| `working` | Processing, running commands | walk, run |
| `moving` | Blob being moved | walk |
| `waitingForInput` | Claude asking a question | think, cast |
| `waitingForPermission` | Permission dialog shown | alert, think |
| `error` | Tool failure | hurt, sad |
| `done` | Task completed | idle, celebrate |
| `dragging` | User dragging the blob | walk, grab |
| `falling` | Blob falling after drag | fall, hurt |

## Sprite Sheet Layouts

### Horizontal Strip (default)
Frames laid out left to right:
```
[frame1][frame2][frame3][frame4]
```

### Vertical Strip (vertical: true)
Frames stacked top to bottom:
```
[frame1]
[frame2]
[frame3]
[frame4]
```

### Grid Sheet with Origins
Single sprite sheet with multiple animations using `origin` offsets:
```
[idle1][idle2][idle3][idle4]     <- origin: [0, 0]
[walk1][walk2][walk3][walk4]     <- origin: [0, 64]
[cast1][cast2][cast3][cast4]     <- origin: [0, 128]
```

## Examples

### Single Sprite Sheet (Grid)
```json
{
  "id": "wizard",
  "name": "Wizard",
  "frameSize": [64, 80],
  "scale": 1.5,
  "defaultFps": 8,
  "animations": {
    "idle": {
      "file": "spritesheet.png",
      "frames": 5,
      "origin": [0, 0]
    },
    "walk": {
      "file": "spritesheet.png",
      "frames": 5,
      "origin": [0, 80]
    }
  },
  "states": {
    "idle": "idle",
    "working": "walk"
  }
}
```

### Separate Animation Files
```json
{
  "id": "slime",
  "name": "Slime",
  "frameSize": [128, 128],
  "scale": 2.0,
  "defaultFps": 10,
  "animations": {
    "idle": {
      "file": "slime_idle.png",
      "frames": 4
    },
    "walk": {
      "file": "slime_walk.png",
      "frames": 6
    }
  },
  "states": {
    "idle": "idle",
    "working": "walk"
  }
}
```

## Installation

Place your character pack folder in `~/.agentsprites/characters/`, then select it from the menu bar app's settings.
