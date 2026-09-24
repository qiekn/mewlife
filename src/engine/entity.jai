// ----------------------------------------------------------------------------: 实体与世界
//
// 不做 ECS：一个实体就是一个普通结构体，字段按需使用。世界是实体的动态数组，
// 选中项用下标记录。每帧由 world_build_draws 把实体翻译成渲染器的 Draw 列表。

Entity_Kind :: enum u8 {
    MESH;     // 普通静态网格（头盔的每个图元）
    BLOCK;    // 组成地面/墙的单位立方体，占一个格子
    BOX;      // 可推动的箱子，占一个格子
    GOAL;     // 目标格标记
    PLAYER;   // 角色（蒙皮）
}

Grid_Cell :: struct { x, y, z: s32; }

Entity :: struct {
    name: string;                      // 静态字符串或由场景拥有
    kind: Entity_Kind;
    position: Vector3;                 // 世界位置
    yaw: float;                        // 绕 Y 轴旋转
    scale := Vector3.{1, 1, 1};
    base_transform := Matrix4_Identity;   // 位于 TRS 之后的固定变换（glTF 节点矩阵、模型朝向修正）
    cell: Grid_Cell;                   // 格子类实体的逻辑位置
    mesh: *Mesh;
    first_index: u32;
    index_count: u32;                  // 0 表示整个网格
    material: Material;
    bounds_min, bounds_max: Vector3;   // 网格局部包围盒（在 base_transform 之前的空间）
    skinning: [] Matrix4;              // 非空则蒙皮
    parts: [] Model_Part;              // 多材质模型：按部件分次绘制（贴图在 part_textures 里）
    part_textures: [] Gpu_Texture_View;
    selectable := true;
}

World :: struct {
    entities: [..] Entity;
    selected: s32 = -1;
    instances: [..] Instance;   // 每帧重建：BLOCK 的实例化数据
    draws: [..] Draw;           // 每帧重建
}

world_free :: (world: *World) {
    array_free(world.entities);
    array_free(world.instances);
    array_free(world.draws);
    world.* = .{};
}

world_add :: (world: *World, entity: Entity) -> *Entity {
    array_add(*world.entities, entity);
    return *world.entities[world.entities.count - 1];
}

world_remove :: (world: *World, index: s64) {
    if index < 0 || index >= world.entities.count return;
    array_ordered_remove_by_index(*world.entities, index);
    if world.selected == index then world.selected = -1;
    else if world.selected > index then world.selected -= 1;
}

world_selected :: (world: *World) -> *Entity {
    if world.selected < 0 || world.selected >= world.entities.count return null;
    return *world.entities[world.selected];
}

// 格子中心与实体位置的约定：格子 (x, y, z) 是一个单位立方体区域，
// BLOCK 的中心在 (x, y + 0.5, z)；BOX / PLAYER / GOAL 的位置是格子底面中心 (x, y, z)。
cell_to_position :: (cell: Grid_Cell, kind: Entity_Kind) -> Vector3 {
    p := Vector3.{xx cell.x, xx cell.y, xx cell.z};
    if kind == .BLOCK then p.y += 0.5;
    return p;
}

position_to_cell :: (position: Vector3, kind: Entity_Kind) -> Grid_Cell {
    p := position;
    if kind == .BLOCK then p.y -= 0.5;
    return .{xx floor(p.x + 0.5), xx floor(p.y + 0.5), xx floor(p.z + 0.5)};
}

cell_equal :: (a: Grid_Cell, b: Grid_Cell) -> bool { return a.x == b.x && a.y == b.y && a.z == b.z; }
cell_add :: (a: Grid_Cell, dx: s32, dy: s32, dz: s32) -> Grid_Cell { return .{a.x + dx, a.y + dy, a.z + dz}; }

// 在格子里找某类实体，返回下标或 -1。
world_find_at :: (world: *World, cell: Grid_Cell, kind: Entity_Kind) -> s64 {
    for * world.entities if it.kind == kind && cell_equal(it.cell, cell) return it_index;
    return -1;
}

entity_model_matrix :: (entity: *Entity) -> Matrix4 {
    rotation: Quaternion;
    set_from_axis_and_angle(*rotation, 0, 1, 0, entity.yaw);
    return make_translation_matrix4(entity.position) * rotation_matrix(Matrix4, rotation)
         * make_scale_matrix4(entity.scale) * entity.base_transform;
}

