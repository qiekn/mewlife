// ----------------------------------------------------------------------------: Grid puzzle rules (no renderer or UI dependencies)

BOARD_WIDTH :: 40;
BOARD_HEIGHT :: 40;
MAX_BOXES :: 8;

Grid_Position :: struct { x: s32; z: s32; }
Game_Turn :: enum { NONE; LEFT; RIGHT; BACK; }
Game_Motion :: enum { WALK; PUSH; BLOCKED; }
Game_Event_Kind :: enum { MOTION; STONE_SLIDE; PUSH_FAILED; SOLVED; RESET; }
Game_Event :: struct {
    kind: Game_Event_Kind;
    motion: Game_Motion;
    turn: Game_Turn;
    from, to: float; // Normalized action progress; the host resolves animation/audio assets.
    started: bool;
}

Game_Input :: struct {
    direction: Grid_Position;
    pressed: bool; // A fresh directional press in this frame, including a quick press/release.
    held: bool; // Continue at grid boundaries while the direction is down.
    run: bool;
    slow_time: bool;
    fast_time: bool;
    undo: bool;
    restart: bool;
}

Game_Snapshot :: struct {
    player: Grid_Position;
    boxes: [MAX_BOXES] Grid_Position;
    move_count: u32;
    facing: float;
}

Game_State :: struct {
    walls: [BOARD_WIDTH * BOARD_HEIGHT] bool;
    goals: [BOARD_WIDTH * BOARD_HEIGHT] bool;
    player: Grid_Position;
    boxes: [MAX_BOXES] Grid_Position;
    box_count: s32;
    player_position: Vector3;
    box_positions: [MAX_BOXES] Vector3;
    facing: float;
    visual_facing: float;
    turn: Game_Turn;
    turning: bool;
    turn_from, turn_angle: float;
    turn_time, turn_duration: float;
    motion_serial: u64;
    moving: bool;
    blocked: bool;
    blocked_box: s32 = -1;
    blocked_repeat_direction: Grid_Position;
    motion_started: bool;
    running: bool;
    pushed_box: s32 = -1;
    from, to: Vector3;
    box_from, box_to: Vector3;
    step_time: float;
    step_duration: float;
    move_count: u32;
    solved: bool;
    clock: World_Clock;
    history: [256] Game_Snapshot;
    history_count: s32;
    events: [32] Game_Event; // At most four events per iteration of the bounded update loop.
    event_count: s32;
}

game_grid_equal :: (a: Grid_Position, b: Grid_Position) -> bool { return a.x == b.x && a.z == b.z; }

game_grid_world :: (position: Grid_Position) -> Vector3 {
    return .{position.x.(float) - BOARD_WIDTH / 2, 0, position.z.(float) - BOARD_HEIGHT / 2};
}

game_reset :: (game: *Game_State) {
    serial := game.motion_serial + 1;
    game.* = .{};
    game.motion_serial = serial;
    // An open floor: keep the initial puzzle at the world origin without perimeter walls.
    center := Grid_Position.{BOARD_WIDTH / 2, BOARD_HEIGHT / 2};
    game.player = center;
    game.box_count = 2;
    game.boxes[0] = .{center.x - 1, center.z - 1};
    game.boxes[1] = .{center.x + 1, center.z - 1};
    game.goals[(center.z - 2) * BOARD_WIDTH + center.x - 1] = true;
    game.goals[(center.z - 2) * BOARD_WIDTH + center.x + 1] = true;
    game_sync_positions(game);
}

game_sync_positions :: (game: *Game_State) {
    game.player_position = game_grid_world(game.player);
    for index: 0..game.box_count - 1 { game.box_positions[index] = game_grid_world(game.boxes[index]); }
    game.moving = false;
    game.blocked = false;
    game.blocked_box = -1;
    game.running = false;
    game.pushed_box = -1;
    game.turning = false;
    game.visual_facing = game.facing;
}

game_motion_time :: (game: *Game_State) -> float { return game.turn_time + game.step_time; }
game_busy :: (game: *Game_State) -> bool { return game.moving || game.turning || game.blocked; }

