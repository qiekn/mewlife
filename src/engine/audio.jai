// ----------------------------------------------------------------------------: Small PCM sound service over Jai's Sound_Player

Audio_Clip :: struct { data: Sound.Sound_Data; }
Audio_Player :: struct {
    initialized, available: bool;
    volume: float = 0.7;
    time_scale: float = 1;
    paused: bool;
    cue_count: u64; // Accepted playback requests; also useful without opening a device.
    next_voice: s64;
}

audio_load :: (clip: *Audio_Clip, path: string) -> bool {
    clip.data = Sound.load_audio_file(path);
    return clip.data.loaded;
}

audio_free :: (clip: *Audio_Clip) {
    // The owning player must be shut down before releasing any clip buffers.
    free(clip.data.name);
    free(clip.data.buffer);
    clip.* = .{};
}

audio_init :: (player: *Audio_Player) -> bool {
    assert(!player.initialized);
    player.available = Sound.sound_player_init(.{});
    player.initialized = true; // Sound_Player also owns resources when no output device is available.
    return player.available;
}

audio_stop :: (player: *Audio_Player) {
    if player.initialized then Sound.stop_all_sounds_abruptly(AUDIO_MANAGER_ID);
}

audio_shutdown :: (player: *Audio_Player) {
    if !player.initialized then return;
    audio_stop(player);
    Sound.sound_player_shutdown();
    player.initialized = false;
    player.available = false;
}

audio_play :: (player: *Audio_Player, clip: *Audio_Clip, volume: float = 1) {
    if !clip.data.loaded || player.paused then return;
    player.cue_count += 1;
    if !player.initialized then return;
    // Cap simultaneous one-shots without keeping pointers that the mixer may retire.
    player.next_voice += 1;
    if player.next_voice > AUDIO_MAX_VOICES then Sound.stop_stream_abruptly(player.next_voice - AUDIO_MAX_VOICES);
    stream := Sound.make_stream(*clip.data);
    stream.manager_id = AUDIO_MANAGER_ID;
    stream.entity_id = player.next_voice;
    stream.user_volume_scale = volume;
    stream.universe_volume_scale = player.volume;
    stream.rate_scale = player.time_scale;
    Sound.update_desired_rate(stream);
    stream.current_rate = stream.desired_rate;
    Sound.start_playing(stream);
}

audio_update :: (player: *Audio_Player, real_dt: float) {
    if !player.initialized then return;
    {
        lock(*Sound.sound_mutex);
        defer unlock(*Sound.sound_mutex);
        for stream: Sound.live_streams {
            if stream.manager_id != AUDIO_MANAGER_ID then continue;
            stream.universe_volume_scale = player.volume;
            stream.rate_scale = ifx player.paused then 0 else player.time_scale;
            // Skipping the stream freezes its sample cursor, including quiet/fading sounds.
            stream.inaudible = player.paused;
            if player.paused then stream.user_flags |= .PAUSED_DUE_TO_MENU;
            else stream.user_flags &= ~.PAUSED_DUE_TO_MENU;
        }
    }
    Sound.update(real_dt);
}

#scope_file
AUDIO_MANAGER_ID :: 1;
AUDIO_MAX_VOICES :: 48;
Sound :: #import "Sound_Player"(VERBOSE = false);
#import "Basic";
#import "Thread";
