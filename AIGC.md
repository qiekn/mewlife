#  Mewlife (Renderer)

A small, customizable Jai + SGPU/Vulkan engine foundation for a 3D Sokoban game.
The current application includes a main menu, a Priestess model viewer, a cubic checkerboard,
skeletal animation with turn/blocked transitions, direct grid movement, OOTSS action audio,
a crystal-box puzzle, an ImGui inspector, and a dropdown console.

## Build and run

From this directory, with Jai on `PATH`:

```powershell
jai -quiet build.jai -x64
.\bin\main.exe
```

In MSYS2, `bash run.sh` builds and runs. Launch from the project root so asset paths resolve.
The Windows build deploys the Slang compiler DLL and embeds a per-monitor DPI manifest.
A Vulkan 1.3 driver and the Khronos validation layer are required by this development build.

## Main menu

The startup menu follows the supplied `enigmash-jai` screenshot: `0x004569` background,
white Karmina text, `0xeb8a30` selection, centered title/choices, and a bottom-right version footer.
Use W/S or arrows to select, Enter/Space to activate, and Esc to go back. Mouse selection also works.
Titles, choices, and options use `Karmina-Bold.otf`. The current title is `ENIGMASH - Remake`.

- **Resume Game** opens/resumes the puzzle. The same five main-menu labels appear at startup and during play.
- **Options** adjusts camera speed, mouse sensitivity, sound volume, inspector visibility, ground, and background color.
  Use Tab and arrows or the mouse. Settings apply immediately for the current run.
- **Load a Different Campaign** lists the one bundled campaign, **First Steps**.
- **Start a New Campaign** resets the small Sokoban level after a second activation.
- **Quit** requires a second activation; moving selection or pressing Esc cancels confirmation.

Press **F3** while playing to toggle the model viewer; its inspector previews bind/T pose, Idle, Walk,
Run, Push and Blocked Push. This developer entry stays outside the reference main-menu list.

## Controls

| Context | Keys | Action |
| --- | --- | --- |
| Game | W / S / A / D | Press to move; hold to continue grid steps. Push one box if the next cell is clear. |
| Game | Shift | Run: each grid step takes half as long. |
| World | Ctrl / Alt | Hold for 0.25x / 4x world time; both together give 1x. |
| Game | Z / R | Undo the last move / restart the level. |
| Scene | F1 / F2 | Toggle inspector / free camera. |
| Scene | F3 | Toggle model viewer / game, preserving the puzzle. |
| Free camera | W / S / A / D, Q / E | Fly forward/back/left/right, down/up. |
| Free camera | Hold right mouse, Shift | Look with unsmoothed mouse input; move four times faster. |
| Scene | Esc | Open the menu; close the console first if it is open. |
| Console | Backtick | Toggle the remembered dropdown size. |
| Console | `:` / `;` | Open remembered full/small dropdown / mini input. |
| Console | Up / Down, Enter, Esc | History, submit, close. |

Menu and console input take priority over the game. They pause world time. Free-camera inspection pauses
the game, while the camera itself uses real time. Focus loss clears held keys and pauses the world.
The scene uses metres with Y up. Floor, walls, and goals are 1 x 1 x 1 cubes on the same grid.
The checkerboard and walkable area extend across 40 x 40 tiles. The initial puzzle sits near the origin
on an open floor, with no surrounding fence or collision barrier around its starting area.
The default gameplay camera is perspective, with yaw 0, pitch -45 degrees, and a 45-degree field of view.
It shows the character from an angle above the axis-aligned grid. W/S move up/down and A/D move left/right.
Floor centres are at Y=-0.5, so the walking surface is Y=0. The two green floor cubes are goals;
push both blue-violet crystals onto them to complete the level. A crystal on a goal changes tint.

Movement reads current input directly. A press starts an action when the character is idle; holding continues
at cell boundaries without an initial repeat delay. Releasing finishes the current action and stops.
Taps made during an active action are not stored for later. If several directional presses arrive in one
frame, the latest press chooses that frame's direction. Releasing the active direction falls back to another
key that is still held. Holding against an obstacle plays one blocked response until release/repress or a
direction change. There is no movement queue, sequence input, or pending-move HUD.

