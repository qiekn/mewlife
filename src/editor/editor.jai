// ----------------------------------------------------------------------------: Editor state and inspector

DEFAULT_BACKGROUND :: #run color_rgb(0x062626);
Preview_Pose :: enum { BIND; GAMEPLAY; IDLE; WALK; RUN; PUSH; BLOCKED; }
Editor :: struct {
    camera: Camera; // Free camera / model viewer.
    gameplay_camera: Camera;
    free_camera: bool = true;
    visible: bool = true;
    show_ground: bool = true;
    character_outline: bool = true;
    outline_width: float = 1.2; // Logical pixels; the renderer applies display DPI.
    show_demo: bool;
    paused: bool;
    pose: Preview_Pose = .BIND;
    playback_rate: float = 1;
    background: Vector4 = DEFAULT_BACKGROUND;
    sfx_volume: float = 0.7;
}

editor_reset_camera :: (editor: *Editor, in_game: bool) {
    if in_game then editor.camera = editor.gameplay_camera;
    else camera_look_at(*editor.camera, .{2.3, 1.8, 3.7}, .{0, 0.65, 0});
    editor.camera.projection = .PERSPECTIVE;
}

editor_reset_gameplay_camera :: (editor: *Editor) {
    editor.gameplay_camera = .{position = .{0, 12, 12}, pitch = -PI * 0.25,
                              projection = .PERSPECTIVE, fov = PI * 0.25, orthographic_height = 14};
}

editor_active_camera :: (editor: *Editor, in_game: bool) -> *Camera {
    if in_game && !editor.free_camera then return *editor.gameplay_camera;
    return *editor.camera;
}

editor_set_free_camera :: (editor: *Editor, enabled: bool, in_game: bool) {
    if enabled && !editor.free_camera && in_game {
        speed := editor.camera.move_speed;
        sensitivity := editor.camera.sensitivity;
        editor.camera = editor.gameplay_camera;
        editor.camera.projection = .PERSPECTIVE;
        editor.camera.move_speed = speed;
        editor.camera.sensitivity = sensitivity;
    }
    editor.free_camera = enabled;
}

editor_use_free_camera :: (editor: *Editor) {
    editor.gameplay_camera.position = editor.camera.position;
    editor.gameplay_camera.yaw = editor.camera.yaw;
    editor.gameplay_camera.pitch = editor.camera.pitch;
    editor.gameplay_camera.fov = editor.camera.fov;
    editor.gameplay_camera.projection = editor.camera.projection;
    editor.gameplay_camera.orthographic_height = editor.camera.orthographic_height;
    editor.free_camera = false;
}

