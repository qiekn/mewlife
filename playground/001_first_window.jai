#import "Window_Creation";
#import "Input";

main :: () {
    the_window := create_window(1200, 800, "ck: window");

    quit := false;
    while !quit {
        update_window_events();

        for events_this_frame {
            if it.type == .QUIT then quit = true;

            if it.type == .KEYBOARD {
                if it.key_pressed == 0 continue;

                if it.key_code == .ESCAPE {
                    quit = true;
                }
            }
        }
    }
}
