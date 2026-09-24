// ----------------------------------------------------------------------------: Wavefront OBJ loader
//
// 用法：
//     #import "obj";
//     mesh, ok := obj_load("model.obj");
//     defer mesh_data_free(*mesh);
//
// OBJ is a line-based text format. We only care about four kinds of line:
//   v  x y z        position
//   vt u v          texture coordinate (origin bottom-left)
//   vn x y z        normal
//   f  a/b/c ...    face: each corner is position/uv/normal indices, 1-based,
//                   negative means "count back from the end", uv and normal are optional.
//
// The catch: OBJ indexes positions, uvs and normals independently, but the GPU
// wants ONE index per vertex. So every distinct (position, uv, normal) triple
// becomes its own GPU vertex, deduplicated through a hash table.

Mesh_Vertex :: struct {
    position: Vector3;
    normal:   Vector3;
    uv:       Vector2;
}

Mesh_Data :: struct {
    vertices: [..] Mesh_Vertex;
    indices:  [..] u32;
    bounds_min: Vector3;
    bounds_max: Vector3;
}

mesh_data_free :: (mesh: *Mesh_Data) {
    array_free(mesh.vertices);
    array_free(mesh.indices);
}

load_obj :: (path: string) -> Mesh_Data, bool {
    mesh: Mesh_Data;
    text, ok := read_entire_file(path);
    if !ok {
        log_error("Could not read OBJ file '%'.", path);
        return mesh, false;
    }
    defer free(text);

    positions: [..] Vector3;  defer array_free(positions);
    uvs:       [..] Vector2;  defer array_free(uvs);
    normals:   [..] Vector3;  defer array_free(normals);
    corners:   [..] u32;      defer array_free(corners);  // GPU vertex index per corner of the current face.

    // Key packs the three OBJ indices of a corner; value is the GPU vertex index.
    lookup: Table(u64, u32);
    defer deinit(*lookup);

    mesh.bounds_min = .{ FLOAT32_MAX,  FLOAT32_MAX,  FLOAT32_MAX};
    mesh.bounds_max = .{-FLOAT32_MAX, -FLOAT32_MAX, -FLOAT32_MAX};

    remaining := text;
    line_number := 0;
    while remaining.count {
        line_number += 1;
        line := obj_next_line(*remaining);
        keyword := obj_next_token(*line);

        if keyword == "v" {
            p := obj_parse_vector3(*line);
            array_add(*positions, p);
            mesh.bounds_min = .{min(mesh.bounds_min.x, p.x), min(mesh.bounds_min.y, p.y), min(mesh.bounds_min.z, p.z)};
            mesh.bounds_max = .{max(mesh.bounds_max.x, p.x), max(mesh.bounds_max.y, p.y), max(mesh.bounds_max.z, p.z)};
        } else if keyword == "vt" {
            array_add(*uvs, obj_parse_vector2(*line));
        } else if keyword == "vn" {
            array_add(*normals, obj_parse_vector3(*line));
        } else if keyword == "f" {
            array_reset(*corners);
            while true {
                token := obj_next_token(*line);
                if !token.count break;
                p, t, n := obj_parse_corner(token, positions.count, uvs.count, normals.count);
                if p < 0 {
                    log_error("%:%: bad face corner '%'.", path, line_number, token);
                    return mesh, false;
                }
                array_add(*corners, obj_vertex_index(*mesh, *lookup, positions, uvs, normals, p, t, n));
            }
            // Fan triangulation: a polygon with k corners becomes k-2 triangles sharing corner 0.
            // Correct for convex polygons, which is what OBJ exporters produce in practice.
            for i: 1..corners.count - 2 {
                array_add(*mesh.indices, corners[0]);
                array_add(*mesh.indices, corners[i]);
                array_add(*mesh.indices, corners[i + 1]);
            }
        }
        // Everything else (comments, groups, materials, smoothing) is ignored for now.
    }

    if normals.count == 0 then obj_compute_normals(*mesh);

    log("Loaded '%': % vertices, % triangles, bounds % .. %.",
        path, mesh.vertices.count, mesh.indices.count / 3, mesh.bounds_min, mesh.bounds_max);
    return mesh, true;
}

#scope_file