editor_draw :: (editor: *Editor, in_game: bool, draw_count: u32, triangles: u32, joints: s64,
                world_scale: float, move_count: u32) {
    if editor.visible {
        ImGui.SetNextWindowPos(.{24, 24}, .FirstUseEver);
        ImGui.SetNextWindowSize(.{370, 0}, .FirstUseEver);
        viewport := ImGui.GetIO().DisplaySize;
        ImGui.SetNextWindowSizeConstraints(.{320, 160}, .{max(320.0, viewport.x - 48), max(160.0, viewport.y - 96)});
        if ImGui.Begin("Scene Inspector", *editor.visible, .AlwaysAutoResize | .NoFocusOnAppearing) {
            ImGui.Text("Priestess  |  % joints", joints);
            ImGui.Text("% FPS  |  % draws  |  % triangles", cast(s32) ImGui.GetIO().Framerate, draw_count, triangles);
            ImGui.Separator();
            free_camera := editor.free_camera;
            if ImGui.Checkbox("Free Camera (F2)", *free_camera) then editor_set_free_camera(editor, free_camera, in_game);
            ImGui.SameLine();
            if ImGui.Button("Reset View") {
                if in_game && !editor.free_camera then editor_reset_gameplay_camera(editor);
                else editor_reset_camera(editor, in_game);
            }
            if in_game && ui_collapsing_header("Gameplay Camera", .DefaultOpen) {
                camera := *editor.gameplay_camera;
                ImGui.SetNextItemWidth(210);
                ImGui.DragFloat3("Position", *camera.position.component, 0.05, format = "%.2f");
                ImGui.SetNextItemWidth(210);
                ImGui.SliderAngle("Yaw", *camera.yaw, -180, 180);
                ImGui.SetNextItemWidth(210);
                ImGui.SliderAngle("Pitch", *camera.pitch, -90, 90);
                orthographic := camera.projection == .ORTHOGRAPHIC;
                if ImGui.Checkbox("Orthographic", *orthographic) {
                    camera.projection = ifx orthographic then .ORTHOGRAPHIC else .PERSPECTIVE;
                }
                ImGui.SetNextItemWidth(210);
                if orthographic then ImGui.SliderFloat("View Height", *camera.orthographic_height, 6, 60, "%.1f m");
                else ImGui.SliderAngle("Game FOV", *camera.fov, 20, 100);
                if ImGui.Button("Look at Board") then camera_look_at(camera, camera.position, .{0, 0, 0});
                ImGui.SameLine();
                if ImGui.Button("Reset Game View") then editor_reset_gameplay_camera(editor);
                if editor.free_camera && ImGui.Button("Use Free Camera for Gameplay") then editor_use_free_camera(editor);
            }
            if editor.free_camera {
                ImGui.SetNextItemWidth(170);
                ImGui.SliderFloat("Move Speed", *editor.camera.move_speed, 0.5, 16, "%.1f m/s");
                ImGui.SetNextItemWidth(170);
                ImGui.SliderAngle("Free FOV", *editor.camera.fov, 20, 100);
                ImGui.TextUnformatted("RMB: look   WASD: fly   Q/E: down/up");
                ImGui.TextUnformatted("Shift: faster camera   F1: inspector");
            }
            ImGui.Separator();
            names := string.["Bind pose (T pose)", "Gameplay", "Idle", "Walk", "Run (faster walk)", "Push", "Blocked push"];
            ImGui.SetNextItemWidth(205);
            if ui_begin_combo("Pose", names[editor.pose]) {
                for name: names {
                    selected := editor.pose.(s32) == it_index;
                    if ImGui.Selectable(temp_c_string(name), selected) then editor.pose = cast(Preview_Pose) it_index;
                    if selected then ImGui.SetItemDefaultFocus();
                }
                ImGui.EndCombo();
            }
            ImGui.Checkbox(temp_c_string(ifx in_game then "Pause World" else "Pause Animation"), *editor.paused);
            ImGui.BeginDisabled(in_game && editor.pose == .GAMEPLAY);
            ImGui.SetNextItemWidth(170);
            ImGui.SliderFloat("Playback Rate", *editor.playback_rate, 0.1, 2, "%.2fx");
            ImGui.EndDisabled();
            ImGui.Text("World Time: %x", world_scale);
            if in_game then ImGui.Text("Moves: %", move_count);
            ImGui.Separator();
            ImGui.Checkbox("Cubic Checkerboard", *editor.show_ground);
            ImGui.Checkbox("Character Outline", *editor.character_outline);
            if editor.character_outline {
                ImGui.SetNextItemWidth(170);
                ImGui.SliderFloat("Outline Width", *editor.outline_width, 0.5, 6, "%.1f px");
            }
            ImGui.SetNextItemWidth(210);
            ImGui.ColorEdit3("Background", *editor.background.xyz.component, .Float);
            if ImGui.Button("Reset Background") then editor.background = DEFAULT_BACKGROUND;
            ImGui.Checkbox("ImGui Demo", *editor.show_demo);
        }
        ImGui.End();
    }
    if editor.show_demo then ImGui.ShowDemoWindow(*editor.show_demo);
}

#scope_file
#import "Basic";
#import "Math";
#import "String";
