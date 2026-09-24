// ----------------------------------------------------------------------------: 骨骼动画
//
// 动画片段是逐帧、逐关节的本地变换采样（平移 + 四元数 + 3x3 缩放）。
// Animator 每帧：在两帧之间插值 -> 沿层级累乘出全局矩阵 -> 乘逆绑定矩阵得到蒙皮矩阵。
// 切换片段时，从上一姿态平滑过渡到新片段，避免跳变。

Joint_Sample :: struct {
    position: Vector3;
    orientation: Quaternion;
    scale: Matrix3;
}
#assert(size_of(Joint_Sample) == 64);

Animation_Clip :: struct {
    name: string;
    joint_count: u32;
    frame_count: u32;
    fps: float;
    samples: [] Joint_Sample;   // 帧优先，关节顺序与模型一致
}

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

animation_load :: (clip: *Animation_Clip, path: string, name: string, joint_count: s64) -> bool {
    raw, ok := read_entire_file(path);
    if !ok { log_error("Could not read animation '%'.", path); return false; }
    defer free(raw);
    reader := Asset_Reader.{bytes = raw};
    if asset_bytes(*reader, 4) != "MWAN" || asset_value(*reader, u32) != 1 return false;
    joints := asset_value(*reader, u32);
    frames := asset_value(*reader, u32);
    fps := asset_value(*reader, float);
    if joints != joint_count || joints == 0 || frames == 0 || frames > 100000 || !(fps > 0 && fps <= 240) return false;
    count := joints.(s64) * frames;
    bytes := asset_bytes(*reader, count * size_of(Joint_Sample));
    if reader.failed || reader.offset != raw.count return false;
    clip.name = copy_string(name);
    clip.joint_count = joints;
    clip.frame_count = frames;
    clip.fps = fps;
    clip.samples = NewArray(count, Joint_Sample);
    memcpy(clip.samples.data, bytes.data, bytes.count);
    return true;
}

animation_free :: (clip: *Animation_Clip) {
    array_free(clip.samples);
    free(clip.name);
    clip.* = .{};
}

animation_duration :: (clip: *Animation_Clip) -> float64 {
    return (clip.frame_count - 1).(float64) / clip.fps;
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
    array_free(animator.samples);
    array_free(animator.transition_from);
    array_free(animator.globals);
    array_free(animator.skinning);
    animator.* = .{};
}

// 顶点本来就是绑定姿态，单位矩阵即可原样显示。
animator_bind_pose :: (animator: *Animator) {
    animator.bind_pose = true;
    animator.clip = null;
    animator.time = 0;
    animator.finished = false;
    for * animator.skinning it.* = Matrix4_Identity;
}

animator_play :: (animator: *Animator, clip: *Animation_Clip, looping := true, restart := false) {
    if animator.clip == clip && !animator.bind_pose && animator.looping == looping && !restart return;
    assert(clip.joint_count == animator.model.joints.count);
    if animator.clip != null && !animator.bind_pose {
        // 记住当前姿态作为过渡起点。
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

animator_update :: (animator: *Animator, dt: float, playback_rate: float = 1) {
    if animator.bind_pose || animator.clip == null return;
    if !animator.paused {
        animator.time += dt * playback_rate;
        animator.transition_elapsed += dt;
    }
    animator_evaluate(animator);
}

// 由外部（游戏逻辑）直接指定时间，让动画进度跟动作进度对齐。
animator_seek :: (animator: *Animator, time: float64, dt: float) {
    if animator.bind_pose || animator.clip == null return;
    if !animator.paused {
        animator.time = max(time, 0.0);
        animator.transition_elapsed += dt;
    }
    animator_evaluate(animator);
}

#scope_file

blend_sample :: (a: Joint_Sample, b: Joint_Sample, t: float) -> Joint_Sample {
    result: Joint_Sample;
    result.position = lerp(a.position, b.position, t);
    orientation := b.orientation;
    if dot(a.orientation, orientation) < 0 then orientation = -orientation;   // 走短弧
    result.orientation = nlerp(a.orientation, orientation, t);
    for 0..8 result.scale.floats[it] = lerp(a.scale.floats[it], b.scale.floats[it], t);
    return result;
}

sample_matrix :: (sample: Joint_Sample) -> Matrix4 {
    scale := Matrix4_Identity;
    for row: 0..2 for column: 0..2 scale.coef[row][column] = sample.scale.coef[row][column];
    return make_translation_matrix4(sample.position) * rotation_matrix(Matrix4, sample.orientation) * scale;
}

animator_evaluate :: (animator: *Animator) {
    clip := animator.clip;
    duration := animation_duration(clip);
    animator.finished = !animator.looping && animator.time >= duration;
    if !animator.looping then animator.time = min(animator.time, duration);
    frame := cast(float) (animator.time * clip.fps);
    if animator.looping then frame = fmod_cycling(frame, clip.frame_count.(float));
    else frame = clamp(frame, 0.0, cast(float) (clip.frame_count - 1));
    first := cast(s64) frame;
    second := ifx animator.looping then (first + 1) % clip.frame_count else min(first + 1, clip.frame_count - 1);
    fraction := frame - first;
    blend := ifx animator.transition_time > 0 then min(animator.transition_elapsed / animator.transition_time, 1.0) else 1.0;

    for * sample, index: animator.samples {
        sample.* = blend_sample(clip.samples[first * clip.joint_count + index],
                                clip.samples[second * clip.joint_count + index], fraction);
        joint := *animator.model.joints[index];
        if joint.parent < 0 {
            // 位移由游戏逻辑控制：去掉根关节的水平位移（root motion）。
            sample.position.x = joint.local_bind._14;
            sample.position.z = joint.local_bind._34;
        }
        if blend < 1 then sample.* = blend_sample(animator.transition_from[index], sample.*, blend);
        local := sample_matrix(sample.*);
        animator.globals[index] = ifx joint.parent < 0 then local else animator.globals[joint.parent] * local;
        animator.skinning[index] = animator.globals[index] * joint.inverse_bind;
    }
}
