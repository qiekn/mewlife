// ----------------------------------------------------------------------------: glTF 2.0 加载器
//
// 用法：
//     #import "gltf";
//     model, ok := load_gltf("assets/models/damaged_helmet/DamagedHelmet.glb");
//     defer gltf_free(*model);
//
// 支持 .glb（二进制容器）和 .gltf（JSON + 外部 .bin / 图片）。JSON 由 jaison 解析。读取：
//   - 节点层级（TRS 或 matrix），算出每个节点的世界矩阵
//   - 网格图元：POSITION / NORMAL / TEXCOORD_0 / TANGENT，索引 u8/u16/u32；缺切线时用 uv 导数自己算
//   - 材质：metallic-roughness 工作流的因子和五张贴图
//   - 图片：bufferView 内嵌或外部文件，用 stb_image 解码成 RGBA8
// 不支持：sparse accessor、动画、蒙皮、KHR 扩展、data: URI。

// 所有图元共用一份顶点/索引数组，图元只记录范围。
Gltf_Vertex :: struct {
    position: Vector3;
    normal:   Vector3;
    uv:       Vector2;
    tangent:  Vector4;   // xyz 切线，w 是副切线符号（glTF 约定）
}

Gltf_Primitive :: struct {
    first_index: u32;    // 索引数组中的起点；索引已加上顶点基址，直接可用
    index_count: u32;
    material: s32 = -1;
    bounds_min, bounds_max: Vector3;   // 局部空间
}

Gltf_Mesh :: struct {
    name: string;
    primitives: [] Gltf_Primitive;
}

Gltf_Material :: struct {
    name: string;
    base_color := Vector4.{1, 1, 1, 1};
    metallic: float = 1;
    roughness: float = 1;
    emissive: Vector3;
    // 以下均为 images 数组的下标，-1 表示无。
    base_color_image: s32 = -1;
    metallic_roughness_image: s32 = -1;
    normal_image: s32 = -1;
    occlusion_image: s32 = -1;
    emissive_image: s32 = -1;
    double_sided: bool;
}

Gltf_Image :: struct {
    name: string;
    pixels: *u8;         // RGBA8，stb_image 分配
    width, height: s32;
    srgb: bool;          // 被 baseColor / emissive 引用则为 sRGB，其余是线性数据
}

Gltf_Node :: struct {
    name: string;
    mesh: s32 = -1;
    parent: s32 = -1;
    local: Matrix4 = Matrix4_Identity;
    world: Matrix4 = Matrix4_Identity;
}

Gltf_Model :: struct {
    vertices: [..] Gltf_Vertex;
    indices:  [..] u32;
    meshes:    [..] Gltf_Mesh;
    materials: [..] Gltf_Material;
    images:    [..] Gltf_Image;
    nodes:     [..] Gltf_Node;
    bounds_min, bounds_max: Vector3;   // 所有带网格节点在世界空间的包围盒
    strings: [..] string;              // 拥有所有 name 字符串
}

load_gltf :: (path: string) -> Gltf_Model, bool {
    model: Gltf_Model;
    file, ok := read_entire_file(path);
    if !ok { log_error("Could not read glTF file '%'.", path); return model, false; }
    defer free(file);

    json_text := file;
    glb_bin: string;
    if file.count >= 12 && slice(file, 0, 4) == "glTF" {
        json_text, glb_bin, ok = split_glb(file);
        if !ok { log_error("'%': malformed GLB container.", path); return model, false; }
    }

    root, parsed := json_parse(json_text);
    if !parsed { log_error("'%': JSON parse failed.", path); return model, false; }
    defer json_release(root);

    directory := path_strip_filename(path);
    ctx := Loader.{model = *model, root = root, glb_bin = glb_bin, directory = directory};
    defer {
        for ctx.buffers if it.owned then free(it.bytes);
        array_free(ctx.buffers);
    }

    if !load_buffers(*ctx) { gltf_free(*model); return model, false; }
    load_images(*ctx);
    load_materials(*ctx);
    if !load_meshes(*ctx) { gltf_free(*model); return model, false; }
    load_nodes(*ctx);
    compute_bounds(*model);

    log("Loaded '%': % vertices, % triangles, % meshes, % materials, % images, % nodes.",
        path, model.vertices.count, model.indices.count / 3, model.meshes.count,
        model.materials.count, model.images.count, model.nodes.count);
    return model, true;
}