game_emit :: (game: *Game_State, event: Game_Event) {
    assert(game.event_count < game.events.count);
    game.events[game.event_count] = event;
    game.event_count += 1;
}

game_turn_to :: (game: *Game_State, facing: float, run: bool) {
    // Positive Y rotation is a character-relative left turn. Resolve a half turn to the right
    // to match the imported 180Right clip; never interpolate the long way across +/- PI.
    angle := fmod_cycling(facing - game.visual_facing + PI, 2 * PI) - PI;
    game.turn = .NONE;
    game.turn_from = game.visual_facing;
    game.turn_angle = angle;
    game.turn_time = 0;
    game.turn_duration = 0;
    game.turning = abs(angle) > 0.0001;
    game.facing = facing;
    if !game.turning { game.visual_facing = facing; return; }
    game.turn = ifx abs(angle) > PI * 0.75 then .BACK else ifx angle > 0 then .LEFT else .RIGHT;
    game.turn_duration = ifx game.turn == .BACK then 0.32 else 0.22;
    if run then game.turn_duration *= 0.5;
}

game_is_wall :: (game: *Game_State, position: Grid_Position) -> bool {
    if position.x < 0 || position.x >= BOARD_WIDTH || position.z < 0 || position.z >= BOARD_HEIGHT then return true;
    return game.walls[position.z * BOARD_WIDTH + position.x];
}

game_is_goal :: (game: *Game_State, position: Grid_Position) -> bool {
    if position.x < 0 || position.x >= BOARD_WIDTH || position.z < 0 || position.z >= BOARD_HEIGHT then return false;
    return game.goals[position.z * BOARD_WIDTH + position.x];
}

game_find_box :: (game: *Game_State, position: Grid_Position) -> s32 {
    for index: 0..game.box_count - 1 {
        if game_grid_equal(game.boxes[index], position) then return xx index;
    }
    return -1;
}

game_is_solved :: (game: *Game_State) -> bool {
    for index: 0..game.box_count - 1 {
        position := game.boxes[index];
        if !game.goals[position.z * BOARD_WIDTH + position.x] then return false;
    }
    return game.box_count > 0;
}

game_push_history :: (game: *Game_State) {
    if game.history_count == game.history.count {
        for index: 1..game.history.count - 1 { game.history[index - 1] = game.history[index]; }
        game.history_count -= 1;
    }
    game.history[game.history_count] = .{game.player, game.boxes, game.move_count, game.facing};
    game.history_count += 1;
}

game_undo :: (game: *Game_State) {
    game.blocked_repeat_direction = .{};
    if game.history_count == 0 {
        game_sync_positions(game);
        game.motion_serial += 1;
        return;
    }
    game.history_count -= 1;
    snapshot := game.history[game.history_count];
    game.player = snapshot.player;
    game.boxes = snapshot.boxes;
    game.move_count = snapshot.move_count;
    game.facing = snapshot.facing;
    game.motion_serial += 1;
    game.turn = .NONE;
    game.turn_time = 0;
    game.step_time = 0;
    game.solved = game_is_solved(game);
    game_sync_positions(game);
}

