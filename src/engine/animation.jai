// ----------------------------------------------------------------------------: Skeletal animation

Joint_Sample :: struct {
    position: Vector3;
    orientation: Quaternion;
    scale: Matrix3;
}

Animation_Clip :: struct {
    name: string;
    joint_count: u32;
    frame_count: u32;
    fps: float;
    samples: [] Joint_Sample; // Frame-major, in the model skeleton's joint order.
    markers: [] Animation_Marker;
    marker_data: string; // Owns marker names; consumers decide what each event means.
}

Animation_Marker :: struct { at: float; name: string; }

Animator :: struct {
    model: *Model_Asset;
    clip: *Animation_Clip;
    time: float64;
    transition_time: float = 0.12;
    transition_elapsed: float;
    paused: bool;
    looping: bool = true;
    finished: bool;
    bind_pose: bool = true;
    samples: [] Joint_Sample;
    transition_from: [] Joint_Sample;
    globals: [] Matrix4;
    skinning: [] Matrix4;
}

#assert(size_of(Joint_Sample) == 64);

animation_load :: (clip: *Animation_Clip, path: string, name: string, joint_count: s64) -> bool {
    raw, ok := read_entire_file(path);
    if !ok then return false;
    defer free(raw);
    reader := Asset_Reader.{bytes = raw};
    if asset_bytes(*reader, 4) != "MWAN" || asset_value(*reader, u32) != 1 then return false;
    joints := asset_value(*reader, u32);
    frames := asset_value(*reader, u32);
    fps := asset_value(*reader, float);
    if joints != joint_count || joints == 0 || joints > MAX_MODEL_JOINTS || frames == 0 || frames > 100000
        || !(fps > 0 && fps <= 240) then return false;
    count := joints.(s64) * frames;
    if count * size_of(Joint_Sample) > 128 * 1024 * 1024 then return false;
    bytes := asset_bytes(*reader, count * size_of(Joint_Sample));
    if reader.failed || reader.offset != raw.count then return false;
    clip.name = copy_string(name);
    clip.joint_count = joints;
    clip.frame_count = frames;
    clip.fps = fps;
    clip.samples = NewArray(count, Joint_Sample);
    memcpy(clip.samples.data, bytes.data, bytes.count);
    return true;
}

animation_free :: (clip: *Animation_Clip) {
    free(clip.samples.data);
    free(clip.name);
    free(clip.markers.data);
    free(clip.marker_data);
    clip.* = .{};
}

animation_load_markers :: (clip: *Animation_Clip, path: string) -> bool {
    assert(clip.marker_data.data == null);
    raw, ok := read_entire_file(path);
    if !ok then return false;
    success := false;
    defer if !success then free(raw);
    reader := Asset_Reader.{bytes = raw};
    if asset_bytes(*reader, 4) != "MWEV" || asset_value(*reader, u32) != 1 then return false;
    count := asset_value(*reader, u32);
    if count > 1024 then return false;
    markers := NewArray(count, Animation_Marker);
    defer if !success then free(markers.data);
    previous: float;
    for *marker: markers {
        marker.at = asset_value(*reader, float);
        marker.name = asset_string(*reader);
        if reader.failed || !(marker.at >= previous && marker.at <= 1) || !marker.name then return false;
        previous = marker.at;
    }
    if reader.failed || reader.offset != raw.count then return false;
    clip.markers = markers;
    clip.marker_data = raw;
    success = true;
    return true;
}

animator_init :: (animator: *Animator, model: *Model_Asset) {
    animator.model = model;
    animator.samples = NewArray(model.joints.count, Joint_Sample);
    animator.transition_from = NewArray(model.joints.count, Joint_Sample);
    animator.globals = NewArray(model.joints.count, Matrix4);
    animator.skinning = NewArray(model.joints.count, Matrix4);
    animator_bind_pose(animator);
}

animator_free :: (animator: *Animator) {
    free(animator.samples.data);
    free(animator.transition_from.data);
    free(animator.globals.data);
    free(animator.skinning.data);
    animator.* = .{};
}

animator_bind_pose :: (animator: *Animator) {
    animator.bind_pose = true;
    animator.clip = null;
    animator.time = 0;
    animator.finished = false;
    // The source vertices are already in their bind pose. Identity preserves it exactly.
    for *animator.skinning { it.* = Matrix4_Identity; }
}

