// ----------------------------------------------------------------------------: Camera in metres, Y up

Camera_Input :: struct {
    move: Vector3; // Right, world up, forward.
    look: Vector2; // Raw mouse delta, with no smoothing or frame-time multiplier.
    fast: bool;
}

Camera_Projection :: enum { PERSPECTIVE; ORTHOGRAPHIC; }

Camera :: struct {
    position := Vector3.{5, 5, 7};
    yaw: float;
    pitch: float;
    projection: Camera_Projection;
    fov: float = 55 * PI / 180;
    orthographic_height: float = 14; // Vertical span in world metres.
    move_speed: float = 4;
    sensitivity: float = 0.002;
    near_plane: float = 0.05;
    far_plane: float = 100;
}

camera_forward :: (camera: *Camera) -> Vector3 {
    return .{sin(camera.yaw) * cos(camera.pitch), sin(camera.pitch), -cos(camera.yaw) * cos(camera.pitch)};
}

camera_right :: (camera: *Camera) -> Vector3 {
    // The yaw basis stays defined when looking straight down or up.
    return .{cos(camera.yaw), 0, sin(camera.yaw)};
}

camera_look_at :: (camera: *Camera, position: Vector3, target: Vector3) {
    camera.position = position;
    offset := target - position;
    if dot(offset, offset) < 0.000001 then return;
    direction := unit_vector(offset);
    if abs(direction.x) + abs(direction.z) > 0.000001 then camera.yaw = atan2(direction.x, -direction.z);
    camera.pitch = asin(clamp(direction.y, -1.0, 1.0));
}

camera_update :: (camera: *Camera, input: Camera_Input, real_dt: float) {
    camera.yaw += input.look.x * camera.sensitivity;
    camera.pitch = clamp(camera.pitch - input.look.y * camera.sensitivity, -PI * 0.5, PI * 0.5);
    forward := camera_forward(camera);
    right := camera_right(camera);
    move := right * input.move.x + Vector3.{0, 1, 0} * input.move.y + forward * input.move.z;
    speed := camera.move_speed * (ifx input.fast then 4.0 else 1.0);
    if dot(move, move) > 0.000001 then camera.position += unit_vector(move) * speed * real_dt;
}

camera_view_projection :: (camera: *Camera, aspect: float) -> Matrix4 {
    forward := camera_forward(camera);
    right := camera_right(camera);
    up := cross(right, forward);
    view := Matrix4_Identity;
    view._11 = right.x;    view._12 = right.y;    view._13 = right.z;
    view._21 = up.x;       view._22 = up.y;       view._23 = up.z;
    view._31 = -forward.x; view._32 = -forward.y; view._33 = -forward.z;
    view._14 = -dot(right, camera.position);
    view._24 = -dot(up, camera.position);
    view._34 = dot(forward, camera.position);
    // Vulkan depth is [0, 1]. Slang handles Vulkan's Y inversion at compilation.
    projection: Matrix4;
    if camera.projection == .ORTHOGRAPHIC {
        projection._22 = 2 / max(camera.orthographic_height, 0.01);
        projection._11 = projection._22 / max(aspect, 0.01);
        projection._33 = 1 / (camera.near_plane - camera.far_plane);
        projection._34 = camera.near_plane * projection._33;
        projection._44 = 1;
    } else {
        f := 1 / tan(camera.fov * 0.5);
        projection._11 = f / max(aspect, 0.01);
        projection._22 = f;
        projection._33 = camera.far_plane / (camera.near_plane - camera.far_plane);
        projection._34 = camera.near_plane * projection._33;
        projection._43 = -1;
    }
    return projection * view;
}

#scope_file
#import "Math";