gltf_free :: (model: *Gltf_Model) {
    array_free(model.vertices);
    array_free(model.indices);
    for model.meshes array_free(it.primitives);
    array_free(model.meshes);
    array_free(model.materials);
    for model.images if it.pixels then stbi_image_free(it.pixels);
    array_free(model.images);
    array_free(model.nodes);
    for model.strings free(it);
    array_free(model.strings);
    model.* = .{};
}

#scope_file

Buffer :: struct { bytes: string; owned: bool; }

Loader :: struct {
    model: *Gltf_Model;
    root: *Json;
    glb_bin: string;
    directory: string;
    buffers: [..] Buffer;
}

// GLB：12 字节头，然后是若干 chunk（长度、类型、数据）。第一个是 JSON，第二个（可选）是 BIN。
split_glb :: (file: string) -> json: string, bin: string, ok: bool {
    at := 12;
    json, bin: string;
    while at + 8 <= file.count {
        length := (cast(*u32) (file.data + at)).*;
        type   := (cast(*u32) (file.data + at + 4)).*;
        at += 8;
        if at + length > file.count return "", "", false;
        chunk := string.{length, file.data + at};
        if type == 0x4E4F534A then json = chunk;   // "JSON"
        else if type == 0x004E4942 then bin = chunk;   // "BIN\0"
        at += length;
    }
    return json, bin, json.count > 0;
}

own_string :: (ctx: *Loader, s: string) -> string {
    if !s.count return "";
    copy := copy_string(s);
    array_add(*ctx.model.strings, copy);
    return copy;
}

load_buffers :: (ctx: *Loader) -> bool {
    buffers := json_get(ctx.root, "buffers");
    for i: 0..json_count(buffers) - 1 {
        entry := json_at(buffers, i);
        uri := json_string(json_get(entry, "uri"));
        buffer: Buffer;
        if !uri.count {
            buffer.bytes = ctx.glb_bin;   // GLB 的 BIN chunk
        } else if begins_with(uri, "data:") {
            log_error("glTF data: URIs are not supported.");
            return false;
        } else {
            bytes, ok := read_entire_file(tprint("%1%2", ctx.directory, uri));
            if !ok { log_error("Could not read glTF buffer '%'.", uri); return false; }
            buffer = .{bytes, true};
        }
        array_add(*ctx.buffers, buffer);
    }
    return true;
}

// bufferView 的字节范围。
buffer_view_bytes :: (ctx: *Loader, view_index: s64) -> string, stride: s64 {
    view := json_at(json_get(ctx.root, "bufferViews"), view_index);
    if view == null return "", 0;
    buffer_index := json_int(view, "buffer");
    if buffer_index < 0 || buffer_index >= ctx.buffers.count return "", 0;
    bytes := ctx.buffers[buffer_index].bytes;
    offset := json_int(view, "byteOffset", 0);
    length := json_int(view, "byteLength", 0);
    if offset < 0 || length < 0 || offset + length > bytes.count return "", 0;
    return slice(bytes, offset, length), json_int(view, "byteStride", 0);
}

// 一个 accessor 的解析结果：起始地址、元素个数、每元素字节跨度、分量类型和分量数。
Accessor :: struct {
    data: *u8;
    count: s64;
    stride: s64;
    component_type: s64;   // 5120 s8, 5121 u8, 5122 s16, 5123 u16, 5125 u32, 5126 f32
    components: s64;       // SCALAR 1, VEC2 2, VEC3 3, VEC4 4, MAT4 16
    normalized: bool;
}

component_size :: (component_type: s64) -> s64 {
    if component_type == 5120 || component_type == 5121 return 1;
    if component_type == 5122 || component_type == 5123 return 2;
    return 4;
}

