main :: () {
    result := gpu_init();
    defer gpu_shutdown();
    assert(result == .SUCCESS);

    result=, texture := gpu_create_texture(.{
        type = ._2D_ARRAY,
        dimensions = .[4, 4, 1],
        layer_count = 4,
        format = .R32_UINT,
        usage = .TRANSFER_DST | .TRANSFER_SRC,
    });
    assert(result == .SUCCESS);
    defer gpu_free(texture);

    staging_cpu, staging_gpu := gpu_malloc([16] u32);
    assert(staging_cpu != null);
    defer gpu_free(staging_cpu);

    readback_cpu, readback_gpu := gpu_malloc([16] u32, .READBACK);
    assert(readback_cpu != null);
    defer gpu_free(readback_cpu);

    transfer_queue := gpu_get_queue(.TRANSFER, 0);

    for layer: 0..3 {
        for 0..15 {
            staging_cpu.*[it] = xx (layer * 1000 + it);
        }

        result=, cmd_buff := gpu_start_command_recording(transfer_queue);
        assert(result == .SUCCESS);
        gpu_copy_to_texture(cmd_buff, texture, staging_gpu, mip = 0, layer_slice = .[xx layer, 1]);
        gpu_submit(cmd_buff);
        gpu_wait_idle();
    }

    for layer: 0..3 {
        memset(readback_cpu, 0, 16 * size_of(u32));

        result=, cmd_buff := gpu_start_command_recording(transfer_queue);
        assert(result == .SUCCESS);
        result = gpu_copy_from_texture(cmd_buff, readback_gpu, texture, mip = 0, layer_slice = .[xx layer, 1]);
        assert(result == .SUCCESS);
        gpu_submit(cmd_buff);
        gpu_wait_idle();

        for 0..15 {
            assert(readback_cpu.*[it] == layer * 1000 + it);
        }
    }
}

#import,file "../module.jai"(VALIDATION = true);
#import "Basic";
