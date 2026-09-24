// ----------------------------------------------------------------------------: 平移 Gizmo
//
// 选中实体后，在它的位置画三根轴（X 红、Y 绿、Z 蓝）。拖动某根轴时，把鼠标射线
// 与该轴所在的直线求最近点，最近点相对于按下时的偏移就是移动量。画线用 ImGui 的前景
// 绘制列表，省去单独的线段渲染管线。

Gizmo :: struct {
    active_axis: s32 = -1;      // 正在拖动的轴
    hover_axis: s32 = -1;
    drag_start_hit: float;      // 按下时鼠标射线在轴上的参数 t
    drag_start_position: Vector3;
    snap: bool;                 // 拖动时按整数格吸附
    axis_length: float = 1.2;   // 世界单位
}

gizmo: Gizmo;

// 每帧在 ImGui.NewFrame 之后调用。返回 true 表示 gizmo 占用了鼠标（应用不要再做拾取）。
gizmo_update :: (world: *World) -> bool {
    io := ImGui.GetIO();
    entity := world_selected(world);
    if entity == null { gizmo.active_axis = -1; gizmo.hover_axis = -1; return false; }

    viewport := io.DisplaySize;
    mouse := io.MousePos;
    aspect := viewport.x / max(viewport.y, 1);
    vp := view_projection(aspect);

    origin := entity.position;
    // 轴长随距离缩放，让 gizmo 在屏幕上大小大致固定。
    distance := length(origin - camera.position);
    axis_length := gizmo.axis_length * max(distance, 1) * 0.18;

    axes := Vector3.[.{1, 0, 0}, .{0, 1, 0}, .{0, 0, 1}];
    colors := u32.[im_color(235, 64, 52), im_color(96, 200, 64), im_color(64, 128, 235)];
    highlight := im_color(255, 230, 80);

    origin_screen, origin_visible := project(vp, viewport, origin);
    tips: [3] Vector2;
    tip_visible: [3] bool;
    for axis: 0..2 tips[axis], tip_visible[axis] = project(vp, viewport, origin + axes[axis] * axis_length);

    // 悬停检测：鼠标到轴线段的距离。
    if gizmo.active_axis < 0 {
        gizmo.hover_axis = -1;
        if origin_visible && !io.WantCaptureMouse {
            best := 12.0;   // 像素阈值
            for axis: 0..2 {
                if !tip_visible[axis] continue;
                d := point_segment_distance(mouse, origin_screen, tips[axis]);
                if d < best { best = d; gizmo.hover_axis = cast(s32) axis; }
            }
        }
        if gizmo.hover_axis >= 0 && ImGui.IsMouseClicked(.Left) {
            gizmo.active_axis = gizmo.hover_axis;
            gizmo.drag_start_position = origin;
            gizmo.drag_start_hit = closest_axis_parameter(camera_ray(mouse, viewport), origin, axes[gizmo.active_axis]);
        }
    }

    // 拖动。
    if gizmo.active_axis >= 0 {
        if !ImGui.IsMouseDown(.Left) {
            gizmo.active_axis = -1;
        } else {
            axis := axes[gizmo.active_axis];
            t := closest_axis_parameter(camera_ray(mouse, viewport), gizmo.drag_start_position, axis);
            delta := t - gizmo.drag_start_hit;
            if gizmo.snap then delta = floor(delta + 0.5);
            entity.position = gizmo.drag_start_position + axis * delta;
        }
    }

    // 绘制。
    draw := ImGui.GetForegroundDrawList();
    if origin_visible {
        for axis: 0..2 {
            if !tip_visible[axis] continue;
            color := ifx axis == gizmo.active_axis || axis == gizmo.hover_axis then highlight else colors[axis];
            draw.AddLine(draw, origin_screen, tips[axis], color, 3);
            draw.AddCircleFilled(draw, tips[axis], 6, color);
        }
        draw.AddCircleFilled(draw, origin_screen, 4, im_color(255, 255, 255));
    }
    return gizmo.active_axis >= 0 || gizmo.hover_axis >= 0;
}

// 打包成 ImGui 的 ABGR 颜色。
im_color :: (r: u8, g: u8, b: u8, a: u8 = 255) -> u32 {
    return (cast(u32) a << 24) | (cast(u32) b << 16) | (cast(u32) g << 8) | cast(u32) r;
}

#scope_file

// 世界点 -> 屏幕像素。相机后方的点标记为不可见。
project :: (vp: Matrix4, viewport: Vector2, point: Vector3) -> Vector2, bool {
    clip := vp * Vector4.{point.x, point.y, point.z, 1};
    if clip.w <= 0.0001 return .{}, false;
    ndc := clip.xyz / clip.w;
    return .{(ndc.x * 0.5 + 0.5) * viewport.x, (0.5 - ndc.y * 0.5) * viewport.y}, true;
}

point_segment_distance :: (p: Vector2, a: Vector2, b: Vector2) -> float {
    ab := b - a;
    len2 := dot(ab, ab);
    t := ifx len2 > 0.000001 then clamp(dot(p - a, ab) / len2, 0.0, 1.0) else 0.0;
    return length(p - (a + ab * t));
}

// 射线与直线 (origin + axis * t) 的最近点参数 t。两条线的公垂线求解。
closest_axis_parameter :: (ray: Ray, origin: Vector3, axis: Vector3) -> float {
    w := origin - ray.origin;
    a := dot(axis, axis);
    b := dot(axis, ray.direction);
    c := dot(ray.direction, ray.direction);
    d := dot(axis, w);
    e := dot(ray.direction, w);
    denom := a * c - b * b;
    if abs(denom) < 0.000001 return 0;   // 轴与视线平行
    return (b * e - c * d) / denom;
}
