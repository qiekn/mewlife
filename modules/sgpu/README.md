# SGPU

A refreshingly simple graphics API for the Jai programming language, implemented on top of Vulkan and inspired by Sebastian Aaltonen's [No Graphics API](https://www.sebastianaaltonen.com/blog/no-graphics-api)

SGPU eliminates the complexity of modern graphics APIs by collapsing the traditional descriptor set model into a single unified pipeline layout backed by bindless resources and GPU "pointers" (BDA). Shader parameters are passed directly as GPU pointers via push constants, and all resources are accessed through simple indices. The result is a GPU programming model that feels more like writing regular C code than wrestling with API boilerplate.

## Features

- **Bindless resources** -- textures and samplers are accessed by index, no descriptor set management
- **GPU pointers** -- shader data is passed as raw GPU addresses through push constants
- **Slang shader compiler** -- built-in compile-to-SPIR-V via the [Slang](https://shader-slang.com/) compiler
- **RenderDoc API capture** support
- Cross-platform support: **Windows**, **Linux**, **macOS** 

## Module Parameters

SGPU is configured at import time through Jai module parameters:

| Parameter | Default | Description |
|---|---|---|
| `VALIDATION` | `false` | Enable Vulkan validation layers |
| `DEBUG_ASSERTS` | `false` | Enable internal debug assertions |
| `RENDER_CAPTURE` | `false` | Include RenderDoc capture API |
| `SLANG_COMPILER` | `true` | Include the Slang shader compiler submodule |
| `DEBUG_MARKERS` | `true` | Enable debug command buffer and object markers |

## Quick Start

### Initialization & Swapchain

```jai
gpu_init();
defer gpu_shutdown();

window := create_native_window(1280, 720, "My Window");

window_type: Native_Window_Type;
#if      OS == .WINDOWS then window_type = .WIN32;
else #if OS == .LINUX   then window_type = .X11;
else #if OS == .MACOS   then window_type = .COCOA;

gpu_init_swapchain(window, window_type);
defer gpu_destroy_swapchain();
```

### Memory & Arenas

```jai
// Typed allocation -- returns both a CPU pointer and a GPU pointer
data_cpu, data_gpu := gpu_malloc([1024] float);

// Device-local memory (no CPU access)
_, gpu_ptr := gpu_malloc([1024] float, .GPU);

// GPU arena for per-frame transient allocations
arena := gpu_make_arena(1024 * 1024);
defer gpu_free_arena(arena);

vertices, vertices_gpu := gpu_arena_alloc(*arena, [4] Vector2);
vertices.* = Vector2.[ .{-0.5, -0.5}, .{0.5, -0.5}, .{0.5, 0.5}, .{-0.5, 0.5} ];

// Reset the arena each frame to reuse the memory
gpu_reset_arena(*arena);
```

### Pipelines & Shaders

```jai
// Compile Slang shaders to SPIR-V
success, vs_spv := compile_shader("shaders/vertex.slang");
assert(success);
success, ps_spv := compile_shader("shaders/pixel.slang");
assert(success);

// Create a graphics pipeline
pipeline := gpu_create_graphics_pipeline(vs_spv, ps_spv, .{
    cull = .CW,
    color_targets = .[ .{format = .B8G8R8A8_UNORM} ],
});
defer gpu_free_pipeline(pipeline);

// Compute pipelines
compute_pipe := gpu_create_compute_pipeline(compute_spv);

// Mesh shader pipelines (requires .MESH_SHADERS optional feature)
mesh_pipe := gpu_create_meshlets_pipeline(mesh_spv, pixel_spv, raster_desc);
```

### Rendering Loop

```jai
main_queue := gpu_get_queue(.MAIN, 0);

while !quit {
    update_window_events();
    if get_window_resizes().count > 0 {
        gpu_swapchain_resize();
    }

    swapchain_image := gpu_swapchain_acquire();
    if !swapchain_image continue;

    cmd := gpu_start_command_recording(main_queue);

    gpu_begin_render_pass(cmd, .{
        color_targets = .[
            .{
                view = swapchain_image,
                load_op = .CLEAR,
                store_op = .STORE,
                clear_color._float = .[0, 0, 0, 1],
            }
        ]
    });

    gpu_set_pipeline(cmd, pipeline);
    gpu_draw_indexed_instanced(cmd, vertex_data_gpu, pixel_data_gpu, index_data_gpu, index_count, 1);

    gpu_end_render_pass(cmd);

    gpu_submit_and_present(main_queue, cmd);
}

gpu_wait_idle();
```

### Compute Dispatch

```jai
compute_queue := gpu_get_queue(.COMPUTE, 0);
cmd := gpu_start_command_recording(compute_queue);

gpu_set_pipeline(cmd, compute_pipeline);

// data_gpu is passed to the shader as a push constant (GPU pointer)
gpu_dispatch(cmd, data_gpu, .[num_groups_x, 1, 1]);

gpu_submit(cmd);
```

### Textures

```jai
texture := gpu_create_texture(.{
    type = ._2D,
    dimensions = .[512, 512, 1],
    format = .R8G8B8A8_SRGB,
    usage = .SAMPLED | .TRANSFER_DST,
});

view := gpu_create_texture_view(texture, .{
    format = .R8G8B8A8_SRGB,
});

sampler := gpu_create_sampler(.{ });

// Upload pixel data
gpu_copy_to_texture(cmd, texture, pixel_data_staging_buffer);

// Access in shaders directly via cpu handle/bindless index
texture_index := view;
sampler_index := sampler;
```

### Synchronization

```jai
// Timeline semaphores for cross-queue synchronization
sem := gpu_create_semaphore(0);
defer gpu_destroy_semaphore(sem);

gpu_submit(cmd, signals = .[.{sem, 1}]);

// Block CPU until GPU signals
gpu_wait_semaphore(.{semaphore = sem, value = 1});
```

### GPU Timestamps

```jai
begin := gpu_cmd_timestamp_write(cmd, .COMPUTE_SHADER);
// ... GPU work ...
end := gpu_cmd_timestamp_write(cmd, .COMPUTE_SHADER);

// Call after the frame completes
ready, ms := gpu_timestamp_duration_ms(begin, end);
if ready {
    print("GPU time: %ms\n", ms);
}
```

### RenderDoc Capture

```jai
// With RENDER_CAPTURE := true
gpu_capture_start();
// ... frame work ...
gpu_capture_end();

// Or use the scoped helper
gpu_scoped_capture();
```

## Core Design

### GPU Pointers Instead of Descriptors

Every shader invocation in SGPU receives user data as a raw `Gpu_Ptr` (a 64-bit device address) pushed via push constants. Textures and samplers are accessed bindlessly by index. This removes the need for descriptor set creation, binding, and management entirely.

```jai
// Push two GPU pointers to vertex and pixel shaders respectively
gpu_draw_indexed_instanced(cmd, vertex_params_gpu, pixel_params_gpu, index_gpu, 6, 1);
```

The corresponding Slang shader might look like:

```hlsl
// Vertex Shader
struct VertexData {
    float2* positions;
    float3* colors;
}
[[vk::push_constant]] VertexData* params;

// Pixel Shader
struct PixelData {
    TextureHandle<float4> texture;
}
[[vk::push_constant]] PixelData* params;
```
