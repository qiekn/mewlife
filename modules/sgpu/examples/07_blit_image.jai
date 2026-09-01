main :: () {
    result := gpu_init();
    defer gpu_shutdown();
    assert(result == .SUCCESS);

    result=, src_texture := gpu_create_texture(.{
        dimensions = .[4, 4, 1],
        format = .R32_UINT,
        usage = .TRANSFER_DST | .TRANSFER_SRC,
    });
    assert(result == .SUCCESS);
    defer gpu_free(src_texture);

    result=, dst_texture := gpu_create_texture(.{
        dimensions = .[2, 2, 1],
        format = .R32_UINT,
        usage = .TRANSFER_DST | .TRANSFER_SRC,
    });
    assert(result == .SUCCESS);
    defer gpu_free(dst_texture);

    staging_cpu, staging_gpu := gpu_malloc([16] u32);
    assert(staging_cpu != null);
    defer gpu_free(staging_cpu);

    for 0..15 {
        staging_cpu.*[it] = xx it;
    }

    readback_cpu, readback_gpu := gpu_malloc([4] u32, .READBACK);
    assert(readback_cpu != null);
    defer gpu_free(readback_cpu);

    main_queue := gpu_get_queue(.MAIN, 0);

    result=, cmd_buff := gpu_start_command_recording(main_queue);
    assert(result == .SUCCESS);
    gpu_copy_to_texture(cmd_buff, src_texture, staging_gpu);
    gpu_barrier(cmd_buff, .TRANSFER, .TRANSFER);
    result = gpu_blit_image(cmd_buff, dst_texture, src_texture, src_mip = 0, dst_mip = 0, .NEAREST);
    assert(result == .SUCCESS);
    gpu_barrier(cmd_buff, .TRANSFER, .TRANSFER);
    result = gpu_copy_from_texture(cmd_buff, readback_gpu, dst_texture, mip = 0);
    assert(result == .SUCCESS);
    gpu_submit(cmd_buff);
    gpu_wait_idle();

    assert(readback_cpu.*[0] == 5);
    assert(readback_cpu.*[1] == 7);
    assert(readback_cpu.*[2] == 13);
    assert(readback_cpu.*[3] == 15);
}

#import,file "../module.jai"(VALIDATION = true);
#import "Basic";
