import "common";

// ----------------------------------------------------------------------------: 立方体像素着色器
//
// 直接输出顶点着色器插值过来的颜色。
// 交换链是 UNORM 格式，这里不做 sRGB 编码，所以颜色会偏暗一点；正式渲染器里会处理。

struct PS_Input {
    float3 color : COLOR;
}

// 这个例子没有像素参数；push constant 的像素槽位仍要传一个合法指针，见 006_cube.jai。
[vk::push_constant]
PixelParams<float3> unused;

[shader("pixel")]
float4 main(PS_Input input) : SV_Target0 {
    return float4(input.color, 1.0);
}
