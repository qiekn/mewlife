import common;

[[vk::push_constant]]
ComputeParams<uint> params;

[shader("compute")]
[numthreads(64)]
void main(uint3 tid: SV_DispatchThreadID) {
    uint* buf = params.get();
    buf[tid.x] = tid.x + 1;
}