game_begin_step :: (game: *Game_State, direction: Grid_Position, run: bool) -> bool {
    if game_busy(game) || abs(direction.x) + abs(direction.z) != 1 then return false;
    target := Grid_Position.{game.player.x + direction.x, game.player.z + direction.z};
    box := game_find_box(game, target);
    box_target := Grid_Position.{target.x + direction.x, target.z + direction.z};
    blocked := game_is_wall(game, target)
               || (box >= 0 && (game_is_wall(game, box_target) || game_find_box(game, box_target) >= 0));
    if !blocked then game_push_history(game);
    game_turn_to(game, atan2(direction.x.(float), direction.z.(float)), run);
    game.step_time = 0;
    game.step_duration = 0;
    game.pushed_box = -1;
    game.running = run;
    game.motion_serial += 1;
    game.motion_started = true;
    // A failed command still owns an action interval, but never reserves cells or enters undo history.
    if blocked {
        game.blocked = true;
        game.blocked_box = box;
        game.blocked_repeat_direction = direction;
        // Bump is 42 / 30 seconds; turn-to-blocked clips are 100 / 30 seconds.
        // Use a brisk two-times cadence like locomotion, including the authored recovery.
        duration: float = ifx game.turn == .NONE then 0.7 else 5.0 / 3;
        if run then duration *= 0.5;
        game.step_duration = duration - game.turn_duration;
        return false;
    }
    game.from = game.player_position;
    game.to = game_grid_world(target);
    game.player = target;
    game.pushed_box = box;
    if box >= 0 {
        game.box_from = game.box_positions[box];
        game.box_to = game_grid_world(box_target);
        game.boxes[box] = box_target;
    }
    game.moving = true;
    game.running = run;
    game.step_time = 0;
    game.step_duration = ifx run then 0.175 else 0.35;
    game.move_count += 1;
    game.solved = false;
    return true;
}

game_update :: (game: *Game_State, input: Game_Input, real_dt: float, paused: bool) {
    game.event_count = 0;
    if !paused {
        if input.restart then game_reset(game);
        else if input.undo then game_undo(game);
        if input.restart || input.undo then game_emit(game, .{kind = .RESET});
    }
    world_clock_update(*game.clock, real_dt, paused, input.slow_time, input.fast_time);
    if game.clock.dt <= 0 then return;
    if input.restart || input.undo then return;
    if input.pressed || !game_grid_equal(input.direction, game.blocked_repeat_direction) {
        game.blocked_repeat_direction = .{};
    }
    pressed := input.pressed;
    remaining := game.clock.dt;
    for 0..7 {
        if !game_busy(game) {
            if game.solved then break;
            if pressed || (input.held && !game_grid_equal(input.direction, game.blocked_repeat_direction)) {
                game_begin_step(game, input.direction, input.run);
            }
            pressed = false;
            if !game_busy(game) then break;
        }
        duration := game.turn_duration + game.step_duration;
        before := game_motion_time(game);
        event := Game_Event.{kind = .MOTION, turn = game.turn, from = before / duration,
                             started = game.motion_started,
                             motion = ifx game.blocked then .BLOCKED else ifx game.pushed_box >= 0 then .PUSH else .WALK};
        game.motion_started = false;
        if game.turning {
            turn_dt := min(remaining, game.turn_duration - game.turn_time);
            game.turn_time += turn_dt;
            remaining -= turn_dt;
            t := clamp(game.turn_time / game.turn_duration, 0.0, 1.0);
            game.visual_facing = game.turn_from + game.turn_angle * (t * t * (3 - 2 * t));
            if game.turn_time + 0.000001 >= game.turn_duration {
                game.turning = false;
                game.visual_facing = game.facing;
            }
        }
        if !game.turning {
            step_dt := min(remaining, game.step_duration - game.step_time);
            game.step_time += step_dt;
            remaining -= step_dt;
            if game.moving {
                t := clamp(game.step_time / game.step_duration, 0.0, 1.0);
                game.player_position = lerp(game.from, game.to, t);
                if game.pushed_box >= 0 then game.box_positions[game.pushed_box] = lerp(game.box_from, game.box_to, t);
            }
        }
        event.to = clamp(game_motion_time(game) / duration, 0.0, 1.0);
        game_emit(game, event);
        if game.pushed_box >= 0 && !game.turning && (event.started || before < game.turn_duration) {
            game_emit(game, .{kind = .STONE_SLIDE});
        }
        if game.blocked_box >= 0 && event.from < 0.12 && event.to >= 0.12 {
            game_emit(game, .{kind = .PUSH_FAILED});
        }
        if !game.turning && game.step_time + 0.000001 >= game.step_duration {
            was_moving := game.moving;
            game_sync_positions(game);
            if was_moving {
                game.solved = game_is_solved(game);
                if game.solved then game_emit(game, .{kind = .SOLVED});
            }
        }
        if remaining <= 0.000001 then break;
    }
}

#scope_file
#import "Basic";
#import "Math";
