//  使用右手系，Y 朝上，单位是米
Camera :: struct {
    position := Vector3.{0, 0, 3};
    yaw:   float;                  // 左右转头
    pitch: float;                  // 上下抬头

    fov:   float = 60 * PI / 180;  // Vertical field of view, radians.

    near_plane: float = 0.05;
    far_plane:  float = 200;

    move_speed: float = 2;         // Metres per second.
    fast_multiplier: float = 4;    // Applied while Shift is held.

    sensitivity: float = 0.0025;   // Radians per mouse count.
}

camera: Camera;

Camera_Input :: struct {
    move: Vector3;  // x: right, y: world up, z: forward. Each in [-1, 1], not normalized.
    look: Vector2;  // Raw mouse delta in counts (x: right, y: down).
    fast: bool;
}

camera_forward :: () -> Vector3 {
    cos_pitch := cos(camera.pitch);
    return .{
        sin(camera.yaw) * cos_pitch,
        sin(camera.pitch),
        -cos(camera.yaw) * cos_pitch
    };
}

camera_right :: () -> Vector3 {
    // Depends on yaw only, so it stays well defined when looking straight up or down.
    // cross(forward, world_up) would degenerate to zero there.
    return .{cos(camera.yaw), 0, sin(camera.yaw)};
}

camera_up :: () -> Vector3 {
    return cross(camera_right(), camera_forward());
}

handle_camera_input :: (input: Camera_Input, dt: float) {
    // Look. Screen Y grows downwards, so moving the mouse down should pitch down.
    camera.yaw   += input.look.x * camera.sensitivity;
    camera.pitch -= input.look.y * camera.sensitivity;
    PITCH_LIMIT :: PI * 0.5 - 0.001;
    camera.pitch = clamp(camera.pitch, -PITCH_LIMIT, PITCH_LIMIT);
    if camera.yaw >  PI then camera.yaw -= 2 * PI;
    if camera.yaw < -PI then camera.yaw += 2 * PI;

    // Move. Combine the axes first, then normalize, so diagonal movement is not faster.
    forward := camera_forward();
    right   := camera_right();
    move := right * input.move.x + Vector3.{0, 1, 0} * input.move.y + forward * input.move.z;
    if dot(move, move) > 0.000001 {
        speed := camera.move_speed * (ifx input.fast then camera.fast_multiplier else 1.0);
        camera.position += unit_vector(move) * (speed * dt);
    }
}

// Aims the camera at target from position.
camera_look_at :: (position: Vector3, target: Vector3) {
    camera.position = position;
    direction := target - position;
    if dot(direction, direction) < 0.000001 return;
    direction = unit_vector(direction);
    camera.yaw = atan2(direction.x, -direction.z);
    camera.pitch = asin(clamp(direction.y, -1.0, 1.0));
}

// World -> view. The camera's own transform is "rotate by R, then translate by p".
// Its inverse is "translate by -p, then rotate by R^T". A rotation's inverse is its
// transpose, so the rows of the view matrix are simply the camera's basis vectors.
// View space looks down -Z, which is why the third row is -forward.
view_matrix :: () -> Matrix4 {
    forward := camera_forward();
    right   := camera_right();
    up      := cross(right, forward);
    using view := Matrix4_Identity;
    _11 =  right.x;   _12 =  right.y;   _13 =  right.z;   _14 = -dot(right, camera.position);
    _21 =  up.x;      _22 =  up.y;      _23 =  up.z;      _24 = -dot(up, camera.position);
    _31 = -forward.x; _32 = -forward.y; _33 = -forward.z; _34 =  dot(forward, camera.position);
    return view;
}

// 
projection_matrix :: (aspect: float) -> Matrix4 {
    f := 1 / tan(camera.fov * 0.5);
    n := camera.near_plane;
    r := camera.far_plane;
    using projection: Matrix4;
    _11 = f / max(aspect, 0.01);
    _22 = f;
    _33 = r / (n - r);
    _34 = n * r / (n - r);
    _43 = -1;  // clip w = -view z, so points in front of the camera get positive w.
    return projection;
}

view_projection :: (aspect: float) -> Matrix4 {
    return projection_matrix(aspect) * view_matrix();
}
