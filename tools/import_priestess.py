"""Import the reference project's Priestess into the small mewlife runtime format.

Only this offline tool needs ootss-assets. The game loads the generated local files.
"""

from pathlib import Path
import argparse
import hashlib
import json
import math
import shutil
import struct
import sys


def require(condition, message):
    if not condition:
        raise ValueError(message)


def lines(path):
    return iter(line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip())


def floats(line, count):
    values = tuple(map(float, line.split()))
    require(len(values) == count and all(map(math.isfinite, values)), "Invalid float tuple")
    return values


def put_string(stream, value):
    data = value.encode("utf-8")
    stream.write(struct.pack("<I", len(data)))
    stream.write(data)


def import_model(source, output):
    path = source / "data/characters/cleric/cleric.mesh"
    data = lines(path)
    require(next(data) == "[1]", "Unsupported mesh version")
    counts = []
    for field in ("joint_count", "vertex_count", "triangle_count"):
        key, count = next(data).split()
        require(key == field, f"Expected {field}")
        counts.append(int(count))
    joint_count, vertex_count, triangle_count = counts
    require(0 < joint_count <= 512 and 0 < vertex_count < 1_000_000, "Invalid mesh counts")
    require(next(data) == "joints:", "Missing skeleton")
    joints = []
    for index in range(joint_count):
        name = next(data)
        matrix = sum((floats(next(data), 4) for _ in range(4)), ())
        parent = int(next(data))
        require(-1 <= parent < index, "Skeleton must be parent first")
        joints.append((name, parent, matrix))
    require(next(data) == "vertices:", "Missing vertices")
    uv_data = path.with_suffix(".uv").read_bytes()
    require(uv_data[:4] == b"UVM1" and struct.unpack_from("<I", uv_data, 4)[0] == vertex_count,
            "UV count mismatch")
    require(len(uv_data) == 8 + vertex_count * 8, "Invalid UV size")
    vertices = bytearray()
    lower, upper = [math.inf] * 3, [-math.inf] * 3
    for index in range(vertex_count):
        position = floats(next(data), 3)
        normal = floats(next(data), 3)
        weights = list(floats(next(data), 3))
        weights.append(max(0.0, 1.0 - sum(weights)))
        bone_ids = tuple(map(int, next(data).split()))
        require(len(bone_ids) == 4 and all(-1 <= bone < joint_count for bone in bone_ids), "Invalid skin joints")
        weights = [max(0.0, weight) if bone >= 0 else 0.0 for weight, bone in zip(weights, bone_ids)]
        total = sum(weights)
        if total:
            weights = [weight / total for weight in weights]
        uv = struct.unpack_from("<2f", uv_data, 8 + index * 8)
        require(all(map(math.isfinite, uv)), "Non-finite UV")
        vertices.extend(struct.pack("<12f4I", *position, *normal, *uv, *weights,
                                    *(bone if bone >= 0 else 0xFFFFFFFF for bone in bone_ids)))
        for axis in range(3):
            lower[axis] = min(lower[axis], position[axis])
            upper[axis] = max(upper[axis], position[axis])
    require(next(data) == "triangles:", "Missing indices")
    indices = bytearray()
    for _ in range(triangle_count):
        triangle = tuple(map(int, next(data).split()))
        require(len(triangle) == 3 and all(0 <= v < vertex_count for v in triangle), "Invalid triangle")
        indices.extend(struct.pack("<3I", *triangle))
    require(next(data, None) is None, "Unexpected mesh data")

    data = lines(path.with_suffix(".parts"))
    require(next(data) == "[2]", "Unsupported material version")
    key, count = next(data).split()
    require(key == "part_count", "Missing material count")
    parts = []
    for _ in range(int(count)):
        name, first, count = next(data), int(next(data)), int(next(data))
        texture = Path(next(data))
        color = floats(next(data), 3)
        optional, repeat, mask = int(next(data)), int(next(data)), int(next(data))
        require(0 <= first < triangle_count * 3 and count > 0 and first + count <= triangle_count * 3,
                "Invalid material range")
        require(optional in (0, 1) and repeat in (0, 1), "Invalid material flags")
        texture_name = "textures/" + texture.name
        (output / "textures").mkdir(exist_ok=True)
        shutil.copyfile(source / texture, output / texture_name)
        parts.append((name, first, count, optional, repeat, mask, color, texture_name))
    require(next(data, None) is None, "Unexpected material data")
    with (output / "priestess.meshbin").open("wb") as stream:
        stream.write(struct.pack("<4s5I6f", b"MWMS", 1, vertex_count, triangle_count * 3,
                                 joint_count, len(parts), *lower, *upper))
        for name, parent, matrix in joints:
            put_string(stream, name)
            stream.write(struct.pack("<i16f", parent, *matrix))
        for name, first, count, optional, repeat, mask, color, texture in parts:
            put_string(stream, name)
            put_string(stream, texture)
            stream.write(struct.pack("<5I4f", first, count, optional, repeat, mask, *color, 1.0))
        stream.write(vertices)
        stream.write(indices)
    return joints, {"vertices": vertex_count, "triangles": triangle_count, "joints": joint_count,
                    "parts": len(parts), "bounds_min": lower, "bounds_max": upper}