read_accessor :: (ctx: *Loader, index: s64) -> Accessor, bool {
    accessor := json_at(json_get(ctx.root, "accessors"), index);
    if accessor == null return .{}, false;
    if json_get(accessor, "sparse") != null { log_error("glTF sparse accessors are not supported."); return .{}, false; }

    result: Accessor;
    result.count = json_int(accessor, "count", 0);
    result.component_type = json_int(accessor, "componentType", 5126);
    result.normalized = json_bool(accessor, "normalized");
    type := json_string(json_get(accessor, "type"));
    if type == "SCALAR" then result.components = 1;
    else if type == "VEC2" then result.components = 2;
    else if type == "VEC3" then result.components = 3;
    else if type == "VEC4" then result.components = 4;
    else if type == "MAT4" then result.components = 16;
    else return .{}, false;

    view_index := json_int(accessor, "bufferView");
    if view_index < 0 return .{}, false;   // 没有 bufferView 的 accessor 全零，不支持
    bytes, stride := buffer_view_bytes(ctx, view_index);
    element_size := component_size(result.component_type) * result.components;
    if stride == 0 then stride = element_size;
    offset := json_int(accessor, "byteOffset", 0);
    if result.count > 0 && offset + (result.count - 1) * stride + element_size > bytes.count return .{}, false;
    result.data = bytes.data + offset;
    result.stride = stride;
    return result, true;
}

// 读取第 i 个元素的第 c 个分量，转成 float（整数按 normalized 规则归一化或直接转换）。
accessor_float :: (a: Accessor, i: s64, c: s64) -> float {
    p := a.data + i * a.stride + c * component_size(a.component_type);
    if a.component_type == {
        case 5126; return (cast(*float) p).*;
        case 5121; v := (cast(*u8) p).*;  return ifx a.normalized then v / 255.0 else cast(float) v;
        case 5123; v := (cast(*u16) p).*; return ifx a.normalized then v / 65535.0 else cast(float) v;
        case 5120; v := (cast(*s8) p).*;  return ifx a.normalized then max(v / 127.0, -1.0) else cast(float) v;
        case 5122; v := (cast(*s16) p).*; return ifx a.normalized then max(v / 32767.0, -1.0) else cast(float) v;
        case 5125; return cast(float) (cast(*u32) p).*;
    }
    return 0;
}

accessor_u32 :: (a: Accessor, i: s64) -> u32 {
    p := a.data + i * a.stride;
    if a.component_type == {
        case 5121; return (cast(*u8) p).*;
        case 5123; return (cast(*u16) p).*;
        case 5125; return (cast(*u32) p).*;
    }
    return 0;
}

load_images :: (ctx: *Loader) {
    // 先看材质里谁把图片当颜色用，决定 sRGB。
    images := json_get(ctx.root, "images");
    textures := json_get(ctx.root, "textures");
    srgb := NewArray(json_count(images), bool);
    defer array_free(srgb);
    materials := json_get(ctx.root, "materials");
    for m: 0..json_count(materials) - 1 {
        material := json_at(materials, m);
        pbr := json_get(material, "pbrMetallicRoughness");
        for slot: (*Json).[json_get(pbr, "baseColorTexture"), json_get(material, "emissiveTexture")] {
            image := texture_image_index(ctx, slot);
            if image >= 0 && image < srgb.count then srgb[image] = true;
        }
    }

    for i: 0..json_count(images) - 1 {
        entry := json_at(images, i);
        image: Gltf_Image;
        image.name = own_string(ctx, json_string(json_get(entry, "name")));
        image.srgb = srgb[i];

        encoded: string;
        owned := false;
        view_index := json_int(entry, "bufferView");
        uri := json_string(json_get(entry, "uri"));
        if view_index >= 0 {
            encoded = buffer_view_bytes(ctx, view_index);
        } else if uri.count && !begins_with(uri, "data:") {
            ok: bool;
            encoded, ok = read_entire_file(tprint("%1%2", ctx.directory, uri));
            if !ok then log_error("Could not read glTF image '%'.", uri);
            owned = ok;
        }
        defer if owned then free(encoded);

        if encoded.count {
            channels: s32;
            stbi_set_flip_vertically_on_load(0);   // glTF 的 uv (0,0) 在图片左上角，与 stb 一致
            image.pixels = stbi_load_from_memory(encoded.data, cast(s32) encoded.count,
                                                 *image.width, *image.height, *channels, 4);
            if image.pixels == null then log_error("glTF image % failed to decode: %", i, to_string(stbi_failure_reason()));
        }
        array_add(*ctx.model.images, image);
    }
}

