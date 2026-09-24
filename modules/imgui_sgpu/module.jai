// ImGui 的 SGPU 后端：平台输入（Input / Window_Creation）、渲染器、字体与主题，
// 由 ui.jai 里的 Ui 统一封装。
//
// 渲染器与应用共享 SGPU 的句柄类型，所以 sgpu 模块在这里和在应用里必须用相同参数导入：
//     #import "sgpu"(VALIDATION = true);
//     #import "imgui_sgpu"(VALIDATION = true);

#module_parameters(VALIDATION := false);

#load "font.jai";
#load "input.jai";
#load "sgpu_backend.jai";
#load "theme.jai";
#load "ui.jai";

#scope_module

#import "Basic";
#import "Math";
#import "sgpu"(VALIDATION = VALIDATION);
ImGui :: #import "ImGui";
