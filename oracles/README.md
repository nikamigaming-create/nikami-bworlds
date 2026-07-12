# Direct oracle source

These directories are the final, directly browsable Nikami oracle sources—not
generated examples or references to code stored elsewhere.

| Runtime | Direct source | Pinned upstream dependency |
| --- | --- | --- |
| Fallout: New Vegas | `xnvse/nvse_retail_oracle` | xNVSE `175bb2891c517d42ad5c206086f654960fa2e9b9` |
| Oblivion | `xobse/nikami_oblivion_hidden` and `xobse/nikami_oblivion_oracle` | xOBSE `5078a1dcd2d115bf1f900cfe698b6334cae61707` |
| Starfield | `sfse/nikami_starfield_oracle` | SFSE `48535cc4306ab345252bf740c20a1c6194929b0e` |

The project files retain their upstream-relative include paths. Place each
directory at the matching checkout root to compile it. Where Nikami changes an
existing upstream file, the complete final file is under `../upstream-overrides`
and the reviewable delta remains under `../patches`.

The full OpenMW/OpenMW VR C++ composite is not duplicated here. It is the
default `main` tree of `nikami-openmw-lab`.
