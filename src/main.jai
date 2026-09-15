main :: () { app_run(); }

#import "sgpu"(VALIDATION = true);
#import "Basic";
#import "Math";
#import "String";
ImGui :: #import "ImGui";
Input :: #import "Input";

#load "app.jai";
#load "app_audio.jai";
#load "engine/assets.jai";
#load "engine/animation.jai";
#load "engine/audio.jai";
#load "engine/camera.jai";
#load "engine/color.jai";
#load "engine/time.jai";
#load "render/scene.jai";
#load "render/imgui_sgpu.jai";
#load "platform/window.jai";
#load "platform/input.jai";
#load "platform/imgui_input.jai";
#load "editor/editor.jai";
#load "game/game.jai";
#load "game/menu.jai";
#load "ui/imgui_font.jai";
#load "ui/imgui_theme.jai";
#load "ui/colors.jai";
#load "ui/widgets.jai";
#load "ui/console.jai";
#load "ui/console_view.jai";
#load "ui/menu_view.jai";