The inspector's **Gameplay Camera** section edits Position, Yaw, Pitch, and projection live.
**Game FOV** controls perspective zoom, starting at 45 degrees. **Orthographic** is optional and disabled
by default; enabling it exposes **View Height**, the visible vertical span in metres (initially 14).
**Look at Board** aims at the origin; **Reset Game View** restores the default view.
F2 enters a perspective free camera from the current gameplay pose. **Use Free Camera for Gameplay** copies an
inspected angle back into gameplay. These settings survive F2, menu, viewer, and new-game transitions
within the current run. **Character Outline** and **Outline Width** control the Priestess silhouette;
the default width is 1.2 logical pixels, scaled for HiDPI.

## Console

The console borrows the dark teal, cream text/footer, `$` prompt, and minimal layout of `ootss-cmd`.
It has a full viewport mode, a 30% top dropdown, and a bottom-left mini input without output.
Input, history, and output survive mode changes. Ordinary punctuation is allowed while typing;
only the punctuation used to open/close the console is consumed.

Commands: `help`, `clear`, `close`, `toggle full`, `toggle small`, `toggle mini`.
Mini submission closes the input, retaining output for the next dropdown; an explicit `toggle` stays open.
There are no process, memory, shell, or reference-game command integrations.

## Architecture

| Directory | Responsibility |
| --- | --- |
| `src/engine` | Asset loading, skeleton/marker data, camera math, world clock, RGB conversion, PCM audio service. |
| `src/render` | Registered static/skinned meshes, cube instancing, depth, materials, GPU skinning, outlines, ImGui rendering. |
| `src/platform` | Native window, ordered press events/held keys, focus/mouse capture, DPI and ImGui event forwarding. |
| `src/editor` | Scene inspector, animation preview, camera and background settings. |
| `src/game` | Sokoban board, direct movement/blocked actions, semantic events, undo, victory, menu state. |
| `src/ui` | English menu/console presentation, theme, Noto/Karmina fonts and Meslo Nerd icon controls. |
| `src/app.jai` | Host lifecycle, input ownership, scene switching, and translation of game state to render items. |
| `src/app_audio.jai` | Maps motion spans and animation markers to the small OOTSS sound bank. |

Engine and game code consume semantic inputs and contain no ImGui or window calls. The renderer consumes
meshes, transforms, and per-item bone matrices without knowing the puzzle rules. The current scene
registers Priestess and one static crystal; all floor and wall tiles share one cube mesh.
Materials remain opaque with simple directional lighting; there is no ECS or general scene graph.

Consecutive compatible lit cubes use GPU instancing, retaining each cube's transform and checkerboard color.
All 1600 floor cubes render in one draw. The default scene uses **25 draw calls instead of 1624**, excluding
ImGui, with the same geometry and triangle count. Models and outlines keep their existing rendering path.
The inspector reports actual submitted scene draw calls.

Animation samples local translation, shortest-path quaternion interpolation, and full scale matrices,
then evaluates the hierarchy and uploads skin matrices. Clip changes blend over 0.12 seconds.
Gameplay owns translation and heading. Direction changes first turn smoothly at the current cell,
then translate one grid step: 90-degree turns take 0.22 seconds, 180-degree turns 0.32 seconds,
and walking takes 0.35 seconds per tile. Shift halves both phases. Ctrl/Alt scale the entire motion.
Three walk-turn, three push-turn and four blocked clips cover facing changes and failed movement.
Every grid action is sampled once from the game's motion clock; idle and editor previews loop.
A blocked action plays and recovers without changing the grid or adding undo history.
Undo cancels the active motion and restores both cells and facing, including mid-turn.
[Priestess provenance and formats](assets/models/priestess/README.md), [crystal extraction](assets/models/crystal/README.md).

Animation markers from the source `.sound_events` drive footsteps, stops, cloth and staff sounds.
Crystal slides and failed pushes have separate cues. Game updates emit every traversed motion span, so a
fast-time frame that finishes several actions still delivers all their markers once. Audio uses Jai's
`Sound_Player` with a small set of resident PCM clips, bounded concurrent one-shots and three variants per
effect. Ctrl/Alt scale playback rate; pause freezes streams; undo/restart stop old sounds. If no output
device is available, the game continues silently. [Audio provenance and reimport](assets/audio/ootss/README.md).