// 把实体列表翻译成 Draw。连续的 BLOCK 合并成一个实例化绘制。
world_build_draws :: (world: *World) -> [] Draw {
    array_reset(*world.draws);
    array_reset(*world.instances);

    block_draw := -1;   // 当前正在累积的实例化 Draw 的下标
    for * entity, index: world.entities {
        if entity.mesh == null continue;
        model := entity_model_matrix(entity);

        if entity.kind == .BLOCK {
            // 所有 BLOCK 共用一个网格和材质，只有矩阵和颜色不同（颜色走实例，材质底色置白）。
            if block_draw < 0 {
                material := entity.material;
                material.base_color = .{1, 1, 1, 1};
                array_add(*world.draws, .{mesh = entity.mesh, material = material});
                block_draw = world.draws.count - 1;
            }
            array_add(*world.instances, .{model, entity.material.base_color});
            continue;
        }

        if entity.parts.count {
            for part, part_index: entity.parts {
                if part.optional continue;
                material := entity.material;
                material.base_color = entity.material.base_color * part.color;
                if part_index < entity.part_textures.count && entity.part_textures[part_index] != 0 {
                    material.base_color_map = entity.part_textures[part_index];
                    material.flags |= .HAS_BASE_COLOR_MAP;
                }
                array_add(*world.draws, .{
                    mesh = entity.mesh, first_index = part.first_index, index_count = part.index_count,
                    material = material, model = model, skinning = entity.skinning,
                });
            }
        } else {
            array_add(*world.draws, .{
                mesh = entity.mesh, first_index = entity.first_index, index_count = entity.index_count,
                material = entity.material, model = model, skinning = entity.skinning,
            });
        }
    }
    // 实例数组在循环里可能重新分配，最后再把视图挂上去。
    if block_draw >= 0 then world.draws[block_draw].instances = world.instances;
    return world.draws;
}

// ----------------------------------------------------------------------------: 拾取

Ray :: struct { origin, direction: Vector3; }

// 把屏幕像素反投影成世界空间射线：近平面点和远平面点相减。
// 投影矩阵输出 y 朝上的裁剪坐标（Vulkan 的 Y 翻转由 Slang 在着色器里做），所以鼠标 y 要翻转。
camera_ray :: (mouse: Vector2, viewport: Vector2) -> Ray {
    ndc_x := 2 * mouse.x / max(viewport.x, 1) - 1;
    ndc_y := 1 - 2 * mouse.y / max(viewport.y, 1);
    ok, inverse_vp := inverse(view_projection(viewport.x / max(viewport.y, 1)));
    if !ok return .{camera.position, camera_forward()};
    near := inverse_vp * Vector4.{ndc_x, ndc_y, 0, 1};
    far  := inverse_vp * Vector4.{ndc_x, ndc_y, 1, 1};
    near_point := near.xyz / near.w;
    far_point  := far.xyz / far.w;
    return .{near_point, unit_vector(far_point - near_point)};
}

// 射线与实体局部包围盒求交（slab 法）。把射线变换到实体局部空间，包围盒就保持轴对齐。
ray_hits_entity :: (ray: Ray, entity: *Entity) -> bool, float {
    ok, inverse_model := inverse(entity_model_matrix(entity));
    if !ok return false, 0;
    origin := transform_point(inverse_model, ray.origin);
    direction := transform_vector(inverse_model, ray.direction);   // 不归一化，这样 t 与世界空间一致

    t_min := -FLOAT32_MAX;
    t_max :=  FLOAT32_MAX;
    for axis: 0..2 {
        d := direction.component[axis];
        o := origin.component[axis];
        lo := entity.bounds_min.component[axis];
        hi := entity.bounds_max.component[axis];
        if abs(d) < 0.000001 {
            if o < lo || o > hi return false, 0;
            continue;
        }
        t1 := (lo - o) / d;
        t2 := (hi - o) / d;
        if t1 > t2 then t1, t2 = t2, t1;
        t_min = max(t_min, t1);
        t_max = min(t_max, t2);
        if t_min > t_max return false, 0;
    }
    if t_max < 0 return false, 0;
    return true, ifx t_min >= 0 then t_min else t_max;
}

// 返回射线命中的最近实体下标，没有则 -1。
world_pick :: (world: *World, ray: Ray) -> s64 {
    best := -1;
    best_t := FLOAT32_MAX;
    for * entity, index: world.entities {
        if !entity.selectable || entity.mesh == null continue;
        hit, t := ray_hits_entity(ray, entity);
        if hit && t < best_t { best = index; best_t = t; }
    }
    return best;
}