// textureInfo 对象 { "index": texture } -> 图片下标。
texture_image_index :: (ctx: *Loader, info: *Json) -> s32 {
    if info == null return -1;
    texture_index := json_int(info, "index");
    texture := json_at(json_get(ctx.root, "textures"), texture_index);
    if texture == null return -1;
    return cast(s32) json_int(texture, "source");
}

read_vector :: (node: *Json, key: string, default: Vector4) -> Vector4 {
    array := json_get(node, key);
    if array == null || array.type != .ARRAY return default;
    result := default;
    for c: 0..min(json_count(array), 4) - 1 {
        result.component[c] = cast(float) json_number(json_at(array, c));
    }
    return result;
}

load_materials :: (ctx: *Loader) {
    materials := json_get(ctx.root, "materials");
    for i: 0..json_count(materials) - 1 {
        entry := json_at(materials, i);
        material: Gltf_Material;
        material.name = own_string(ctx, json_string(json_get(entry, "name")));
        pbr := json_get(entry, "pbrMetallicRoughness");
        material.base_color = read_vector(pbr, "baseColorFactor", .{1, 1, 1, 1});
        material.metallic = json_float(pbr, "metallicFactor", 1);
        material.roughness = json_float(pbr, "roughnessFactor", 1);
        material.emissive = read_vector(entry, "emissiveFactor", .{0, 0, 0, 0}).xyz;
        material.base_color_image = texture_image_index(ctx, json_get(pbr, "baseColorTexture"));
        material.metallic_roughness_image = texture_image_index(ctx, json_get(pbr, "metallicRoughnessTexture"));
        material.normal_image = texture_image_index(ctx, json_get(entry, "normalTexture"));
        material.occlusion_image = texture_image_index(ctx, json_get(entry, "occlusionTexture"));
        material.emissive_image = texture_image_index(ctx, json_get(entry, "emissiveTexture"));
        material.double_sided = json_bool(entry, "doubleSided");
        array_add(*ctx.model.materials, material);
    }
}

