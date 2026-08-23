# SMAA lookup textures

`AreaTexDX10.dds` and `SearchTex.dds` are the unmodified lookup textures from
Jorge Jimenez's official [SMAA reference implementation](https://github.com/iryoku/smaa).
They are non-sRGB data textures with no mipmaps or repeat. Both use the
official linear/clamp lookup convention.

The reference implementation is distributed under the MIT License; see
`LICENSE-SMAA.txt` in this directory. The shader ports in the parent directory
preserve the reference presets and lookup conventions while using Godot shader syntax.