animator_play :: (animator: *Animator, clip: *Animation_Clip, looping: bool = true, restart: bool = false) {
    if animator.clip == clip && !animator.bind_pose && animator.looping == looping && !restart then return;
    assert(clip.joint_count == animator.model.joints.count);
    if animator.clip != null && !animator.bind_pose {
        memcpy(animator.transition_from.data, animator.samples.data, animator.samples.count * size_of(Joint_Sample));
        animator.transition_elapsed = 0;
    } else {
        animator.transition_elapsed = animator.transition_time;
    }
    animator.clip = clip;
    animator.bind_pose = false;
    animator.time = 0;
    animator.looping = looping;
    animator.finished = false;
}

animation_duration :: (clip: *Animation_Clip) -> float64 { return (clip.frame_count - 1).(float64) / clip.fps; }

animation_blend_sample :: (a: Joint_Sample, b: Joint_Sample, t: float) -> Joint_Sample {
    result: Joint_Sample;
    result.position = lerp(a.position, b.position, t);
    orientation := b.orientation;
    if dot(a.orientation, orientation) < 0 then orientation = -orientation;
    result.orientation = nlerp(a.orientation, orientation, t);
    for 0..8 { result.scale.floats[it] = lerp(a.scale.floats[it], b.scale.floats[it], t); }
    return result;
}

animation_sample_matrix :: (sample: Joint_Sample) -> Matrix4 {
    scale := Matrix4_Identity;
    for row: 0..2 for column: 0..2 { scale.coef[row][column] = sample.scale.coef[row][column]; }
    return make_translation_matrix4(sample.position) * rotation_matrix(Matrix4, sample.orientation) * scale;
}

animator_update :: (animator: *Animator, world_dt: float, playback_rate: float = 1) {
    if animator.bind_pose || animator.clip == null then return;
    if !animator.paused {
        animator.time += world_dt * playback_rate;
        animator.transition_elapsed += world_dt;
    }
    animator_evaluate(animator);
}

// Useful for motions owned by gameplay: sample its clock without letting the two timelines drift.
animator_seek :: (animator: *Animator, time: float64, world_dt: float) {
    if animator.bind_pose || animator.clip == null then return;
    if !animator.paused {
        animator.time = max(time, 0.0);
        animator.transition_elapsed += world_dt;
    }
    animator_evaluate(animator);
}

#scope_file

animator_evaluate :: (animator: *Animator) {
    clip := animator.clip;
    animator.finished = !animator.looping && animator.time >= animation_duration(clip);
    if !animator.looping then animator.time = min(animator.time, animation_duration(clip));
    frame := cast(float) (animator.time * clip.fps);
    if animator.looping then frame = fmod_cycling(frame, clip.frame_count.(float));
    else frame = clamp(frame, 0.0, cast(float) (clip.frame_count - 1));
    first := cast(s64) frame;
    second := ifx animator.looping then (first + 1) % clip.frame_count else min(first + 1, clip.frame_count - 1);
    fraction := frame - first;
    blend := ifx animator.transition_time > 0 then min(animator.transition_elapsed / animator.transition_time, 1.0) else 1.0;
    for *sample: animator.samples {
        sample.* = animation_blend_sample(clip.samples[first * clip.joint_count + it_index],
                                         clip.samples[second * clip.joint_count + it_index], fraction);
        if animator.model.joints[it_index].parent < 0 {
            // Gameplay owns translation. Remove horizontal root motion from the imported clips.
            sample.position.x = animator.model.joints[it_index].local_bind._14;
            sample.position.z = animator.model.joints[it_index].local_bind._34;
        }
        if blend < 1 then sample.* = animation_blend_sample(animator.transition_from[it_index], sample.*, blend);
        local := animation_sample_matrix(sample.*);
        parent := animator.model.joints[it_index].parent;
        animator.globals[it_index] = ifx parent < 0 then local else animator.globals[parent] * local;
        animator.skinning[it_index] = animator.globals[it_index] * animator.model.joints[it_index].inverse_bind;
    }
}

#scope_file
#import "Basic";
#import "File";
#import "Math";
#import "String";
