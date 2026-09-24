// ----------------------------------------------------------------------------: 演示场景 2：推箱子
//
// 世界由单位格子组成：BLOCK 是地面/墙（可以叠高，不限于一个平面），BOX 是可推的水晶箱，
// GOAL 是目标格，PLAYER 是牧师。规则：
//   - 目标格有 BLOCK：若其上方空着，就爬上去一格；否则算撞墙
//   - 目标格没有 BLOCK 也没有支撑：若再往下一格有支撑，就走下去一格；否则算掉崖，不动
//   - 目标格有 BOX：箱子再往前一格必须空着且有支撑，才一起推动
// 一次动作 = 转身（可选）+ 迈步，动画片段按（动作，转向）选取，并用动作进度驱动动画进度。
// 编辑：左键选中实体，gizmo 拖动（按格吸附），Scene 窗口里增删方块/箱子/目标。

Sokoban :: struct {
    world: World;

    cube: Mesh;
    crystal: Model_Asset;
    crystal_mesh: Mesh;
    crystal_textures: [] Gpu_Texture_View;
    priestess: Model_Asset;
    priestess_mesh: Mesh;
    priestess_textures: [] Gpu_Texture_View;
    textures: [..] Texture;           // 拥有所有加载的贴图

    animator: Animator;
    idle, walk, push: Animation_Clip;
    turns, push_turns: [3] Animation_Clip;   // LEFT / RIGHT / BACK
    blocked_clips: [4] Animation_Clip;       // NONE / LEFT / RIGHT / BACK

    // 角色动作状态。
    player: s32 = -1;             // PLAYER 实体下标
    facing: float;                // 逻辑朝向（弧度，从 +Z 起）
    visual_facing: float;
    busy: bool;                   // 正在转身或迈步
    blocked: bool;                // 这次动作是撞墙
    turn: Turn;
    turn_from, turn_angle: float;
    turn_time, turn_duration: float;
    step_time, step_duration: float;
    from, to: Vector3;
    pushed_box: s32 = -1;
    box_from, box_to: Vector3;
    running: bool;
    move_count: u32;
    solved: bool;
    loaded: bool;
}

Turn :: enum { NONE; LEFT; RIGHT; BACK; }
Motion :: enum { WALK; PUSH; BLOCKED; }

sokoban: Sokoban;

sokoban_init :: () {
    s := *sokoban;
    s.cube = make_cube_mesh();

    // 水晶箱。
    assert(model_load(*s.crystal, "assets/models/crystal/crystal.meshbin"), "Cannot load crystal mesh");
    s.crystal_mesh = upload_mesh(s.crystal.vertices, s.crystal.indices);
    s.crystal_textures = load_part_textures(s, s.crystal.parts, "assets/models/crystal");

    // 牧师与动画。
    assert(model_load(*s.priestess, "assets/models/priestess/priestess.meshbin"), "Cannot load priestess mesh");
    s.priestess_mesh = upload_mesh(s.priestess.vertices, s.priestess.indices);
    s.priestess_textures = load_part_textures(s, s.priestess.parts, "assets/models/priestess");
    joints := s.priestess.joints.count;
    assert(animation_load(*s.idle, "assets/models/priestess/idle.animbin", "Idle", joints));
    assert(animation_load(*s.walk, "assets/models/priestess/walk.animbin", "Walk", joints));
    assert(animation_load(*s.push, "assets/models/priestess/push.animbin", "Push", joints));
    for name: string.["left", "right", "back"] {
        assert(animation_load(*s.turns[it_index], tprint("assets/models/priestess/turn_%.animbin", name), tprint("Turn %", name), joints));
        assert(animation_load(*s.push_turns[it_index], tprint("assets/models/priestess/push_turn_%.animbin", name), tprint("Push turn %", name), joints));
    }
    for name: string.["blocked", "blocked_left", "blocked_right", "blocked_back"] {
        assert(animation_load(*s.blocked_clips[it_index], tprint("assets/models/priestess/%.animbin", name), name, joints));
    }
    animator_init(*s.animator, *s.priestess);

    sokoban_reset_level();
    s.loaded = true;
}

