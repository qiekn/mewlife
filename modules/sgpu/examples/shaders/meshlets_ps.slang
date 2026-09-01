struct Vertex {
    float4 pos: SV_Position;
}

struct Primitive {
    [[vk::location(0)]]
    nointerpolation float3 color;
    bool cull: SV_CullPrimitive;
}

[shader("fragment")]
float3 main(Vertex vert, Primitive prim) {
    return prim.color;
}