load_meshes :: (ctx: *Loader) -> bool {
    model := ctx.model;
    meshes := json_get(ctx.root, "meshes");
    for m: 0..json_count(meshes) - 1 {
        entry := json_at(meshes, m);
        mesh: Gltf_Mesh;
        mesh.name = own_string(ctx, json_string(json_get(entry, "name")));
        primitives := json_get(entry, "primitives");
        list: [..] Gltf_Primitive;
        for p: 0..json_count(primitives) - 1 {
            prim_json := json_at(primitives, p);
            mode := json_int(prim_json, "mode", 4);
            if mode != 4 { log("glTF: skipping non-triangle primitive (mode %).", mode); continue; }

            attributes := json_get(prim_json, "attributes");
            position_index := json_int(attributes, "POSITION");
            if position_index < 0 continue;
            positions, ok := read_accessor(ctx, position_index);
            if !ok || positions.components != 3 return false;

            has_normal, has_uv, has_tangent := false;
            normals, uvs, tangents: Accessor;
            if json_int(attributes, "NORMAL") >= 0     then normals, has_normal   = read_accessor(ctx, json_int(attributes, "NORMAL"));
            if json_int(attributes, "TEXCOORD_0") >= 0 then uvs, has_uv          = read_accessor(ctx, json_int(attributes, "TEXCOORD_0"));
            if json_int(attributes, "TANGENT") >= 0    then tangents, has_tangent = read_accessor(ctx, json_int(attributes, "TANGENT"));

            base_vertex := cast(u32) model.vertices.count;
            prim: Gltf_Primitive;
            prim.material = cast(s32) json_int(prim_json, "material");
            prim.bounds_min = .{ FLOAT32_MAX,  FLOAT32_MAX,  FLOAT32_MAX};
            prim.bounds_max = .{-FLOAT32_MAX, -FLOAT32_MAX, -FLOAT32_MAX};

            for v: 0..positions.count - 1 {
                vertex: Gltf_Vertex;
                vertex.position = .{accessor_float(positions, v, 0), accessor_float(positions, v, 1), accessor_float(positions, v, 2)};
                if has_normal then vertex.normal = .{accessor_float(normals, v, 0), accessor_float(normals, v, 1), accessor_float(normals, v, 2)};
                if has_uv then vertex.uv = .{accessor_float(uvs, v, 0), accessor_float(uvs, v, 1)};
                if has_tangent then vertex.tangent = .{accessor_float(tangents, v, 0), accessor_float(tangents, v, 1),
                                                       accessor_float(tangents, v, 2), accessor_float(tangents, v, 3)};
                prim.bounds_min = component_min(prim.bounds_min, vertex.position);
                prim.bounds_max = component_max(prim.bounds_max, vertex.position);
                array_add(*model.vertices, vertex);
            }

            prim.first_index = cast(u32) model.indices.count;
            indices_index := json_int(prim_json, "indices");
            if indices_index >= 0 {
                indices, indices_ok := read_accessor(ctx, indices_index);
                if !indices_ok return false;
                for i: 0..indices.count - 1 array_add(*model.indices, base_vertex + accessor_u32(indices, i));
            } else {
                for v: 0..positions.count - 1 array_add(*model.indices, base_vertex + cast(u32) v);
            }
            prim.index_count = cast(u32) model.indices.count - prim.first_index;

            vertex_range := array_view(model.vertices, base_vertex, positions.count);
            index_range := array_view(model.indices, prim.first_index, prim.index_count);
            if !has_normal then compute_normals(vertex_range, index_range, base_vertex);
            if !has_tangent then compute_tangents(vertex_range, index_range, base_vertex);
            array_add(*list, prim);
        }
        mesh.primitives = list;
        array_add(*model.meshes, mesh);
    }
    return true;
}

component_min :: (a: Vector3, b: Vector3) -> Vector3 { return .{min(a.x, b.x), min(a.y, b.y), min(a.z, b.z)}; }
component_max :: (a: Vector3, b: Vector3) -> Vector3 { return .{max(a.x, b.x), max(a.y, b.y), max(a.z, b.z)}; }

compute_normals :: (vertices: [] Gltf_Vertex, indices: [] u32, base: u32) {
    for * vertices it.normal = .{};
    i := 0;
    while i + 2 < indices.count {
        a := *vertices[indices[i] - base];
        b := *vertices[indices[i + 1] - base];
        c := *vertices[indices[i + 2] - base];
        n := cross(b.position - a.position, c.position - a.position);
        a.normal += n; b.normal += n; c.normal += n;
        i += 3;
    }
    for * vertices if dot(it.normal, it.normal) > 0.000001 then it.normal = unit_vector(it.normal);
}

// 每个三角形由位置差与 uv 差解出切线/副切线，累加到顶点，最后对法线做 Gram-Schmidt 正交化。
// w 记录副切线的手性，让着色器能用 cross(n, t) * w 重建副切线。
compute_tangents :: (vertices: [] Gltf_Vertex, indices: [] u32, base: u32) {
    bitangents := NewArray(vertices.count, Vector3);
    defer array_free(bitangents);
    for * vertices it.tangent = .{};
    i := 0;
    while i + 2 < indices.count {
        i0 := indices[i] - base; i1 := indices[i + 1] - base; i2 := indices[i + 2] - base;
        i += 3;
        v0 := *vertices[i0]; v1 := *vertices[i1]; v2 := *vertices[i2];
        e1 := v1.position - v0.position;
        e2 := v2.position - v0.position;
        d1 := v1.uv - v0.uv;
        d2 := v2.uv - v0.uv;
        det := d1.x * d2.y - d2.x * d1.y;
        if abs(det) < 0.000000001 continue;
        r := 1.0 / det;
        t := (e1 * d2.y - e2 * d1.y) * r;
        b := (e2 * d1.x - e1 * d2.x) * r;
        for idx: u32.[i0, i1, i2] {
            vertices[idx].tangent.xyz += t;
            bitangents[idx] += b;
        }
    }
    for * v, index: vertices {
        n := v.normal;
        t := v.tangent.xyz - n * dot(n, v.tangent.xyz);
        if dot(t, t) < 0.000001 {
            // 退化：随便挑一个与法线垂直的方向。
            helper := ifx abs(n.x) < 0.9 then Vector3.{1, 0, 0} else Vector3.{0, 1, 0};
            t = cross(helper, n);
        }
        t = unit_vector(t);
        w := ifx dot(cross(n, t), bitangents[index]) < 0 then -1.0 else 1.0;
        v.tangent = .{t.x, t.y, t.z, w};
    }
}

