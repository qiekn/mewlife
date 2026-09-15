"""Import one static Sokoban crystal from the local game using ootss-assets decoders."""

from pathlib import Path
import argparse
import hashlib
import json
import math
import struct
import sys

sys.dont_write_bytecode = True
from import_priestess import put_string, require


def read_static_mesh(path, reader_type, decompress):
    raw = path.read_bytes()
    require(len(raw) >= 12, "Missing mesh header")
    version, mesh_version, compression, full_size = struct.unpack_from("<HHII", raw)
    require((version, mesh_version, compression) == (1, 13, 1), "Unsupported mesh format")
    require(12 <= full_size <= 256 * 1024 * 1024, "Invalid mesh size")
    reader = reader_type(decompress(raw[12:], full_size - 12), path.name)
    lod_count, vertex_count, _, _, skinned = reader.unpack("IIIHH")
    bounds = reader.unpack("6f")
    reader.take(12)  # Pivot; positions are already in mesh space.
    material_count = reader.number("I")
    require(skinned == 0 and 0 < vertex_count < 1_000_000, "Expected a static mesh")
    require(0 < lod_count <= 8 and 0 < material_count < 1000, "Invalid mesh counts")
    positions = list(struct.iter_unpack("<3f", reader.take(vertex_count * 12)))
    require(all(math.isfinite(v) for position in positions for v in position), "Invalid vertex")
    # The first attribute stream is 20 bytes/vertex (UV + packed vectors), followed by 4 bytes/vertex.
    attributes = reader.take(vertex_count * 24)
    uvs = [struct.unpack_from("<2f", attributes, index * 20) for index in range(vertex_count)]
    require(all(math.isfinite(v) for uv in uvs for v in uv), "Invalid UV")
    lods = []
    for _ in range(lod_count):
        surfaces = [reader.unpack("III") for _ in range(material_count)]
        words, byte_count, encoding = reader.unpack("IIH")
        require(encoding in (0, 1) and byte_count == words * 2, "Invalid index encoding")
        index_size = 2 if encoding == 0 else 4
        require(byte_count % index_size == 0, "Invalid index size")
        indices = reader.unpack(str(byte_count // index_size) + ("H" if encoding == 0 else "I"))
        require(indices and max(indices) < vertex_count, "Index outside vertex buffer")
        for material, count, first in surfaces:
            require(material < material_count and count % 3 == 0 and first + count <= len(indices),
                    "Invalid material range")
        lods.append((surfaces, indices))
    materials = [reader.string("H") for _ in range(material_count)]
    reader.end()  # Unlike skinned v13 meshes, static meshes have no skeleton trailer.
    return raw, positions, uvs, lods, materials, bounds


def import_crystal(game, source, output):
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(source / "tools"))
    from ootss_formats import Package, Reader, lz4_block
    from ootss_textures import MaterialLibrary, decode_texture, write_png

    name = "GAME_SOKO_Crystal_A"
    mesh_path = game / "data-common" / (name + ".compressed_mesh")
    raw, positions, uvs, lods, materials, source_bounds = read_static_mesh(mesh_path, Reader, lz4_block)
    surfaces, source_indices = lods[0]
    # Keep the highest-detail front surfaces; stored indices also include reversed back faces.
    indices, parts = [], []
    for material, count, first in surfaces:
        if not count:
            continue
        parts.append((materials[material], len(indices), count))
        indices.extend(source_indices[first:first + count])
    used = sorted(set(indices))
    remap = {old: new for new, old in enumerate(used)}
    positions = [positions[index] for index in used]
    uvs = [uvs[index] for index in used]
    indices = [remap[index] for index in indices]
    positions = [(x, z, -y) for x, y, z in positions]
    lower = [min(p[axis] for p in positions) for axis in range(3)]
    upper = [max(p[axis] for p in positions) for axis in range(3)]
    scale = 0.94 / max(upper[axis] - lower[axis] for axis in range(3))
    center = ((lower[0] + upper[0]) * 0.5, lower[1], (lower[2] + upper[2]) * 0.5)
    positions = [tuple((p[axis] - center[axis]) * scale for axis in range(3)) for p in positions]
    lower = [min(p[axis] for p in positions) for axis in range(3)]
    upper = [max(p[axis] for p in positions) for axis in range(3)]
    normals = [[0.0] * 3 for _ in positions]
    for offset in range(0, len(indices), 3):
        a, b, c = indices[offset:offset + 3]
        ab = [positions[b][axis] - positions[a][axis] for axis in range(3)]
        ac = [positions[c][axis] - positions[a][axis] for axis in range(3)]
        cross = (ab[1] * ac[2] - ab[2] * ac[1], ab[2] * ac[0] - ab[0] * ac[2],
                 ab[0] * ac[1] - ab[1] * ac[0])
        for vertex in (a, b, c):
            for axis in range(3):
                normals[vertex][axis] += cross[axis]
    for index, normal in enumerate(normals):
        length = math.sqrt(sum(v * v for v in normal))
        normals[index] = tuple(v / length for v in normal) if length > 1e-12 else (0.0, 1.0, 0.0)

    library = MaterialLibrary(game, output)
    material_info = []
    for name, first, count in parts:
        fields = library.fields(name)
        texture_name = fields.get("Crystal_Color_Map", fields.get("color_map", '"white"')).strip('"')
        require(Path(texture_name).name == texture_name, "Invalid texture name")
        texture_path = game / "data-pc" / (texture_name + ".texture")
        width, height, pixels = decode_texture(texture_path)
        texture = "textures/" + texture_name + ".png"
        write_png(output / texture, width, height, pixels)
        core = tuple(map(float, fields.get("color_core", "(0.12 0.68 0.92)").strip("()").split()))
        rim = tuple(map(float, fields.get("color_glancing", "(1 1 1)").strip("()").split()))
        require(len(core) == 3 and len(rim) == 3, "Invalid crystal colors")
        material_info.append({"name": name, "first": first, "count": count, "texture": texture,
                              "core": core, "rim": rim, "emissive": float(fields.get("emissive_mult", "0")),
                              "source_fields": fields, "texture_sha256": hashlib.sha256(texture_path.read_bytes()).hexdigest()})

    with (output / "crystal.meshbin").open("wb") as stream:
        stream.write(struct.pack("<4s5I6f", b"MWMS", 1, len(positions), len(indices), 0,
                                 len(parts), *lower, *upper))
        for part in material_info:
            put_string(stream, part["name"])
            put_string(stream, part["texture"])
            stream.write(struct.pack("<5I4f", part["first"], part["count"], 0, 0, 0, *part["core"], 1.0))
        for position, normal, uv in zip(positions, normals, uvs):
            stream.write(struct.pack("<12f4I", *position, *normal, *uv, 0, 0, 0, 0, *([0xFFFFFFFF] * 4)))
        stream.write(struct.pack(f"<{len(indices)}I", *indices))

    outline_path = game / "data/mesh_outlines.mesh_outlines"
    mappings = [line for line in outline_path.read_text(encoding="utf-8").splitlines()
                if line.split() and line.split()[0] in ("cleric", "GAME_SOKO_Crystal_A")]
    outline = library.fields("entity_outline")
    shader_name = "data-pc/entity_outline--2048.shader"
    shader_blob = Package(game / "data/shaders.package").read(shader_name)
    manifest = {"source_id": "GAME_SOKO_Crystal_A", "game": str(game), "format_version": 1,
                "source": mesh_path.relative_to(game).as_posix(), "sha256": hashlib.sha256(raw).hexdigest(),
                "mesh": {"vertices": len(positions), "triangles": len(indices) // 3, "joints": 0,
                         "lod": 0, "bounds_min": lower, "bounds_max": upper, "source_bounds": source_bounds,
                         "uniform_scale": scale, "coordinates": "Y up, base at Y=0, fits inside a unit tile"},
                "materials": material_info,
                "outline_reference": {"mappings": mappings, "fields": outline,
                                      "shader": shader_name, "sha256": hashlib.sha256(shader_blob).hexdigest(),
                                      "note": "Compiled DirectX shader. SGPU uses a depth-tested inverted hull; no native shader is copied."}}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Imported crystal: {len(positions)} vertices, {len(indices) // 3} triangles, {len(parts)} material(s)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True, help="ootss-assets project directory")
    parser.add_argument("--output", type=Path, default=Path("assets/models/crystal"))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    import_crystal(args.game.resolve(), args.source.resolve(), args.output.resolve())


if __name__ == "__main__":
    main()
