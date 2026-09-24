import "common";

// ----------------------------------------------------------------------------: 立方体顶点着色器
//
// 与 playground/006_cube.jai 里的 Vertex_Params 逐字节一致：
//   float4x4 占 64 字节，两个指针各 8 字节，共 80 字节。
// Slang 用 scalar 布局 + 行主序矩阵，Jai 的 Matrix4 也是按行存放，所以不用转置。

struct VS_Output {
    float4 position : SV_POSITION;   // 裁剪空间坐标，光栅化用
    float3 color    : COLOR;         // 传给像素着色器，会在三角形内部插值
}

struct Vertex_Params {
    float4x4 mvp;        // model * view * projection 合成的一个矩阵：局部坐标 -> 裁剪坐标
    float3*  positions;  // 顶点位置数组的 GPU 地址（buffer device address）
    float3*  colors;     // 顶点颜色数组的 GPU 地址
};

// push constant 里只有一个 8 字节的指针，指向上面这个结构；真正的数据都在显存里。
[vk::push_constant]
VertexParams<Vertex_Params> sp;

[shader("vertex")]
VS_Output main(uint vertex_id : SV_VertexID) {
    // 先把参数整体拷到局部变量，避免多次经指针读取。
    Vertex_Params p = *sp.get();

    // 没有顶点输入布局：着色器拿到顶点编号，自己去数组里取。
    // 用索引缓冲绘制时，vertex_id 就是索引缓冲里的值。
    float3 local = p.positions[vertex_id];

    VS_Output output;
    // 列向量约定：矩阵在左、向量在右。w 填 1 表示这是一个点（会被平移）。
    output.position = mul(p.mvp, float4(local, 1.0));
    output.color = p.colors[vertex_id];
    return output;
}
