// ----------------------------------------------------------------------------: ImGui 面板

Demo_Scene :: enum s32 { HELMET; SOKOBAN; }
current_scene: Demo_Scene = .HELMET;
show_demo := false;

draw_ui :: (dpi_scale: float) {
    io := ImGui.GetIO();

    ImGui.SetNextWindowPos(.{16 * dpi_scale, 16 * dpi_scale}, .FirstUseEver);
    ImGui.SetNextWindowSize(.{380 * dpi_scale, 0}, .FirstUseEver);
    if ImGui.Begin("mewlife") {
        ImGui.Text("% FPS  |  % draws  |  % triangles", cast(s32) io.Framerate, frame_draw_count, frame_triangle_count);
        scene: s32 = xx current_scene;
        ImGui.RadioButton("PBR Helmet", *scene, xx Demo_Scene.HELMET); ImGui.SameLine();
        ImGui.RadioButton("Sokoban", *scene, xx Demo_Scene.SOKOBAN);
        if scene != xx current_scene then switch_scene(xx scene);
        ImGui.Separator();

        if ImGui.CollapsingHeader("Camera") {
            ImGui.DragFloat3("Position", *camera.position.component, 0.05, format = "%.2f");
            ImGui.SliderAngle("Yaw", *camera.yaw, -180, 180);
            ImGui.SliderAngle("Pitch", *camera.pitch, -89, 89);
            ImGui.SliderAngle("FOV", *camera.fov, 20, 120);
            ImGui.SliderFloat("Speed", *camera.move_speed, 0.25, 20, "%.2f m/s");
            if ImGui.Button("Reset Camera") then camera = home_camera;
            ImGui.TextUnformatted("RMB drag: look   WASD/QE: fly (helmet) or hold RMB (sokoban)");
        }

        if ImGui.CollapsingHeader("Lighting", .DefaultOpen) {
            ImGui.DragFloat3("Sun Direction", *lighting.sun_direction.component, 0.01, -1, 1, "%.2f");
            ImGui.ColorEdit3("Sun Color", *lighting.sun_color.component, .Float);
            ImGui.SliderFloat("Sun Intensity", *lighting.sun_intensity, 0, 10, "%.2f");
            ImGui.ColorEdit3("Ambient Color", *lighting.ambient_color.component, .Float);
            ImGui.SliderFloat("Ambient", *lighting.ambient_intensity, 0, 2, "%.2f");
            ImGui.SliderFloat("Exposure", *lighting.exposure, 0.1, 4, "%.2f");
            ImGui.ColorEdit3("Background", *background.component, .Float);
            tone: s32 = xx lighting.tone_mapping;
            ImGui.TextUnformatted("Tone mapping:"); ImGui.SameLine();
            ImGui.RadioButton("None", *tone, 0); ImGui.SameLine();
            ImGui.RadioButton("Reinhard", *tone, 1); ImGui.SameLine();
            ImGui.RadioButton("ACES", *tone, 2);
            lighting.tone_mapping = xx tone;
            debug_names := string.["Shaded", "Normal", "Base Color", "Metallic", "Roughness", "Occlusion", "Emissive", "UV"];
            if ImGui.BeginCombo("Debug View", temp_c_string(debug_names[lighting.debug_view])) {
                for name, index: debug_names {
                    selected := index == cast(int) lighting.debug_view;
                    if ImGui.Selectable(temp_c_string(name), selected) then lighting.debug_view = xx index;
                    if selected then ImGui.SetItemDefaultFocus();
                }
                ImGui.EndCombo();
            }

            count: s32 = xx lighting.point_light_count;
            ImGui.SliderInt("Point Lights", *count, 0, 4);
            lighting.point_light_count = xx count;
            for i: 0..cast(int) lighting.point_light_count - 1 {
                ImGui.PushID(cast(s32) i);
                light := *lighting.point_lights[i];
                if ImGui.TreeNode("light", "Point Light %", i) {
                    ImGui.DragFloat3("Position", *light.position.component, 0.05, format = "%.2f");
                    ImGui.ColorEdit3("Color", *light.color.component, .Float);
                    ImGui.SliderFloat("Intensity", *light.intensity, 0, 200, "%.1f");
                    ImGui.SliderFloat("Radius", *light.radius, 0.5, 50, "%.1f");
                    ImGui.TreePop();
                }
                ImGui.PopID();
            }
        }

        if current_scene == .HELMET then draw_helmet_ui();
        else draw_sokoban_ui();

        ImGui.Separator();
        if ImGui.CollapsingHeader("Debug") {
            ImGui.Checkbox("Disable Skinning", *debug_disable_skinning);
            ImGui.Checkbox("Disable Instancing", *debug_disable_instancing);
            ImGui.Checkbox("Disable Textures", *debug_disable_textures);
        }
        ImGui.Checkbox("ImGui Demo", *show_demo);
    }
    ImGui.End();
    if show_demo then ImGui.ShowDemoWindow(*show_demo);
}

