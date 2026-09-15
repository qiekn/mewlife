// World time is separate from real time used by input, cameras, menus and the console.
World_Clock :: struct {
    elapsed: float64;
    dt: float;
    scale: float = 1;
}

world_clock_update :: (clock: *World_Clock, real_dt: float, paused: bool, slow: bool, fast: bool) {
    clock.scale = ifx slow == fast then 1.0 else ifx slow then 0.25 else 4.0;
    clock.dt = ifx paused then 0.0 else clamp(real_dt, 0.0, 0.1) * clock.scale;
    clock.elapsed += clock.dt;
}

#scope_file
#import "Basic";
