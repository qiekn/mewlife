// ----------------------------------------------------------------------------: Game/animation events -> local sound assets

Game_Sound :: enum { STEP; FOOT_STOP; FOOT_STOP_SOFT; CLOTH; STICK_SLIDE; PUSH; PUSH_FAILED; }
Game_Sounds :: struct {
    clips: [7][3] Audio_Clip;
    next_variant: [7] u32;
    cue_count: [7] u64;
}

app_load_sounds :: (app: *App) {
    names := string.["step", "foot_stop", "foot_stop_soft", "cloth", "stick_slide", "push", "push_failed"];
    for group: 0..names.count - 1 for variant: 0..2 {
        assert(audio_load(*app.sounds.clips[group][variant],
                         tprint("assets/audio/ootss/%_0%.wav", names[group], variant + 1)), "Cannot load % sound.", names[group]);
    }
    assert(animation_load_markers(*app.idle, "assets/models/priestess/idle.eventsbin"));
    assert(animation_load_markers(*app.walk, "assets/models/priestess/walk.eventsbin"));
    assert(animation_load_markers(*app.push, "assets/models/priestess/push.eventsbin"));
    for name: string.["left", "right", "back"] {
        assert(animation_load_markers(*app.turns[it_index], tprint("assets/models/priestess/turn_%.eventsbin", name)));
        assert(animation_load_markers(*app.push_turns[it_index], tprint("assets/models/priestess/push_turn_%.eventsbin", name)));
    }
    for name: string.["blocked", "blocked_left", "blocked_right", "blocked_back"] {
        assert(animation_load_markers(*app.blocked_clips[it_index], tprint("assets/models/priestess/%.eventsbin", name)));
    }
}

app_free_sounds :: (app: *App) {
    audio_shutdown(*app.audio);
    for group: 0..6 for variant: 0..2 { audio_free(*app.sounds.clips[group][variant]); }
}

app_play_sound :: (app: *App, sound: Game_Sound) {
    if app.audio.paused then return;
    index := sound.(s64);
    variant := app.sounds.next_variant[index];
    app.sounds.next_variant[index] = (variant + 1) % 3;
    app.sounds.cue_count[index] += 1;
    // Footsteps and cloth sit underneath the two stone interactions.
    volume: float = ifx sound == .CLOTH then 0.45 else ifx sound == .STEP then 0.7 else 0.85;
    audio_play(*app.audio, *app.sounds.clips[index][variant], volume);
}

app_play_marker :: (app: *App, name: string) {
    for event: string.["char_cleric_anim_step_slowMoOnly", "char_cleric_anim_footStop",
                       "char_cleric_anim_footStop_lo", "char_cleric_anim_cloth", "char_cleric_anim_stickSlide"] {
        if event == name { app_play_sound(app, cast(Game_Sound) it_index); return; }
    }
}

app_update_audio :: (app: *App, real_dt: float) {
    app.audio.volume = app.editor.sfx_volume;
    app.audio.time_scale = app.game.clock.scale;
    app.audio.paused = app.mode != .GAME || app.game.clock.dt == 0;
    if app.mode == .GAME {
        for index: 0..app.game.event_count - 1 {
            event := app.game.events[index];
            if event.kind == .RESET { audio_stop(*app.audio); continue; }
            if event.kind == .STONE_SLIDE { app_play_sound(app, .PUSH); continue; }
            if event.kind == .PUSH_FAILED { app_play_sound(app, .PUSH_FAILED); continue; }
            if event.kind != .MOTION then continue;
            clip := app_motion_clip(app, event.motion, event.turn);
            for marker: clip.markers {
                crossed := (marker.at > event.from || (event.started && marker.at == 0)) && marker.at <= event.to;
                if crossed then app_play_marker(app, marker.name);
            }
        }
    }
    audio_update(*app.audio, real_dt);
}

#scope_file
#import "Basic";