sokoban_shutdown :: () {
    s := *sokoban;
    world_free(*s.world);
    animator_free(*s.animator);
    animation_free(*s.idle);
    animation_free(*s.walk);
    animation_free(*s.push);
    for * s.turns animation_free(it);
    for * s.push_turns animation_free(it);
    for * s.blocked_clips animation_free(it);
    for * s.textures free_texture(it);
    array_free(s.textures);
    array_free(s.crystal_textures);
    array_free(s.priestess_textures);
    free_mesh(*s.cube);
    free_mesh(*s.crystal_mesh);
    free_mesh(*s.priestess_mesh);
    model_free(*s.crystal);
    model_free(*s.priestess);
    s.loaded = false;
}

// 初始关卡：8x8 棋盘地面，一圈矮墙，几个台阶，两个箱子两个目标。
sokoban_reset_level :: () {
    s := *sokoban;
    world_free(*s.world);
    s.player = -1;
    s.busy = false;
    s.blocked = false;
    s.pushed_box = -1;
    s.move_count = 0;
    s.solved = false;
    s.facing = 0;
    s.visual_facing = 0;

    for z: -4..3 for x: -4..3 sokoban_add_block(.{xx x, -1, xx z});
    // 墙。
    for x: -4..3 { sokoban_add_block(.{xx x, 0, -4}); sokoban_add_block(.{xx x, 0, 3}); }
    for z: -3..2 { sokoban_add_block(.{-4, 0, xx z}); sokoban_add_block(.{3, 0, xx z}); }
    // 台阶：能走上去的高台。
    sokoban_add_block(.{2, 0, 1}); sokoban_add_block(.{2, 0, 2});
    sokoban_add_block(.{1, 0, 2});
    sokoban_add_block(.{2, 1, 2});
    // 障碍。
    sokoban_add_block(.{-2, 0, -1});

    sokoban_add_box(.{-1, 0, -1});
    sokoban_add_box(.{1, 0, -1});
    sokoban_add_goal(.{-1, 0, -3});
    sokoban_add_goal(.{1, 0, -3});
    sokoban_add_player(.{0, 0, 1});

    animator_bind_pose(*s.animator);
    // 从斜上方看整个棋盘。
    camera_look_at(.{0, 9, 11}, .{0, 0, -0.5});
    home_camera = camera;
    lighting = .{};
    lighting.sun_direction = .{-0.4, 0.9, 0.5};
    lighting.sun_intensity = 3;
    lighting.ambient_intensity = 0.4;
    lighting.point_light_count = 0;
    background = .{0.07, 0.09, 0.11};
}

sokoban_add_block :: (cell: Grid_Cell) -> *Entity {
    s := *sokoban;
    checker := (cell.x + cell.z) & 1;
    // 地面深灰棋盘，高处的方块偏蓝，靠颜色区分层。
    color := ifx cell.y < 0 then (ifx checker == 0 then color_rgb(0x525c59) else color_rgb(0x737d78))
                            else (ifx checker == 0 then color_rgb(0x2e4a5a) else color_rgb(0x3b5c6e));
    entity: Entity;
    entity.name = "block";
    entity.kind = .BLOCK;
    entity.cell = cell;
    entity.position = cell_to_position(cell, .BLOCK);
    entity.mesh = *s.cube;
    entity.bounds_min = .{-0.5, -0.5, -0.5};
    entity.bounds_max = .{0.5, 0.5, 0.5};
    entity.material.base_color = color;
    entity.material.roughness = 0.85;
    return world_add(*s.world, entity);
}

sokoban_add_box :: (cell: Grid_Cell) -> *Entity {
    s := *sokoban;
    entity: Entity;
    entity.name = "box";
    entity.kind = .BOX;
    entity.cell = cell;
    entity.position = cell_to_position(cell, .BOX);
    entity.mesh = *s.crystal_mesh;
    entity.bounds_min = s.crystal.bounds_min;
    entity.bounds_max = s.crystal.bounds_max;
    entity.parts = s.crystal.parts;
    entity.part_textures = s.crystal_textures;
    entity.material.roughness = 0.25;
    entity.material.metallic = 0.1;
    entity.material.emissive = .{0.05, 0.09, 0.65};
    entity.material.emissive_strength = 0.15;
    return world_add(*s.world, entity);
}

