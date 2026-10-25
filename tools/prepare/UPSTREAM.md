# Game file preparation (from gow3_android)

`scripts/` (`prepare.py`, `link_libc.py`, `link_modules.py`, `content_profile.py`, `patches.py`) and
`patches/God_of_War_III_Remastered.xml` are wyatt-poole/gow3_android at commit
5c2219dcf852e4ae010d12a7402d48d004f144fe (2026-10-17), the same commit as `native/runtime`,
GPL-2.0-or-later, copied unmodified. They write the formats the loader in `native/runtime/src`
reads (G3PROBE5, G3CONT01, G3PATCH2), so update them together with the runtime.

`make_gow3_folder.py` is ours: it runs the five scripts in `run.py`'s order and collects the output.