load_nodes :: (ctx: *Loader) {
    model := ctx.model;
    nodes := json_get(ctx.root, "nodes");
    count := json_count(nodes);
    for i: 0..count - 1 {
        entry := json_at(nodes, i);
        node: Gltf_Node;
        node.name = own_string(ctx, json_string(json_get(entry, "name")));
        node.mesh = cast(s32) json_int(entry, "mesh");
        matrix := json_get(entry, "matrix");
        if matrix != null && json_count(matrix) == 16 {
            // glTF 矩阵按列主序存储；Jai 的 Matrix4 按行存放，所以逐个转置填入。
            for c: 0..3 for r: 0..3 node.local.coef[r][c] = cast(float) json_number(json_at(matrix, c * 4 + r));
        } else {
            t := read_vector(entry, "translation", .{0, 0, 0, 0}).xyz;
            r := read_vector(entry, "rotation", .{0, 0, 0, 1});
            s := read_vector(entry, "scale", .{1, 1, 1, 0}).xyz;
            q := Quaternion.{r.x, r.y, r.z, r.w};
            node.local = make_translation_matrix4(t) * rotation_matrix(Matrix4, q) * make_scale_matrix4(s);
        }
        array_add(*model.nodes, node);
    }
    // 第二遍：记录 parent。
    for i: 0..count - 1 {
        children := json_get(json_at(nodes, i), "children");
        for c: 0..json_count(children) - 1 {
            child_index := cast(s64) json_number(json_at(children, c), -1);
            if child_index >= 0 && child_index < count then model.nodes[child_index].parent = cast(s32) i;
        }
    }
    // 世界矩阵：按拓扑顺序（父先于子）。glTF 不保证顺序，所以递归求。
    resolved := NewArray(count, bool);
    defer array_free(resolved);
    for i: 0..count - 1 resolve_world(model, i, resolved);
}

resolve_world :: (model: *Gltf_Model, index: s64, resolved: [] bool) {
    if resolved[index] return;
    resolved[index] = true;   // 先标记，防止损坏文件的循环引用
    node := *model.nodes[index];
    if node.parent >= 0 {
        resolve_world(model, node.parent, resolved);
        node.world = model.nodes[node.parent].world * node.local;
    } else {
        node.world = node.local;
    }
}

compute_bounds :: (model: *Gltf_Model) {
    model.bounds_min = .{ FLOAT32_MAX,  FLOAT32_MAX,  FLOAT32_MAX};
    model.bounds_max = .{-FLOAT32_MAX, -FLOAT32_MAX, -FLOAT32_MAX};
    any := false;
    for node: model.nodes {
        if node.mesh < 0 || node.mesh >= model.meshes.count continue;
        for prim: model.meshes[node.mesh].primitives {
            // 变换局部 AABB 的 8 个角点。
            for corner: 0..7 {
                local := Vector3.{
                    ifx corner & 1 then prim.bounds_max.x else prim.bounds_min.x,
                    ifx corner & 2 then prim.bounds_max.y else prim.bounds_min.y,
                    ifx corner & 4 then prim.bounds_max.z else prim.bounds_min.z,
                };
                world := transform_point(node.world, local);
                model.bounds_min = component_min(model.bounds_min, world);
                model.bounds_max = component_max(model.bounds_max, world);
                any = true;
            }
        }
    }
    if !any { model.bounds_min = .{}; model.bounds_max = .{}; }
}

#import "Basic";
#import "File";
#import "Math";
#import "String";
#import "stb_image";
#load "json.jai";