#scope_file

draw_helmet_ui :: () {
    if !ImGui.CollapsingHeader("Helmet", .DefaultOpen) return;
    if !helmet.loaded { ImGui.TextUnformatted("Model failed to load."); return; }
    ImGui.Checkbox("Turntable", *helmet.turntable);
    ImGui.SameLine();
    if ImGui.Button("Frame Model") then helmet_frame_camera();
    ImGui.SameLine();
    if ImGui.Button("Reset Lights") then helmet_setup_lights();
    ImGui.Text("% entities, % images", helmet.world.entities.count, helmet.model.images.count);
    draw_selection_ui(*helmet.world);
}

draw_sokoban_ui :: () {
    if !ImGui.CollapsingHeader("Sokoban", .DefaultOpen) return;
    s := *sokoban;
    if !s.loaded { ImGui.TextUnformatted("Assets failed to load."); return; }
    if s.solved then ImGui.TextUnformatted("PUZZLE SOLVED!  R: reset");
    else ImGui.Text("Moves: %", s.move_count);
    ImGui.TextUnformatted("WASD / arrows: move   Shift: run   R: reset");
    ImGui.TextUnformatted("LMB: select   drag gizmo: move   Delete: remove");
    if ImGui.Button("Reset Level") then sokoban_reset_level();
    ImGui.Separator();
    ImGui.TextUnformatted("Add next to selection:");
    if ImGui.Button("+ Block") then sokoban_place(.BLOCK); ImGui.SameLine();
    if ImGui.Button("+ Box") then sokoban_place(.BOX); ImGui.SameLine();
    if ImGui.Button("+ Goal") then sokoban_place(.GOAL); ImGui.SameLine();
    if ImGui.Button("Delete") then sokoban_delete_selected();
    ImGui.Checkbox("Snap to Grid", *gizmo.snap);
    ImGui.Text("% entities", s.world.entities.count);
    draw_selection_ui(*s.world);
}

// 选中实体的属性编辑。
draw_selection_ui :: (world: *World) {
    entity := world_selected(world);
    if entity == null { ImGui.TextUnformatted("Nothing selected. Click an object."); return; }
    ImGui.Separator();
    ImGui.Text("Selected: % (%)", entity.name, entity.kind);
    if entity.kind != .MESH then ImGui.Text("Cell: (%, %, %)", entity.cell.x, entity.cell.y, entity.cell.z);
    ImGui.DragFloat3("Position##sel", *entity.position.component, 0.05, format = "%.2f");
    ImGui.SliderAngle("Yaw##sel", *entity.yaw, -180, 180);
    ImGui.DragFloat3("Scale##sel", *entity.scale.component, 0.01, 0.01, 100, "%.2f");
    if ImGui.TreeNode("Material") {
        m := *entity.material;
        ImGui.ColorEdit4("Base Color", *m.base_color.component, .Float);
        ImGui.SliderFloat("Metallic", *m.metallic, 0, 1, "%.2f");
        ImGui.SliderFloat("Roughness", *m.roughness, 0, 1, "%.2f");
        ImGui.ColorEdit3("Emissive", *m.emissive.component, .Float);
        ImGui.SliderFloat("Emissive Strength", *m.emissive_strength, 0, 10, "%.2f");
        ImGui.SliderFloat("Normal Scale", *m.normal_scale, 0, 2, "%.2f");
        ImGui.SliderFloat("Occlusion Strength", *m.occlusion_strength, 0, 1, "%.2f");
        flag_checkbox :: (label: *u8, flags: *Material_Flags, flag: Material_Flags) {
            value := (flags.* & flag) != 0;
            if ImGui.Checkbox(label, *value) {
                if value then flags.* |= flag; else flags.* &= ~flag;
            }
        }
        flag_checkbox("Base Color Map", *m.flags, .HAS_BASE_COLOR_MAP);
        flag_checkbox("Metallic/Roughness Map", *m.flags, .HAS_METALLIC_ROUGHNESS_MAP);
        flag_checkbox("Normal Map", *m.flags, .HAS_NORMAL_MAP);
        flag_checkbox("Occlusion Map", *m.flags, .HAS_OCCLUSION_MAP);
        flag_checkbox("Emissive Map", *m.flags, .HAS_EMISSIVE_MAP);
        flag_checkbox("Unlit", *m.flags, .UNLIT);
        flag_checkbox("Double Sided", *m.flags, .DOUBLE_SIDED);
        ImGui.TreePop();
    }
    if ImGui.Button("Deselect") then world.selected = -1;
}
