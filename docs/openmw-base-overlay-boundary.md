# OpenMW Base and Overlay Boundary

This file prevents the local OpenMW laboratory checkout from being mistaken for
a reproducible upstream base.

## Verified dependency state

As verified on 2026-07-10:

- official OpenMW is remote `upstream`, `https://gitlab.com/OpenMW/openmw.git`;
- the VR fork is remote `origin`, `https://gitlab.com/madsbuvi/openmw`;
- the overlay queue base is `c30c830d8e0b173e17eee17fc63cc059c559a5ba`;
- published `origin/openmw-vr` is `0f520f65c3e085369e66d6a90ce871e817d4533f`;
- the queue base is exactly 98 commits ahead of published `origin/openmw-vr`;
- observed official `upstream/master` is
  `13b1f39492a6291236078958ee91fef24a0128dd`; and
- the current Bethesda branch is not based on official master.

The machine-readable lock is `catalog/openmw-base-lock.json`.

## Honest layer model

1. Official OpenMW `master` is the moving engine reference.
2. The madsbuvi OpenMW-VR fork plus the unpublished 98-commit local delta is
   the current dependency base.
3. `patches/openmw/series` is the Bethesda flat-compatibility overlay.
4. VR integration is a later layer and is not part of the current flat proof
   gate.

Patch 0001 currently mixes the world-viewer snapshot with dormant XR-era source
from the local fork. A trial apply against official `upstream/master` failed at
patch 0001, including paths that do not exist there. Therefore neither the 98
commits nor patch 0001 may be called an official-master overlay.

## Required true-up

The next dependency true-up must make the 98-commit delta reviewable by doing
one of the following, in preference order:

1. pin a published remote commit containing the delta;
2. export the delta as a dedicated ordered `openmw-vr-base` queue; or
3. replace it with equivalent current upstream commits and a small explicit VR
   queue.

After that base is reproducible, split patch 0001 into a flat world-viewer topic
and an optional VR topic. Do not solve an official-master apply failure by
folding more fork code into the Bethesda flat patches.

## Downstream update gate

For any base update:

1. fetch both remotes and record their exact hashes in the lock;
2. recreate the dependency base without relying on an unnamed local branch;
3. replay every flat overlay patch cumulatively;
4. build `openmw.exe` and the focused component tests;
5. rerun FO3/FNV retail differentials and Morrowind/Oblivion regressions; and
6. keep VR disabled until the shared flat gate passes.

Conflicts are evidence that a rule needs revalidation. They are not permission
to preserve old behavior blindly.
