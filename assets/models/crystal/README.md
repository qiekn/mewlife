# Crystal box asset

Extracted from the user-specified local installation:
`E:/SteamLibrary/steamapps/common/Order of the Sinking Star Demo`.
The source mesh is `data-common/GAME_SOKO_Crystal_A.compressed_mesh`.

Reimport from the mewlife project root:

```powershell
python tools/import_crystal.py --game "E:/SteamLibrary/steamapps/common/Order of the Sinking Star Demo" --source C:/msys64/home/user/projects/ootss-assets
```

The importer reuses the reference project's package, LZ4, material-inheritance, BC1/BC3 texture,
and PNG decoders. Static v13 meshes have 12-byte positions, a 20-byte attribute stream followed by
four additional bytes per vertex, and no skeleton trailer; their layout differs from skinned meshes.
The tool validates all LODs but exports only the declared highest-detail front surfaces.
It writes only into the chosen output directory and has no runtime dependency on Python or the game installation.

`crystal.meshbin` uses the same `MWMS` version-1 format as Priestess, with zero joints and no skin weights.
It has 4,849 vertices, 3,962 triangles, and one `crystal_Block_A` material. Source Z up is converted to
Y up, the base is placed at Y=0, and a uniform scale fits the mesh inside a 0.94-metre tile envelope.
The result is about 0.864 x 0.940 x 0.874 metres, leaving space between neighbouring boxes.

`textures/Crystal_Block_A-diffuse.png` is the original 1024 x 1024 diffuse texture. The source material
uses the `Crystal_Color_Map` field, which differs from the character materials' `color_map` field.
The compact opaque shader uses the source core/rim colors and emissive value. It does not implement
the game's refraction, screen-space reflections, fracture parallax, or full material system.

`manifest.json` records mesh and texture hashes, coordinate conversion, material fields, and the
outline reference. `data/mesh_outlines.mesh_outlines` maps `cleric` and this crystal to `entity_outline`.
The material sets `outline_width` to 2.809818. Its shader entries in `data/shaders.package` are
LZ4-compressed compiled DirectX containers, including DXIL, not editable source.
Mewlife uses its own depth-tested, skinned inverted hull for the character outline, with DPI scaling
and distance thinning. The original outline gradient/post-processing is not imported.