sokoban_add_goal :: (cell: Grid_Cell) -> *Entity {
    s := *sokoban;
    entity: Entity;
    entity.name = "goal";
    entity.kind = .GOAL;
    entity.cell = cell;
    entity.position = cell_to_position(cell, .GOAL) + .{0, 0.03, 0};
    entity.scale = .{0.9, 0.06, 0.9};
    entity.mesh = *s.cube;
    entity.bounds_min = .{-0.5, -0.5, -0.5};
    entity.bounds_max = .{0.5, 0.5, 0.5};
    entity.material.base_color = color_rgb(0x218a3d);
    entity.material.emissive = .{0.1, 0.5, 0.2};
    entity.material.roughness = 0.6;
    return world_add(*s.world, entity);
}

sokoban_add_player :: (cell: Grid_Cell) -> *Entity {
    s := *sokoban;
    if s.player >= 0 return *s.world.entities[s.player];
    entity: Entity;
    entity.name = "priestess";
    entity.kind = .PLAYER;
    entity.cell = cell;
    entity.position = cell_to_position(cell, .PLAYER);
    entity.mesh = *s.priestess_mesh;
    entity.bounds_min = s.priestess.bounds_min;
    entity.bounds_max = s.priestess.bounds_max;
    entity.parts = s.priestess.parts;
    entity.part_textures = s.priestess_textures;
    entity.skinning = s.animator.skinning;
    entity.material.roughness = 0.75;
    // 源模型面朝 +X；游戏朝向从 +Z 量起，所以先绕 Y 转 -90 度。
    rotation: Quaternion;
    set_from_axis_and_angle(*rotation, 0, 1, 0, -PI * 0.5);
    entity.base_transform = rotation_matrix(Matrix4, rotation);
    world_add(*s.world, entity);
    s.player = cast(s32) (s.world.entities.count - 1);
    return *s.world.entities[s.player];
}

// ----------------------------------------------------------------------------: 每帧更新

Sokoban_Input :: struct {
    direction: Grid_Cell;   // 只用 x / z，取值 -1/0/1
    pressed: bool;          // 本帧新按下
    held: bool;
    run: bool;
    reset: bool;
}

sokoban_update :: (input: Sokoban_Input, dt: float) {
    s := *sokoban;
    if !s.loaded return;
    if input.reset { sokoban_reset_level(); return; }

    // 编辑后同步格子坐标：不在拖动时，把格子类实体吸附回整数格。
    if gizmo.active_axis < 0 then sync_cells(s);
    // 玩家可能被 world_remove 挪了下标，重新找。
    s.player = -1;
    for * s.world.entities if it.kind == .PLAYER { s.player = cast(s32) it_index; break; }
    if s.player < 0 return;
    player := *s.world.entities[s.player];

    // 空闲时接受新命令。
    if !s.busy && (input.pressed || input.held) && (input.direction.x != 0 || input.direction.z != 0) {
        begin_step(s, player, input.direction, input.run);
    }

    // 推进动作。
    if s.busy {
        remaining := dt;
        if s.turn_time < s.turn_duration {
            turn_dt := min(remaining, s.turn_duration - s.turn_time);
            s.turn_time += turn_dt;
            remaining -= turn_dt;
            t := clamp(s.turn_time / s.turn_duration, 0.0, 1.0);
            s.visual_facing = s.turn_from + s.turn_angle * (t * t * (3 - 2 * t));
        }
        if s.turn_time >= s.turn_duration - 0.000001 {
            s.visual_facing = s.facing;
            s.step_time += remaining;
            t := clamp(s.step_time / s.step_duration, 0.0, 1.0);
            if !s.blocked {
                player.position = lerp(s.from, s.to, t);
                if s.pushed_box >= 0 then s.world.entities[s.pushed_box].position = lerp(s.box_from, s.box_to, t);
            }
            if s.step_time >= s.step_duration - 0.000001 {
                s.busy = false;
                if !s.blocked {
                    player.position = s.to;
                    if s.pushed_box >= 0 then s.world.entities[s.pushed_box].position = s.box_to;
                    s.solved = is_solved(s);
                }
                s.blocked = false;
                s.pushed_box = -1;
            }
        }
        // 用动作进度驱动动画进度，保证脚步和位移对齐。
        duration := s.turn_duration + s.step_duration;
        progress := clamp((s.turn_time + s.step_time) / duration, 0.0, 1.0);
        animator_seek(*s.animator, animation_duration(s.animator.clip) * progress, dt);
    } else {
        animator_play(*s.animator, *s.idle);
        animator_update(*s.animator, dt);
    }
    player.yaw = s.visual_facing;

    // 箱子在目标上时提亮。
    for * box: s.world.entities {
        if box.kind != .BOX continue;
        on_goal := world_find_at(*s.world, box.cell, .GOAL) >= 0;
        box.material.base_color = ifx on_goal then color_rgb(0xd9ff8c) else color_rgb(0xffffff);
        box.material.emissive_strength = ifx on_goal then 0.6 else 0.15;
    }
}

