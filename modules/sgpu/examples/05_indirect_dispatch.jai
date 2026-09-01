main :: () {
    result := gpu_init();
    defer gpu_shutdown();
    assert(result == .SUCCESS);

    args_cpu, args_gpu := gpu_malloc(Gpu_Dispatch_Args);
    assert(args_cpu != null);
    defer gpu_free(args_cpu);

    args_cpu.* = .{x = 4, y = 1, z = 1};

    output_cpu, output_gpu := gpu_malloc([256] u32, .READBACK);
    assert(output_cpu != null);
    defer gpu_free(output_cpu);

    for 0..255 {
        output_cpu.*[it] = 0;
    }

    success, spirv := compile_shader("../shaders/indirect_verify.slang");
    assert(success);
    pipeline := gpu_create_compute_pipeline(spirv);
    defer gpu_free_pipeline(pipeline);

    compute_queue := gpu_get_queue(.COMPUTE, 0);
    result=, cmd_buff := gpu_start_command_recording(compute_queue);
    assert(result == .SUCCESS);

    result = gpu_set_pipeline(cmd_buff, pipeline);
    assert(result == .SUCCESS);

    result = gpu_indirect_dispatch(cmd_buff, output_gpu, args_gpu);
    assert(result == .SUCCESS);

    gpu_submit(cmd_buff);
    gpu_wait_idle();

    for 0..255 {
        assert(output_cpu.*[it] == it + 1);
    }
}

#import,file "../module.jai"(VALIDATION = true);
#import "Basic";