obj_next_line :: (s: *string) -> string {
    line := s.*;
    end := find_index_from_left(s.*, #char "\n");
    if end < 0 {
        s.count = 0;
    } else {
        line.count = end;
        advance(s, end + 1);
    }
    if line.count && line[line.count - 1] == #char "\r" then line.count -= 1;
    return line;
}

obj_is_space :: (c: u8) -> bool { return c == #char " " || c == #char "\t"; }

obj_next_token :: (s: *string) -> string {
    while s.count && obj_is_space(s.data[0]) advance(s, 1);
    token := s.*;
    token.count = 0;
    while s.count && !obj_is_space(s.data[0]) {
        advance(s, 1);
        token.count += 1;
    }
    return token;
}

obj_parse_float :: (s: *string) -> float {
    value, ok := string_to_float(obj_next_token(s));
    return ifx ok then value else 0.0;
}

obj_parse_vector3 :: (s: *string) -> Vector3 {
    x := obj_parse_float(s);
    y := obj_parse_float(s);
    z := obj_parse_float(s);
    return .{x, y, z};
}

obj_parse_vector2 :: (s: *string) -> Vector2 {
    x := obj_parse_float(s);
    y := obj_parse_float(s);
    return .{x, y};
}

// "7/3/5" -> (6, 2, 4). "7//5" -> (6, -1, 4). "7" -> (6, -1, -1). Returns p = -1 on error.
obj_parse_corner :: (token: string, position_count: s64, uv_count: s64, normal_count: s64) -> s64, s64, s64 {
    counts := s64.[position_count, uv_count, normal_count];
    result := s64.[-1, -1, -1];
    rest := token;
    for slot: 0..2 {
        if !rest.count break;
        part := rest;
        slash := find_index_from_left(rest, #char "/");
        if slash >= 0 {
            part.count = slash;
            advance(*rest, slash + 1);
        } else {
            rest.count = 0;
        }
        if !part.count continue;  // "7//5": the empty middle part means "no uv".
        value, ok := string_to_int(part);
        if !ok return -1, -1, -1;
        index := ifx value < 0 then counts[slot] + value else value - 1;
        if index < 0 || index >= counts[slot] return -1, -1, -1;
        result[slot] = index;
    }
    return result[0], result[1], result[2];
}

// Returns the GPU vertex for this (p, t, n) triple, creating it on first sight.
obj_vertex_index :: (mesh: *Mesh_Data, lookup: *Table(u64, u32),
                     positions: [] Vector3, uvs: [] Vector2, normals: [] Vector3,
                     p: s64, t: s64, n: s64) -> u32 {
    // Each index fits in 21 bits (2 million); +1 so that "absent" (-1) packs as 0.
    assert(p < (1 << 21) && t + 1 < (1 << 21) && n + 1 < (1 << 21));
    key := (cast(u64) p) | ((cast(u64) (t + 1)) << 21) | ((cast(u64) (n + 1)) << 42);
    found, existing := table_find(lookup, key);
    if found return existing;

    vertex: Mesh_Vertex;
    vertex.position = positions[p];
    if t >= 0 then vertex.uv = uvs[t];
    if n >= 0 then vertex.normal = normals[n];
    index := cast(u32) mesh.vertices.count;
    array_add(*mesh.vertices, vertex);
    table_add(lookup, key, index);
    return index;
}

// Fallback for files without "vn": average the face normals around each vertex.
// Larger triangles contribute more because the cross product is not normalized.
obj_compute_normals :: (mesh: *Mesh_Data) {
    for *mesh.vertices it.normal = .{};
    i := 0;
    while i + 2 < mesh.indices.count {
        a := *mesh.vertices[mesh.indices[i]];
        b := *mesh.vertices[mesh.indices[i + 1]];
        c := *mesh.vertices[mesh.indices[i + 2]];
        face_normal := cross(b.position - a.position, c.position - a.position);
        a.normal += face_normal;
        b.normal += face_normal;
        c.normal += face_normal;
        i += 3;
    }
    for *mesh.vertices {
        if dot(it.normal, it.normal) > 0.000001 then it.normal = unit_vector(it.normal);
    }
}

#import "Math";
#import "File";
#import "Basic";
#import "String";
#import "Hash_Table";