// ----------------------------------------------------------------------------: 编辑操作

// 在选中实体旁放置新实体；没有选中就放在原点上方。
sokoban_place :: (kind: Entity_Kind) {
    s := *sokoban;
    cell := Grid_Cell.{0, 1, 0};
    selected := world_selected(*s.world);
    if selected != null then cell = cell_add(selected.cell, 0, 1, 0);
    // 往上找空位。
    for 0..15 {
        if world_find_at(*s.world, cell, .BLOCK) < 0 && world_find_at(*s.world, cell, .BOX) < 0
           && world_find_at(*s.world, cell, kind) < 0 break;
        cell.y += 1;
    }
    if kind == .BLOCK then sokoban_add_block(cell);
    else if kind == .BOX then sokoban_add_box(cell);
    else if kind == .GOAL then sokoban_add_goal(cell);
    s.world.selected = cast(s32) (s.world.entities.count - 1);
}

sokoban_delete_selected :: () {
    s := *sokoban;
    selected := world_selected(*s.world);
    if selected == null || selected.kind == .PLAYER return;
    if s.pushed_box == s.world.selected then s.pushed_box = -1;
    else if s.pushed_box > s.world.selected then s.pushed_box -= 1;   // 前面的实体删了，下标前移
    world_remove(*s.world, s.world.selected);
}

#scope_file

load_part_textures :: (s: *Sokoban, parts: [] Model_Part, directory: string) -> [] Gpu_Texture_View {
    views := NewArray(parts.count, Gpu_Texture_View);
    for part, index: parts {
        if !part.texture_path.count continue;
        // 同一张贴图可能被多个部件引用，按路径去重。
        path := tprint("%/%", directory, part.texture_path);
        found := false;
        for other, other_index: parts {
            if other_index >= index break;
            if other.texture_path == part.texture_path { views[index] = views[other_index]; found = true; break; }
        }
        if found continue;
        texture, ok := load_texture_file(path, srgb = true);
        if !ok continue;
        array_add(*s.textures, texture);
        views[index] = texture.view;
    }
    return views;
}

// gizmo 拖完后，格子类实体回到整数格。
sync_cells :: (s: *Sokoban) {
    for * entity, index: s.world.entities {
        if entity.kind == .MESH continue;
        if entity.kind == .PLAYER && s.busy continue;
        if index == s.pushed_box && s.busy continue;
        offset := ifx entity.kind == .GOAL then Vector3.{0, 0.03, 0} else Vector3.{0, 0, 0};
        entity.cell = position_to_cell(entity.position - offset, entity.kind);
        entity.position = cell_to_position(entity.cell, entity.kind) + offset;
    }
}

has_block :: (s: *Sokoban, cell: Grid_Cell) -> bool { return world_find_at(*s.world, cell, .BLOCK) >= 0; }
has_box :: (s: *Sokoban, cell: Grid_Cell) -> bool { return world_find_at(*s.world, cell, .BOX) >= 0; }
is_free :: (s: *Sokoban, cell: Grid_Cell) -> bool { return !has_block(s, cell) && !has_box(s, cell); }
has_support :: (s: *Sokoban, cell: Grid_Cell) -> bool { return has_block(s, cell_add(cell, 0, -1, 0)); }

