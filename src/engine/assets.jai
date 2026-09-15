// ----------------------------------------------------------------------------: CPU model assets

MAX_MODEL_JOINTS :: 512;

Model_Vertex :: struct {
    position: Vector3;
    normal: Vector3;
    uv: Vector2;
    weights: Vector4;
    joints: [4] u32;
}

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
    repeat_texture: bool;
    color: Vector4;
}

Model_Asset :: struct {
    vertices: [] Model_Vertex;
    indices: [] u32;
    joints: [] Model_Joint;
    parts: [] Model_Part;
    bounds_min, bounds_max: Vector3;
    source_data: string; // Owns the strings referenced by joints and parts.
}

#assert(size_of(Model_Vertex) == 64);

model_load :: (model: *Model_Asset, path: string) -> bool {
    assert(model.source_data.data == null);
    raw, ok := read_entire_file(path);
    if !ok then return false;
    model.source_data = raw;
    success := false;
    defer if !success then model_free(model);
    reader := Asset_Reader.{bytes = raw};
    if asset_bytes(*reader, 4) != "MWMS" || asset_value(*reader, u32) != 1 then return false;
    vertex_count := asset_value(*reader, u32);
    index_count := asset_value(*reader, u32);
    joint_count := asset_value(*reader, u32);
    part_count := asset_value(*reader, u32);
    if vertex_count == 0 || vertex_count > 1000000 || index_count == 0 || index_count > 6000000
        || index_count % 3 != 0 || joint_count > MAX_MODEL_JOINTS
        || part_count == 0 || part_count > 1024 then return false;
    model.bounds_min = asset_value(*reader, Vector3);
    model.bounds_max = asset_value(*reader, Vector3);
    model.joints = NewArray(joint_count, Model_Joint);
    model.parts = NewArray(part_count, Model_Part);
    globals := NewArray(joint_count, Matrix4);
    defer free(globals.data);
    for *joint: model.joints {
        joint.name = asset_string(*reader);
        joint.parent = asset_value(*reader, s32);
        joint.local_bind = asset_value(*reader, Matrix4);
        if reader.failed || !joint.name || joint.parent < -1 || joint.parent >= it_index then return false;
        globals[it_index] = joint.local_bind;
        if joint.parent >= 0 then globals[it_index] = globals[joint.parent] * joint.local_bind;
        ok, joint.inverse_bind = inverse(globals[it_index]);
        if !ok then return false;
    }
    for *part: model.parts {
        part.name = asset_string(*reader);
        part.texture_path = asset_string(*reader);
        part.first_index = asset_value(*reader, u32);
        part.index_count = asset_value(*reader, u32);
        optional := asset_value(*reader, u32);
        repeat_texture := asset_value(*reader, u32);
        asset_value(*reader, u32); // Source material mask is not an alpha-cutout flag.
        part.color = asset_value(*reader, Vector4);
        if reader.failed || optional > 1 || repeat_texture > 1 || part.first_index >= index_count
            || part.index_count == 0 || part.index_count > index_count - part.first_index then return false;
        part.optional = optional != 0;
        part.repeat_texture = repeat_texture != 0;
    }
    vertex_bytes := asset_bytes(*reader, vertex_count.(s64) * size_of(Model_Vertex));
    index_bytes := asset_bytes(*reader, index_count.(s64) * size_of(u32));
    if reader.failed || reader.offset != raw.count then return false;
    model.vertices = NewArray(vertex_count, Model_Vertex);
    model.indices = NewArray(index_count, u32);
    memcpy(model.vertices.data, vertex_bytes.data, vertex_bytes.count);
    memcpy(model.indices.data, index_bytes.data, index_bytes.count);
    for model.indices if it >= vertex_count then return false;
    for vertex: model.vertices for joint: vertex.joints {
        if joint != 0xffffffff && joint >= joint_count then return false;
    }
    success = true;
    return true;
}

model_free :: (model: *Model_Asset) {
    free(model.vertices.data);
    free(model.indices.data);
    free(model.joints.data);
    free(model.parts.data);
    free(model.source_data);
    model.* = .{};
}

// ----------------------------------------------------------------------------: Checked asset reader

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

#scope_file
#import "Basic";
#import "File";
#import "Math";
