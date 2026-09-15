# Priestess asset

Imported from the user-specified local `ootss-assets` project:
`C:/msys64/home/user/projects/ootss-assets` (MSYS2: `/home/user/projects/ootss-assets`).
That project's Priestess uses the internal ID **cleric**. The mesh, texture and animation data are
copied/converted reference assets, not newly authored art. Runtime loading uses only files in this directory.

Reimport from the mewlife project root:

```powershell
python tools/import_priestess.py --source C:/msys64/home/user/projects/ootss-assets
```

The importer reads `data/characters/cleric/cleric.mesh`, `.uv`, `.parts`, and the animation sources
listed in `manifest.json`. It uses the reference's `tools/ootss_formats.py` decoder at import time,
without writing to the reference project. There is no Python dependency at runtime.

The result has 26,418 vertices, 28,119 triangles, 254 joints, and 11 material parts sharing one diffuse PNG.
Positions are in metres, Y points up, and the model faces +X. The host rotates -90 degrees about Y
to face game +Z. PNGs are loaded without flipping; the shader samples `(u, 1-v)`.
Texture alpha stores material data and is deliberately not used as opacity.

| File | Source clip | Frames | FPS |
| --- | --- | --- | --- |
| `idle.animbin` | `cleric_active_idle_01.anim` | 111 | 30 |
| `walk.animbin` | `cleric_active_moveForward_01.anim` | 21 | 30 |
| `push.animbin` | `cleric_push_walkForward_01.anim` | 21 | 30 |
| `turn_left.animbin` | `cleric_active_idleToMove90Left_01.anim` | 31 | 30 |
| `turn_right.animbin` | `cleric_active_idleToMove90Right_01.anim` | 31 | 30 |
| `turn_back.animbin` | `cleric_active_idleToMove180Right_01.anim` | 31 | 30 |
| `push_turn_left.animbin` | `cleric_active_idleToPushMove90Left_01.anim` | 31 | 30 |
| `push_turn_right.animbin` | `cleric_active_idleToPushMove90Right_01.anim` | 31 | 30 |
| `push_turn_back.animbin` | `cleric_active_idleToPushMove180Right_01.anim` | 31 | 30 |
| `blocked.animbin` | `cleric_active_bumpForward_01.anim` | 43 | 30 |
| `blocked_left.animbin` | `cleric_active_idleToBlocked90Left_01.anim` | 101 | 30 |
| `blocked_right.animbin` | `cleric_active_idleToBlocked90Right_01.anim` | 101 | 30 |
| `blocked_back.animbin` | `cleric_active_idleToBlocked180Right_01.anim` | 101 | 30 |

Gameplay samples every movement and blocked action once from its motion clock, then blends into the next state.
Shift halves the action duration. Idle and editor previews loop. The source trajectory/root yaw is constant;
the importer checks this for turn and blocked clips before exporting. Gameplay supplies heading once.
Blocked actions preserve the source's recovery at twice its authored speed (0.7 seconds forward,
1.667 seconds when turning; Shift halves these). They never move a logical cell.
`manifest.json` records the source animation hashes and intended loop modes.

[`tools/import_sounds.py`](../../../tools/import_sounds.py) imports the corresponding source sound markers
after these clips have been imported. [Sound provenance](../../audio/ootss/README.md) records the original
events, audio media and marker files. The runtime owns all buffers and releases audio streams before their samples.

## Binary formats, version 1

All numbers are little-endian. Floats are IEEE float32. Matrices are row-major with column-vector
transforms. Strings are a uint32 byte count followed by UTF-8 bytes, without a terminator.

`*.meshbin` (shared by Priestess and the static crystal):

1. `MWMS`, uint32 version, uint32 counts for vertices/indices/joints/parts, float3 bounds min/max.
2. Joints in parent-before-child order: name string, int32 parent (`-1` for root), float4x4 local bind matrix.
   A static mesh has zero joints and omits this section.
3. Parts: name string, texture-path string, uint32 first index/index count/optional/repeat/material mask,
   float4 color. The material mask is source metadata, not an alpha-cutout switch.
4. Vertices, 64 bytes each: float3 position, float3 normal, float2 UV, float4 weights, uint4 joint indices.
   `0xffffffff` denotes an unused joint slot. The importer normalizes valid weights.
   Static vertices have zero weights and four unused joint slots.
5. Triangle indices as uint32 values.

`*.animbin`:

1. `MWAN`, uint32 version/joint count/frame count, float32 FPS.
2. Frame-major samples in the model's joint order, 64 bytes each: float3 local translation,
   float4 quaternion `(x,y,z,w)`, float3x3 local scale matrix.

`*.eventsbin`:

1. `MWEV`, uint32 version/marker count.
2. Markers sorted by time: float32 normalized progress `[0, 1]`, event-name string.

The importer checks skeleton names and parents before reordering samples. The runtime calculates inverse
bind matrices when loading the mesh. Bind pose uploads identity skinning matrices; animation evaluation
combines local samples through the hierarchy and multiplies by each inverse bind matrix.
