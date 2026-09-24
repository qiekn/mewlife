// ----------------------------------------------------------------------------: 程序生成的图元

// 单位立方体，中心在原点，每个面 4 个顶点（法线不共享）。正面逆时针。
make_cube_mesh :: () -> Mesh {
    vertices: [24] Vertex;
    indices: [36] u32;
    normals  := Vector3.[.{1, 0, 0}, .{-1, 0, 0}, .{0, 1, 0}, .{0, -1, 0}, .{0, 0, 1}, .{0, 0, -1}];
    tangents := Vector3.[.{0, 0, -1}, .{0, 0, 1}, .{1, 0, 0}, .{1, 0, 0}, .{1, 0, 0}, .{-1, 0, 0}];
    corners  := Vector2.[.{-1, -1}, .{1, -1}, .{1, 1}, .{-1, 1}];
    for face: 0..5 {
        normal := normals[face];
        tangent := tangents[face];
        up := cross(normal, tangent);
        for corner: 0..3 {
            v := *vertices[face * 4 + corner];
            v.position = (normal + tangent * corners[corner].x + up * corners[corner].y) * 0.5;
            v.normal = normal;
            v.tangent = .{tangent.x, tangent.y, tangent.z, 1};
            v.uv = .{corners[corner].x * 0.5 + 0.5, 0.5 - corners[corner].y * 0.5};
        }
        for index: u32.[0, 1, 2, 0, 2, 3] indices[face * 6 + it_index] = cast(u32) (face * 4) + index;
    }
    return upload_mesh(vertices, indices);
}
