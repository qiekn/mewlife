// ----------------------------------------------------------------------------: 演示场景 1：PBR 头盔
//
// 加载 glTF 的 DamagedHelmet，每个（节点，图元）对生成一个实体，材质贴图上传为 bindless 纹理。
// 四盏点光源环绕头盔，可以在 UI 里调材质和光照参数，对照 debug view 检查每一项。

Helmet_Scene :: struct {
    world: World;
    model: Gltf_Model;
    mesh: Mesh;
    textures: [..] Texture;    // 与 model.images 一一对应；解码失败的槽位 view 为 0
    loaded: bool;
    turntable: bool;           // 自动旋转
}

helmet: Helmet_Scene;

helmet_init :: () {
    ok: bool;
    helmet.model, ok = load_gltf("assets/models/damaged_helmet/DamagedHelmet.glb");
    if !ok { log_error("Helmet scene: model failed to load."); return; }
    model := *helmet.model;

    // glTF 顶点 -> 渲染器顶点（补上蒙皮字段的默认值）。
    vertices := NewArray(model.vertices.count, Vertex);
    defer array_free(vertices);
    for v, index: model.vertices {
        vertices[index] = .{position = v.position, normal = v.normal, uv = v.uv, tangent = v.tangent};
    }
    helmet.mesh = upload_mesh(vertices, model.indices);

    for image: model.images {
        texture: Texture;
        if image.pixels != null {
            texture = create_texture_rgba8(image.pixels, image.width, image.height, image.srgb, label = image.name);
        }
        array_add(*helmet.textures, texture);
    }

    for node, node_index: model.nodes {
        if node.mesh < 0 continue;
        for prim, prim_index: model.meshes[node.mesh].primitives {
            entity: Entity;
            entity.name = ifx node.name.count then node.name else "helmet";
            entity.kind = .MESH;
            entity.mesh = *helmet.mesh;
            entity.first_index = prim.first_index;
            entity.index_count = prim.index_count;
            entity.base_transform = node.world;
            entity.bounds_min = prim.bounds_min;
            entity.bounds_max = prim.bounds_max;
            entity.material = make_material(prim.material);
            world_add(*helmet.world, entity);
        }
    }

    helmet.loaded = true;
    helmet_setup_lights();
    helmet_frame_camera();
}

helmet_shutdown :: () {
    world_free(*helmet.world);
    for * helmet.textures free_texture(it);
    array_free(helmet.textures);
    free_mesh(*helmet.mesh);
    gltf_free(*helmet.model);
    helmet.loaded = false;
}

helmet_update :: (dt: float) {
    if !helmet.loaded return;
    if helmet.turntable {
        for * helmet.world.entities it.yaw += dt * 0.4;
    }
}

helmet_setup_lights :: () {
    lighting = .{};
    lighting.sun_direction = .{0.3, 0.9, 0.4};
    lighting.sun_intensity = 2;
    lighting.ambient_intensity = 0.35;
    lighting.point_light_count = 4;
    // 四盏灯呈正方形放在头盔前上方，和参考项目的布局一致。
    for i: 0..3 {
        x := ifx i & 1 then 3.0 else -3.0;
        y := ifx i & 2 then 3.0 else -3.0;
        lighting.point_lights[i] = .{position = .{x, y, 4}, radius = 20, color = .{1, 1, 1}, intensity = 40};
    }
    background = .{0.03, 0.03, 0.04};
}

helmet_frame_camera :: () {
    center := (helmet.model.bounds_min + helmet.model.bounds_max) * 0.5;
    extent := helmet.model.bounds_max - helmet.model.bounds_min;
    radius := max(max(extent.x, extent.y), extent.z) * 0.5;
    distance := radius / tan(camera.fov * 0.5) * 1.4;
    camera_look_at(center + Vector3.{distance * 0.4, distance * 0.3, distance}, center);
    home_camera = camera;
}

#scope_file

make_material :: (material_index: s32) -> Material {
    result: Material;
    if material_index < 0 || material_index >= helmet.model.materials.count return result;
    m := helmet.model.materials[material_index];
    result.base_color = m.base_color;
    result.metallic = m.metallic;
    result.roughness = m.roughness;
    result.emissive = m.emissive;
    if m.double_sided then result.flags |= .DOUBLE_SIDED;
    bind :: (image: s32, slot: *Gpu_Texture_View, flag: Material_Flags, result: *Material) #expand {
        if image >= 0 && image < helmet.textures.count && helmet.textures[image].view != 0 {
            slot.* = helmet.textures[image].view;
            result.flags |= flag;
        }
    }
    bind(m.base_color_image, *result.base_color_map, .HAS_BASE_COLOR_MAP, *result);
    bind(m.metallic_roughness_image, *result.metallic_roughness_map, .HAS_METALLIC_ROUGHNESS_MAP, *result);
    bind(m.normal_image, *result.normal_map, .HAS_NORMAL_MAP, *result);
    bind(m.occlusion_image, *result.occlusion_map, .HAS_OCCLUSION_MAP, *result);
    bind(m.emissive_image, *result.emissive_map, .HAS_EMISSIVE_MAP, *result);
    return result;
}