// 从 cell 往 direction 走一格，允许上下一格的台阶。返回是否可行和落脚格。
resolve_step :: (s: *Sokoban, cell: Grid_Cell, direction: Grid_Cell) -> bool, Grid_Cell {
    target := cell_add(cell, direction.x, 0, direction.z);
    if has_block(s, target) {
        // 爬台阶：目标格上方要空、再上方（头顶）也不能有方块。
        up := cell_add(target, 0, 1, 0);
        if is_free(s, up) && !has_block(s, cell_add(cell, 0, 1, 0)) return true, up;
        return false, target;
    }
    if has_box(s, target) return false, target;   // 箱子由调用方处理
    if has_support(s, target) return true, target;
    down := cell_add(target, 0, -1, 0);
    if is_free(s, down) && has_support(s, down) return true, down;   // 下台阶
    return false, target;
}

begin_step :: (s: *Sokoban, player: *Entity, direction: Grid_Cell, run: bool) {
    target := cell_add(player.cell, direction.x, 0, direction.z);
    box := world_find_at(*s.world, target, .BOX);
    ok, landing := resolve_step(s, player.cell, direction);
    box_landing: Grid_Cell;
    if box >= 0 {
        // 推箱子：箱子只在同一高度平移，落点要空且有支撑。
        box_landing = cell_add(target, direction.x, 0, direction.z);
        ok = is_free(s, box_landing) && has_support(s, box_landing);
        landing = target;
    }

    facing := atan2(cast(float) direction.x, cast(float) direction.z);
    turn_to(s, facing, run);
    s.busy = true;
    s.step_time = 0;
    s.blocked = !ok;
    s.running = run;
    s.pushed_box = -1;
    motion := Motion.WALK;

    if !ok {
        // 撞墙动作不改变位置，但仍占用一段时间。
        duration: float = ifx s.turn == .NONE then 0.7 else 5.0 / 3;
        if run then duration *= 0.5;
        s.step_duration = max(duration - s.turn_duration, 0.1);
        motion = .BLOCKED;
    } else {
        s.from = player.position;
        s.to = cell_to_position(landing, .PLAYER);
        player.cell = landing;
        if box >= 0 {
            s.pushed_box = cast(s32) box;
            entity := *s.world.entities[box];
            s.box_from = entity.position;
            s.box_to = cell_to_position(box_landing, .BOX);
            entity.cell = box_landing;
            motion = .PUSH;
        }
        s.step_duration = ifx run then 0.175 else 0.35;
        s.move_count += 1;
        s.solved = false;
    }

    clip := motion_clip(s, motion, s.turn);
    animator_play(*s.animator, clip, looping = false, restart = true);
}

// 解析转向：正 Y 旋转是左转；180 度统一按右转（片段只有 180Right）。
turn_to :: (s: *Sokoban, facing: float, run: bool) {
    angle := fmod_cycling(facing - s.visual_facing + PI, 2 * PI) - PI;
    s.turn = .NONE;
    s.turn_from = s.visual_facing;
    s.turn_angle = angle;
    s.turn_time = 0;
    s.turn_duration = 0;
    s.facing = facing;
    if abs(angle) < 0.0001 { s.visual_facing = facing; return; }
    s.turn = ifx abs(angle) > PI * 0.75 then Turn.BACK else ifx angle > 0 then Turn.LEFT else Turn.RIGHT;
    s.turn_duration = ifx s.turn == .BACK then 0.32 else 0.22;
    if run then s.turn_duration *= 0.5;
}

motion_clip :: (s: *Sokoban, motion: Motion, turn: Turn) -> *Animation_Clip {
    if motion == .BLOCKED return *s.blocked_clips[turn.(s64)];
    if turn != .NONE {
        index := turn.(s64) - 1;
        return ifx motion == .PUSH then *s.push_turns[index] else *s.turns[index];
    }
    return ifx motion == .PUSH then *s.push else *s.walk;
}

is_solved :: (s: *Sokoban) -> bool {
    any := false;
    for * box: s.world.entities {
        if box.kind != .BOX continue;
        any = true;
        if world_find_at(*s.world, box.cell, .GOAL) < 0 return false;
    }
    return any;
}