def import_animations(source, output, joints):
    # Reuse the reference's validated decoder without writing into that project.
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(source / "tools"))
    from ootss_formats import Animation

    clips = {
        "idle": "active_idle_01", "walk": "active_moveForward_01", "push": "push_walkForward_01",
        "turn_left": "active_idleToMove90Left_01", "turn_right": "active_idleToMove90Right_01",
        "turn_back": "active_idleToMove180Right_01",
        "push_turn_left": "active_idleToPushMove90Left_01", "push_turn_right": "active_idleToPushMove90Right_01",
        "push_turn_back": "active_idleToPushMove180Right_01",
        "blocked": "active_bumpForward_01",
        "blocked_left": "active_idleToBlocked90Left_01", "blocked_right": "active_idleToBlocked90Right_01",
        "blocked_back": "active_idleToBlocked180Right_01",
    }
    result = {}
    for name, original in clips.items():
        path = source / f"data/characters/cleric/animations/cleric_{original}.anim"
        raw = path.read_bytes()
        animation = Animation.read(raw, original)
        mapping = [animation.joint_names.index(joint[0]) for joint in joints]
        require(len(mapping) == len(animation.joint_names), "Unsupported animation rig")
        for index, (_, parent, _) in enumerate(joints):
            require(animation.parents[mapping[index]] == (-1 if parent == -1 else mapping[parent]),
                    "Animation hierarchy differs from the model")
        # These source clips keep root yaw constant; the game must supply the turn once, not twice.
        if "turn" in name or name.startswith("blocked"):
            for joint, parent in enumerate(animation.parents):
                if parent != -1:
                    continue
                first = animation.sample(joint, 0, unit_scale=0.01, y_up=True)[1]
                for frame in range(animation.frame_count):
                    rotation = animation.sample(joint, frame, unit_scale=0.01, y_up=True)[1]
                    require(abs(sum(a * b for a, b in zip(first, rotation))) > 0.9999,
                            "Turn root rotates; extract its heading before using game-owned yaw")
        with (output / f"{name}.animbin").open("wb") as stream:
            stream.write(struct.pack("<4s3If", b"MWAN", 1, len(joints), animation.frame_count, animation.fps))
            for frame in range(animation.frame_count):
                for joint in mapping:
                    position, rotation, scale = animation.sample(joint, frame, unit_scale=0.01, y_up=True)
                    values = (*position, *rotation, *scale)
                    require(all(map(math.isfinite, values)), "Invalid animation sample")
                    stream.write(struct.pack("<16f", *values))
        result[name] = {"source": path.relative_to(source).as_posix(), "sha256": hashlib.sha256(raw).hexdigest(),
                        "frames": animation.frame_count, "fps": animation.fps,
                        "loop": "turn" not in name and not name.startswith("blocked")}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="ootss-assets project directory")
    parser.add_argument("--output", type=Path, default=Path("assets/models/priestess"))
    args = parser.parse_args()
    source, output = args.source.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    joints, mesh_info = import_model(source, output)
    clips = import_animations(source, output, joints)
    manifest = {"character": "Priestess", "source_id": "cleric", "format_version": 1,
                "coordinates": "Y up, metres; row-major matrices", "mesh": mesh_info, "clips": clips,
                "run": "Uses walk at a faster playback rate; no separate run clip exists in this source set."}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