The source `mesh_outlines.mesh_outlines` maps Priestess to `entity_outline`; it contains no shader source.
Its referenced DirectX shaders are compiled binaries. The SGPU implementation uses a skinned inverted
hull with front-face culling and read-only depth after opaque geometry. Its default width is 1.2 logical pixels
and scales with DPI. Perspective views thin the outline beyond six metres to retain distant details.
The source material's 2.809818 width remains recorded in the asset provenance.
It is a compact silhouette implementation, not a port of the original game's outline post-processing.

The 3D pass uses D32 depth; ImGui follows in a separate color-only pass. Timeline semaphores protect
three reusable mapped frame buffers. Swapchain presentation prefers MAILBOX, falls back to FIFO,
and requests two images. Absolute UI mouse coordinates are sampled after swapchain acquisition.

The supplied ImGui theme is preserved. `NotoSansCJKsc-Regular.otf` is rasterized at display DPI with an
18-pixel logical body size. Menu Karmina em size follows window height / 18; the title is 1.6 times larger.
The font setup accounts for FreeType versus stb sizing, and rebuilds the atlas when DPI or the integer
menu em size changes. Options use a compact Karmina entry. The editor and console retain Noto and CJK coverage.
The inspector's combo and collapsing arrows use `nf-cod-triangle_down` (U+EB6E) and
`nf-cod-triangle_right` (U+EB70) from `Meslo-LG-Mono-Nerd-Regular.ttf`. Only these two glyphs merge
into Noto; icon placement uses glyph bounds for alignment at every DPI. Native ImGui interaction is retained.
Literal colors use `color_rgb(0xa0b8c8)` and `ui_color(0xa0b8c8)` at renderer/ImGui boundaries;
the console shares the named `Naysayer` palette in `src/ui/colors.jai`.
The window requests a 1600 x 900 logical client area, centered and capped to the monitor work area.

## Local checks

The existing repository configuration ignores `tests/`; these workspace checks are available locally:

```powershell
jai -quiet tests/core.jai -x64
.\.build\core_checks.exe
jai -quiet tests/scene.jai -x64
.\.build\scene_checks.exe
jai -quiet tests/app.jai -x64
.\.build\app_checks.exe
jai -quiet tests/imgui_sgpu.jai -x64
.\.build\imgui_sgpu_tests.exe
jai -quiet tests/audio.jai -x64
.\.build\audio_checks.exe
```

The CPU checks cover actual assets, animation, camera/time, puzzle rules, menu confirmation, and console state.
Vulkan checks compare instanced and individual cube draws by pixel readback, including different colors,
transforms, batch boundaries, and draw/triangle counts. They also verify static/skinned meshes,
outline width/culling/occlusion, attachment resizing, animated pixels, buffer reuse, combined scene/UI passes,
and fonts/ImGui at 100/125/150/200% DPI, including Nerd triangles,
collapsing headers and combo selection/clipping. Synthetic platform events exercise
input routing, console editing/history, one-shot turn selection, gameplay-camera preservation, and focus loss.
CPU checks also cover immediate presses, hold/release, direction changes, discarded busy-action taps,
blocked recovery, pause, time scaling and undo, plus both projections and stable vertical camera movement.
Application checks verify the 1,600 floor cubes, 40-metre extent, no surrounding fence, goal alignment,
perspective camera, 1.2-pixel outline, and the draw-call reduction from 1624 to 25.
Movement checks cross the former enclosure boundary. They also exercise same-frame directional taps
without a backlog, held-key priority, source sound marker counts, all blocked clips,
fast-time multi-action frames and the menu at the reference's logical dimensions.
The audio check opens the native device with output muted and verifies PCM loading, cursor progress,
pause/resume, 0.25x/4x playback and stopping. It does not assess subjective sound balance.
Preview images are written to `.build/`.
They do not open a native window; physical dragging, mouse capture, resize/minimize/restore, and
moving between monitors require an interactive run.
