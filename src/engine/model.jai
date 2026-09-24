// ----------------------------------------------------------------------------: 蒙皮模型资源（.meshbin / .animbin）
//
// 这是 .refs/codex_src 用 Python 从游戏数据导出的自有二进制格式，格式说明见
// assets/models/priestess/README.md。加载后顶点转换成渲染器的 Vertex（补上切线）。

MAX_MODEL_JOINTS :: 512;

// 文件里的顶点布局，64 字节。
Model_File_Vertex :: struct {
    position: Vector3;
    normal: Vector3;
    uv: Vector2;
    weights: Vector4;
    joints: [4] u32;
}
#assert(size_of(Model_File_Vertex) == 64);

Model_Joint :: struct {
    name: string;
    parent: s32;
    local_bind: Matrix4;
    inverse_bind: Matrix4;
}

Model_Part :: struct {
    name: string;
    texture_path: string;
    first_index: u32;
    index_count: u32;
    optional: bool;
    color: Vector4;
}

Model_Asset :: struct {
    vertices: [] Vertex;
    indices: [] u32;
    joints: [] Model_Joint;
    parts: [] Model_Part;
    bounds_min, bounds_max: Vector3;
    source_data: string;   // 拥有 joints/parts 引用的字符串
}

model_load :: (model: *Model_Asset, path: string) -> bool {
    assert(model.source_data.data == null);
    raw, ok := read_entire_file(path);
    if !ok { log_error("Could not read model '%'.", path); return false; }
    model.source_data = raw;
    success := false;
    defer if !success then model_free(model);

    reader := Asset_Reader.{bytes = raw};
    if asset_bytes(*reader, 4) != "MWMS" || asset_value(*reader, u32) != 1 return false;
    vertex_count := asset_value(*reader, u32);
    index_count := asset_value(*reader, u32);
    joint_count := asset_value(*reader, u32);
    part_count := asset_value(*reader, u32);
    if vertex_count == 0 || vertex_count > 1000000 || index_count == 0 || index_count > 6000000
        || index_count % 3 != 0 || joint_count > MAX_MODEL_JOINTS || part_count == 0 || part_count > 1024 return false;

    model.bounds_min = asset_value(*reader, Vector3);
    model.bounds_max = asset_value(*reader, Vector3);
    model.joints = NewArray(joint_count, Model_Joint);
    model.parts = NewArray(part_count, Model_Part);

    // 关节按父先子后排列。全局绑定矩阵 = 父全局 * 本地；逆绑定矩阵把绑定姿态的顶点拉回关节空间。
    globals := NewArray(joint_count, Matrix4);
    defer array_free(globals);
    for * joint, index: model.joints {
        joint.name = asset_string(*reader);
        joint.parent = asset_value(*reader, s32);
        joint.local_bind = asset_value(*reader, Matrix4);
        if reader.failed || !joint.name || joint.parent < -1 || joint.parent >= index return false;
        globals[index] = joint.local_bind;
        if joint.parent >= 0 then globals[index] = globals[joint.parent] * joint.local_bind;
        ok, joint.inverse_bind = inverse(globals[index]);
        if !ok return false;
    }
    for * part: model.parts {
        part.name = asset_string(*reader);
        part.texture_path = asset_string(*reader);
        part.first_index = asset_value(*reader, u32);
        part.index_count = asset_value(*reader, u32);
        optional := asset_value(*reader, u32);
        asset_value(*reader, u32);   // repeat_texture，未用
        asset_value(*reader, u32);   // 源材质掩码，未用
        part.color = asset_value(*reader, Vector4);
        if reader.failed || optional > 1 || part.first_index >= index_count
            || part.index_count == 0 || part.index_count > index_count - part.first_index return false;
        part.optional = optional != 0;
    }

    vertex_bytes := asset_bytes(*reader, vertex_count.(s64) * size_of(Model_File_Vertex));
    index_bytes := asset_bytes(*reader, index_count.(s64) * size_of(u32));
    if reader.failed || reader.offset != raw.count return false;

    file_vertices: [] Model_File_Vertex = .{vertex_count, cast(*Model_File_Vertex) vertex_bytes.data};
    model.vertices = NewArray(vertex_count, Vertex);
    for file_vertex, index: file_vertices {
        v := *model.vertices[index];
        v.position = file_vertex.position;
        v.normal = file_vertex.normal;
        // 源 uv 的 v 朝上，PNG 行朝下；这里翻转一次，着色器就不用特殊处理。
        v.uv = .{file_vertex.uv.x, 1 - file_vertex.uv.y};
        v.weights = file_vertex.weights;
        v.joints = file_vertex.joints;
        for file_vertex.joints if it != 0xffffffff && it >= joint_count return false;
    }
    model.indices = NewArray(index_count, u32);
    memcpy(model.indices.data, index_bytes.data, index_bytes.count);
    for model.indices if it >= vertex_count return false;

    compute_mesh_tangents(model.vertices, model.indices);
    success = true;
    return true;
}

model_free :: (model: *Model_Asset) {
    array_free(model.vertices);
    array_free(model.indices);
    array_free(model.joints);
    array_free(model.parts);
    free(model.source_data);
    model.* = .{};
}

// 每个三角形由位置差与 uv 差解出切线，累加后对法线正交化。与 gltf 模块里的算法相同。
compute_mesh_tangents :: (vertices: [] Vertex, indices: [] u32) {
    bitangents := NewArray(vertices.count, Vector3);
    defer array_free(bitangents);
    for * vertices it.tangent = .{};
    i := 0;
    while i + 2 < indices.count {
        i0 := indices[i]; i1 := indices[i + 1]; i2 := indices[i + 2];
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
            helper := ifx abs(n.x) < 0.9 then Vector3.{1, 0, 0} else Vector3.{0, 1, 0};
            t = cross(helper, n);
        }
        t = unit_vector(t);
        w := ifx dot(cross(n, t), bitangents[index]) < 0 then -1.0 else 1.0;
        v.tangent = .{t.x, t.y, t.z, w};
    }
}

// ----------------------------------------------------------------------------: 带边界检查的字节读取器

Asset_Reader :: struct {
    bytes: string;
    offset: s64;
    failed: bool;
}

asset_bytes :: (reader: *Asset_Reader, count: s64) -> string {
    if reader.failed || count < 0 || reader.offset < 0 || count > reader.bytes.count - reader.offset {
        reader.failed = true;
        return "";
    }
    result := string.{count, reader.bytes.data + reader.offset};
    reader.offset += count;
    return result;
}

asset_value :: (reader: *Asset_Reader, $T: Type) -> T {
    value: T;
    bytes := asset_bytes(reader, size_of(T));
    if !reader.failed then memcpy(*value, bytes.data, bytes.count);
    return value;
}

asset_string :: (reader: *Asset_Reader) -> string {
    count := asset_value(reader, u32);
    if count > 4096 { reader.failed = true; return ""; }
    return asset_bytes(reader, count);
}
