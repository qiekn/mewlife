# OOTSS action sounds

These effects were decoded from the user-specified local installation:
`E:/SteamLibrary/steamapps/common/Order of the Sinking Star Demo`.
Only 21 short PCM16 stereo WAVs are used at runtime; the game does not load Wwise or the source installation.

Reimport after importing the Priestess model and clips:

```powershell
python tools/import_sounds.py --game "E:/SteamLibrary/steamapps/common/Order of the Sinking Star Demo" --reference C:/msys64/home/user/projects/ootss-assets
```

The tool uses `vgmstream-cli` to decode embedded WEM/Vorbis and `ffmpeg` to convert to 48 kHz stereo PCM16.
Pass `--decoder` or `--ffmpeg` if they are not on PATH. Temporary WEM/WAV files stay in `.build/audio_import`.
It reads the reference project's package reader without modifying that project.

| Runtime family | Original Wwise event | Selection |
| --- | --- | --- |
| `step` | `char_cleric_anim_step_slowMoOnly` | Granite footstep recordings, three variants. |
| `foot_stop` | `char_cleric_anim_footStop` | Granite stop/impact, three variants. |
| `foot_stop_soft` | `char_cleric_anim_footStop_lo` | Quiet granite stop/impact, three variants. |
| `cloth` | `char_cleric_anim_cloth` | Priestess cloth/foley layers, three variants. |
| `stick_slide` | `char_cleric_anim_stickSlide` | Staff sliding on granite, three variants. |
| `push` | `push_block` | Crystal object on granite, three mixed variants. |
| `push_failed` | `no_multipush` | Failed crystal interaction on granite, three mixed variants. |

Event names were traced to their FNV-1 IDs, HIRC play actions, containers, switches, and embedded media
in `Gameplay_and_characters.bnk` and `Gameplay_and_characters_media.bnk` (Wwise version 154).
`manifest.json` records bank hashes, each HIRC path, switch decisions, WEM hashes, output hashes and mix gains.
Random containers are reduced to three deterministic variants, cycled at runtime. Layers are mixed with
constant-power gain and attenuated only when needed to keep peaks below 90%. Wwise DSP and RTPC curves
are not imported; the host controls volume and playback rate.

The original `cleric_*.sound_events` files in `data/animation.package` supply normalized animation markers.
They are exported as `assets/models/priestess/*.eventsbin`, preserving their original names and times.
The source's `step_slowMoOnly` recordings are used at all speeds here: mewlife owns their scheduling,
instead of retaining the original game's slow-motion-only gate. A failed crystal push also plays one
`no_multipush` feedback cue at contact. Walls use the character's authored foot/cloth markers without
playing a crystal sound.

World pause freezes existing streams. Ctrl/Alt change pitch and duration together with world time;
Shift changes the action and marker cadence. Menu Options has a **Sound Effects** volume slider.
