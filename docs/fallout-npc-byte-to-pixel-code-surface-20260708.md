# Fallout NPC Byte-To-Pixel Code Surface - 2026-07-08

This is the one-file map of the code that makes Fallout 3 / Fallout: New Vegas NPCs appear and move in this OpenMW branch.

It follows the path from bytes on disk to pixels in a screenshot:

```text
BSA / loose files
  -> VFS resource lookup
  -> ESM4 NPC record, race, gear, packages
  -> NIF skeleton / body / head / clothing / weapon load
  -> OSG scene nodes and RigGeometry
  -> KF load and text-key/controller extraction
  -> controller-to-bone binding
  -> Animation::play group selection
  -> Animation::runAnimation per-frame pose update
  -> Skeleton bone matrices
  -> RigGeometry skinning / cull update
  -> OSG draw
  -> screenshot readback / PNG
  -> proof ledgers and contact sheet
```

## 1. Actor Spawn To Animation Object

The NPC becomes a renderable/animatable object when `Objects` chooses the ESM4 actor path.

Primary file:

- `D:\Modlists\fnv\openmw-source\apps\openmw\mwrender\objects.cpp`

Key line anchors:

- `objects.cpp:488` creates `new ESM4NpcAnimation(...)` for ESM4 NPCs.
- `objects.cpp:507` creates regular `NpcAnimation(...)` for TES3/Morrowind NPCs.

Lab variant:

- `D:\Modlists\fnv\openmw-source\apps\openmw\mwrender\objects_swg_lab.cpp`
- `objects_swg_lab.cpp:356` creates `new ESM4NpcAnimation(...)`.

Player Fallout visual proxy:

- `D:\Modlists\fnv\openmw-source\apps\openmw\mwrender\renderingmanager.cpp`
- `renderingmanager.cpp:1928` creates `mFalloutPlayerVisualAnimation = new ESM4NpcAnimation(...)`.

Meaning:

- If the NPC never reaches `ESM4NpcAnimation`, it will not use the Fallout assembly path.
- If it reaches this class, the runtime can build the Fallout skeleton, parts, animation sources, and proof telemetry.

## 2. ESM4 NPC Assembly

Primary file:

- `D:\Modlists\fnv\openmw-source\apps\openmw\mwrender\esm4npcanimation.cpp`

Class header:

- `D:\Modlists\fnv\openmw-source\apps\openmw\mwrender\esm4npcanimation.hpp`
- `esm4npcanimation.hpp:13` declares `class ESM4NpcAnimation : public Animation`.

Constructor:

- `esm4npcanimation.cpp:6583` starts `ESM4NpcAnimation::ESM4NpcAnimation(...)`.

The constructor pulls:

- NPC traits: `MWClass::ESM4Npc::getTraitsRecord(mPtr)`.
- Model record: `MWClass::ESM4Npc::getModelRecord(mPtr)`.
- Race: `MWClass::ESM4Npc::getRace(mPtr)`.
- Corrected skeleton model: `mPtr.getClass().getCorrectedModel(mPtr)`.
- Equipped armor/clothing/weapon through `MWClass::ESM4Npc`.

Key line anchors:

- `esm4npcanimation.cpp:6583` constructor begins.
- `esm4npcanimation.cpp:6625` calls `setObjectRoot(skeletonModel, true, true, false)`.
- `esm4npcanimation.cpp:6657` logs inserted attachment helpers.
- `esm4npcanimation.cpp:6667` calls `updateParts()`.
- `esm4npcanimation.cpp:6675` adds configured non-Fallout animation source.
- `esm4npcanimation.cpp:6700` defines `addFonvAnimationSource`.
- `esm4npcanimation.cpp:6707` calls `addSingleAnimSource(kfPath, skeletonModel, falloutProcedureIdle)`.

Attachment helpers inserted for FNV:

- `Weapon`
- `Torch`
- `SideWeapon`
- `BackWeapon`
- `Quiver`

These helpers are attachment frames. They are not human limbs and must not be treated as deform bones.

## 3. Skeleton Root And Body Parts

Object root:

- `esm4npcanimation.cpp:6625`
- `setObjectRoot(skeletonModel, true, true, false)`

Parts:

- `esm4npcanimation.cpp:6903` starts `ESM4NpcAnimation::updateParts()`.
- `esm4npcanimation.cpp:6932` dispatches Fallout actors to `updatePartsFONV(*traits)`.
- `esm4npcanimation.cpp:6952` starts `insertPart(...)`.
- `esm4npcanimation.cpp:7582` starts `insertAttachedPart(...)`.
- `esm4npcanimation.cpp:7741` starts `updatePartsFONV(...)`.
- `esm4npcanimation.cpp:8068` attaches equipped weapon through `insertAttachedPart(weapon->mModel, "Weapon")`.

Meaning:

- Skeleton appears first.
- Head/body/clothing/armor/weapon parts attach to the skeleton/attachment frames.
- Weapon pixels come from the weapon model attached to `Weapon`.
- Body pixels come from rigged/static geometry inserted as actor parts.

## 4. NIF/KF Bytes Into OSG Nodes

Primary NIF loader:

- `D:\Modlists\fnv\openmw-source\components\nifosg\nifloader.cpp`

Key line anchors:

- `nifloader.cpp:5753` starts `Loader::load(...)`.
- `nifloader.cpp:5762` starts `Loader::loadKf(...)`.
- `nifloader.cpp:1795` starts internal `load(Nif::FileView nif)`.
- `nifloader.cpp:1587` warns when a KF lacks `NiSequenceStreamHelper`.
- `nifloader.cpp:1595` warns when sequence helper has no text keys.
- `nifloader.cpp:1602` warns when first extra data is not `NiTextKeyExtraData`.
- `nifloader.cpp:3579` creates `SceneUtil::RigGeometry` for skinned `NiTriShape`.
- `nifloader.cpp:3580` calls `rig->setSourceGeometry(geom)`.
- `nifloader.cpp:3632` calls `rig->setBoneInfo(...)`.
- `nifloader.cpp:3633` calls `rig->setInfluences(...)`.
- `nifloader.cpp:4077` creates `SceneUtil::RigGeometry` for skinned `BSTriShape`.
- `nifloader.cpp:4078` calls `rig->setSourceGeometry(...)`.
- `nifloader.cpp:4101` calls `rig->setBoneInfo(...)`.
- `nifloader.cpp:4102` calls `rig->setInfluences(...)`.
- `nifloader.cpp:5402` starts `applyDrawableProperties(...)`.

Meaning:

- NIF bytes become OSG nodes and drawables.
- Skin data becomes `RigGeometry` bone info and vertex weights.
- KF bytes become `SceneUtil::KeyframeHolder` controller maps and text keys.
- Text-key extraction is mandatory for real animation group playback.

## 5. Fallout Rig Skinning

Primary file:

- `D:\Modlists\fnv\openmw-source\components\sceneutil\riggeometry.hpp`
- `D:\Modlists\fnv\openmw-source\components\sceneutil\riggeometry.cpp`

Key line anchors:

- `riggeometry.hpp:32` declares `class RigGeometry : public osg::Drawable`.
- `riggeometry.hpp:57` declares `setBoneInfo(...)`.
- `riggeometry.hpp:59` declares vertex-weight `setInfluences(...)`.
- `riggeometry.hpp:61` declares bone-weight `setInfluences(...)`.
- `riggeometry.hpp:65` declares `setSourceGeometry(...)`.
- `riggeometry.hpp:79` declares `setFalloutCharacterSkinning(bool enabled)`.
- `riggeometry.hpp:86` declares `getLastFrameGeometry()`.
- `riggeometry.hpp:88` declares `forceNextUpdate()`.
- `riggeometry.hpp:91` declares `accept(osg::NodeVisitor& nv)`.
- `riggeometry.hpp:110` declares `cull(osg::NodeVisitor* nv)`.
- `riggeometry.cpp:227` implements `RigGeometry::setFalloutCharacterSkinning(...)`.
- `riggeometry.cpp:268` implements `RigGeometry::setSourceGeometry(...)`.
- `riggeometry.cpp:345` implements `RigGeometry::getLastFrameGeometry()`.
- `riggeometry.cpp:350` implements `RigGeometry::forceNextUpdate()`.
- `riggeometry.cpp:578` implements `RigGeometry::cull(...)`.
- `riggeometry.cpp:1137` implements `RigGeometry::setBoneInfo(...)`.
- `riggeometry.cpp:1145` implements vertex-weight `setInfluences(...)`.
- `riggeometry.cpp:1167` implements bone-weight `setInfluences(...)`.
- `riggeometry.cpp:1436` implements `RigGeometry::accept(...)`.

Fallout actor rig marking:

- `esm4npcanimation.cpp:2507` calls `rig->setFalloutCharacterSkinning(true)`.

Meaning:

- This is the code that turns animated bones into moved vertices.
- If bone matrices are wrong, vertices twist.
- If skinning mode/bind basis is wrong, the mesh deforms incorrectly even when the skeleton looks plausible.
- If cull/update does not refresh, the visual pixels can show stale or invalid geometry.

## 6. Skeleton Bone Matrices

Primary file:

- `D:\Modlists\fnv\openmw-source\components\sceneutil\skeleton.hpp`
- `D:\Modlists\fnv\openmw-source\components\sceneutil\skeleton.cpp`

Key line anchors:

- `skeleton.hpp:12` describes `Bone` hierarchy.
- `skeleton.hpp:41` declares `getBone(...)`.
- `skeleton.hpp:46` declares `updateBoneMatrices(...)`.
- `skeleton.hpp:67` declares `markBoneMatriceDirty()`.
- `skeleton.cpp:36` starts `Skeleton::Skeleton()`.
- `skeleton.cpp:61` starts `Skeleton::getBone(...)`.
- `skeleton.cpp:102` starts `Skeleton::updateBoneMatrices(...)`.
- `skeleton.cpp:144` starts `Skeleton::markBoneMatriceDirty()`.
- `skeleton.cpp:180` starts `Bone::update(...)`.

Meaning:

- Controllers update node transforms.
- Skeleton caches named bone paths.
- `updateBoneMatrices` turns node transforms into skeleton-space bone matrices.
- `RigGeometry` consumes those matrices to skin vertices.

## 7. KF/Controller Binding

Primary file:

- `D:\Modlists\fnv\openmw-source\apps\openmw\mwrender\animation.cpp`

Source loading:

- `animation.cpp:2902` starts `Animation::Animation(...)`.
- `animation.cpp:3022` starts `Animation::addAnimSource(...)`.
- `animation.cpp:4223` starts `Animation::addSingleAnimSource(...)`.

Controller/text-key binding:

- `animation.cpp:4248` synthesizes creature KF text-key groups.
- `animation.cpp:4261` enters FNV actor animation handling.
- `animation.cpp:4292` logs synthesized actor KF text-key groups.
- `animation.cpp:4318` reads the source controller map.
- `animation.cpp:4341` iterates keyframe controllers.
- `animation.cpp:4358` logs missing target bones.
- `animation.cpp:4363` checks synthetic attachment helper skip.
- `animation.cpp:4384` clones controllers per animation instance.
- `animation.cpp:4399` sets Fallout actor transform basis on NIF controllers.
- `animation.cpp:4434` inserts cloned controllers into the animation source controller map.
- `animation.cpp:4460` logs procedure text keys.
- `animation.cpp:4465` logs controller binding count.
- `animation.cpp:4473` logs matched/missing controller audit result.

Synthetic helper gate:

- `animation.cpp:293` starts `shouldSkipFalloutSyntheticAttachmentHelperControllers(...)`.

Meaning:

- This is the bone mapping core.
- The KF does not move the actor unless its controller target names match runtime skeleton node names.
- Missing controllers produce bind-pose limbs.
- Wrong helper binding can twist or explode attachments.

## 8. Animation Group Playback

Primary file:

- `D:\Modlists\fnv\openmw-source\apps\openmw\mwrender\animation.cpp`

Key line anchors:

- `animation.cpp:4693` starts `Animation::play(...)`.
- `animation.cpp:4790` counts controllers for active states.
- `animation.cpp:4841` searches text keys.
- `animation.cpp:4970` starts blend-controller helper template.
- `animation.cpp:5019` begins controller callback install accounting.
- `animation.cpp:5061` iterates controllers for the selected blend mask.
- `animation.cpp:5074` binds `NifAnimBlendController`.
- `animation.cpp:5079` binds `BoneAnimBlendController`.
- `animation.cpp:5093` tracks active controllers.
- `animation.cpp:5123` calls `addControllers()`.

Look for logs:

- `FNV/ESM4 diag: play request`
- `FNV/ESM4 diag: play matched`
- `FNV/ESM4 diag: play failed to match`
- `FNV/ESM4 diag: active animation group reset`
- `activeGroups=[...]`

Meaning:

- Text keys choose group names like idle/walk/turn/procedure.
- Active controllers are installed as OSG callbacks.
- If no group matches, the skeleton can look like a clean T-pose because nothing is driving it.

## 9. Per-Frame Movement

Primary base path:

- `D:\Modlists\fnv\openmw-source\apps\openmw\mwrender\animation.cpp`

Key line anchors:

- `animation.cpp:5315` starts `Animation::runAnimation(float duration)`.
- `animation.cpp:5423` starts manual Fallout controller application accounting.
- `animation.cpp:5475` iterates active source controllers.
- `animation.cpp:5488` samples `getCurrentTransformation(...)`.
- `animation.cpp:5495` can sample raw transform without Fallout basis.
- `animation.cpp:5712` increments skipped helper controller count.
- `animation.cpp:5868` increments applied controller count.
- `animation.cpp:5912` calls `applyFalloutSeatedHumanIk(...)`.
- `animation.cpp:5951` logs `manually applied ... active keyframe controller(s)`.
- `animation.cpp:6030` applies runtime human IK/posture when gated.
- `animation.cpp:6035` starts standing upper-body proof audit gate.
- `animation.cpp:6046` calls `auditFalloutStandingUpperBody(...)`.

Primary Fallout override path:

- `D:\Modlists\fnv\openmw-source\apps\openmw\mwrender\esm4npcanimation.cpp`

Key line anchors:

- `esm4npcanimation.cpp:6830` starts `applyPostManualFalloutActorPose()`.
- `esm4npcanimation.cpp:6836` calls `applyFalloutWeaponGripIk(...)`.
- `esm4npcanimation.cpp:6839` starts `ESM4NpcAnimation::runAnimation(float duration)`.
- `esm4npcanimation.cpp:6847` calls `applyFalloutWeaponGripIk(...)`.
- `esm4npcanimation.cpp:6865` calls `forceFalloutRigGeometryUpdate(...)`.

Meaning:

- `Animation::runAnimation` advances and samples controllers.
- Fallout-specific manual application writes sampled transforms into live/duplicate transform targets.
- Post-pose logic handles human IK/audits and weapon support.
- `ESM4NpcAnimation::runAnimation` runs after the base path and refreshes Fallout rig geometry.

## 10. Weapon / Hands / Attachment Movement

Primary file:

- `D:\Modlists\fnv\openmw-source\apps\openmw\mwrender\esm4npcanimation.cpp`

Key line anchors:

- `esm4npcanimation.cpp:4777` starts `applyFalloutWeaponGripIk(...)`.
- `esm4npcanimation.cpp:5045` calls `forceFalloutRigGeometryUpdate(...)` inside weapon IK.
- `esm4npcanimation.cpp:5621` starts `stabilizeFalloutLongGunWeaponFrame(...)`.
- `esm4npcanimation.cpp:5679` starts `stabilizeFalloutSidearmWeaponFrame(...)`.
- `esm4npcanimation.cpp:5737` starts `applyFalloutLongGunOffhandIk(...)`.
- `esm4npcanimation.cpp:8068` attaches equipped weapon model to `Weapon`.

Meaning:

- Hands move from skeleton/KF first.
- Weapon attaches to `Weapon`.
- Weapon IK can adjust arms/hand/weapon frame when enabled and valid.
- Long-gun offhand support tries to keep the left hand near the visible fore-end.
- This area is where "treat an arm like an arm" lives: two-bone solve, reachable target, pole hint, grip span, hand orientation.

## 11. Human Posture / Limb Audit

Primary file:

- `D:\Modlists\fnv\openmw-source\apps\openmw\mwrender\animation.cpp`

Key line anchors:

- `animation.cpp:1535` starts `applyFalloutSeatedHumanIk(...)`.
- `animation.cpp:1882` starts `auditFalloutStandingUpperBody(...)`.
- `animation.cpp:2471` logs runtime part audit rows.
- `animation.cpp:2488` logs runtime part audit summary.

Proof harness:

- `D:\code\nikami-worlds\scripts\Measure-ActorLimbAnatomy.ps1`
- `D:\code\nikami-worlds\scripts\Measure-ActorFabrikTelemetry.ps1`
- `D:\code\nikami-worlds\scripts\Measure-ActorWeaponIkTelemetry.ps1`
- `D:\code\nikami-worlds\scripts\Measure-ActorRootAttachmentTelemetry.ps1`

Meaning:

- This is the math layer that says whether a visible actor is human-shaped.
- It checks spans, reach, collapse, stretch, root orientation, weapon grip, and FABRIK target quality.
- Screenshots are downstream evidence; these ledgers are the frictionless math harness.

## 12. Rig Geometry To Pixels

Primary files:

- `D:\Modlists\fnv\openmw-source\components\sceneutil\riggeometry.cpp`
- `D:\Modlists\fnv\openmw-source\components\sceneutil\riggeometryosgaextension.cpp`
- `D:\Modlists\fnv\openmw-source\apps\openmw\mwrender\screenshotmanager.cpp`
- `D:\Modlists\fnv\openmw-source\components\sceneutil\screencapture.cpp`

Rig update/cull:

- `riggeometry.cpp:578` starts `RigGeometry::cull(...)`.
- `riggeometry.cpp:1436` starts `RigGeometry::accept(osg::NodeVisitor& nv)`.
- `riggeometry.cpp:1452` calls `cull(&nv)` for cull traversal.
- `riggeometry.cpp:1464` starts `RigGeometry::accept(osg::PrimitiveFunctor& func)`.
- `riggeometryosgaextension.cpp:158` starts `RigGeometryHolder::updateRigGeometry(...)`.
- `riggeometryosgaextension.cpp:177` sets skeleton on the per-frame rig geometry.
- `riggeometryosgaextension.cpp:207` runs source geometry updater.
- `riggeometryosgaextension.cpp:211` calls `geom->update()`.
- `riggeometryosgaextension.cpp:219` starts `RigGeometryHolder::forceNextUpdate()`.
- `riggeometryosgaextension.cpp:238` starts `RigGeometryHolder::accept(osg::NodeVisitor& nv)`.
- `riggeometryosgaextension.cpp:245` handles cull visitor updates.

Screenshot:

- `D:\Modlists\fnv\openmw-source\apps\openmw\mwrender\screenshotmanager.cpp`
- `screenshotmanager.cpp:98` calls `mImage->readPixels(...)`.
- `screenshotmanager.cpp:116` starts `ScreenshotManager::screenshot(osg::Image* image, int w, int h)`.
- `D:\Modlists\fnv\openmw-source\components\sceneutil\screencapture.cpp`
- `screencapture.cpp:61` starts `writeScreenshotToFile(...)`.
- `screencapture.cpp:87` gets the writer for the screenshot format.
- `screencapture.cpp:94` calls `readerwriter->writeImage(...)`.
- `screencapture.cpp:112` starts `WriteScreenshotToFileOperation::operator()(...)`.

Meaning:

- Animated skeleton transforms become skinned vertex positions in `RigGeometry`.
- OSG cull/draw uses those updated drawables.
- Screenshot capture reads the rendered framebuffer pixels.
- Proof scripts pick up the PNG and create ledgers/contact sheets.

## 13. Proof Harness Byte/Pixels Back To Evidence

Primary workspace files:

- `D:\code\nikami-worlds\scripts\Invoke-ActorRenderingProof.ps1`
- `D:\code\nikami-worlds\scripts\Invoke-RealWorldScreenshots.ps1`
- `D:\code\nikami-worlds\scripts\New-ScreenshotContactSheet.ps1`
- `D:\code\nikami-worlds\catalog\actor-animation-policy.json`

Key line anchors:

- `Invoke-ActorRenderingProof.ps1:159` creates `screenshots` root.
- `Invoke-ActorRenderingProof.ps1:170` points to `Invoke-RealWorldScreenshots.ps1`.
- `Invoke-ActorRenderingProof.ps1:234` runs `New-ScreenshotContactSheet.ps1`.
- `Invoke-ActorRenderingProof.ps1:239` creates screenshot evidence ledger.
- `Invoke-ActorRenderingProof.ps1:246` runs actor runtime warning measurement.
- `Invoke-ActorRenderingProof.ps1:259` runs actor part telemetry.
- `Invoke-ActorRenderingProof.ps1:265` runs actor render/live telemetry.
- `Invoke-ActorRenderingProof.ps1:271` runs face attachment telemetry.
- `Invoke-ActorRenderingProof.ps1:277` runs basis telemetry.
- `Invoke-ActorRenderingProof.ps1:283` runs root attachment telemetry.
- `Invoke-ActorRenderingProof.ps1:289` runs FABRIK telemetry.
- `Invoke-ActorRenderingProof.ps1:295` runs weapon IK telemetry.
- `Invoke-ActorRenderingProof.ps1:301` runs weapon mesh telemetry.
- `Invoke-ActorRenderingProof.ps1:307` runs limb anatomy telemetry.
- `Invoke-ActorRenderingProof.ps1:313` runs final actor proof status.
- `Invoke-ActorRenderingProof.ps1:347` records screenshot count.

Meaning:

- This is where rendered pixels become auditable proof artifacts.
- The contact sheet is not the source of truth by itself.
- The actor ledgers decide whether the pixels came from coherent moving humans or from broken pose luck.

## 14. Asset Policy Surface

Primary file:

- `D:\code\nikami-worlds\catalog\actor-animation-policy.json`

Fallout 3 policy:

- `OPENMW_WORLD_VIEWER_NPC_ANIMATION_SOURCES=meshes/characters/_male/locomotion/mtidle.kf`
- `OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY=1`
- Required skeleton: `meshes/characters/_male/skeleton.nif`
- Required idle: `meshes/characters/_male/locomotion/mtidle.kf`
- Optional locomotion: `mtforward`, `mtbackward`, `mtturnleft`, `mtturnright`

Fallout: New Vegas policy:

- `OPENMW_WORLD_VIEWER_NPC_ANIMATION_SOURCES=meshes/characters/_male/locomotion/mtidle.kf`
- `OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY=1`
- Required skeleton: `meshes/characters/_male/skeleton.nif`
- Required idle: `meshes/characters/_male/locomotion/mtidle.kf`
- Optional authored idle: `meshes/characters/_male/idleanims/3rdp_cowering.kf`
- Optional locomotion: `mtforward`, `mtbackward`, `mtturnleft`, `mtturnright`

Meaning:

- Policy tells proofs what assets must exist and bind.
- Runtime behavior should be baked in C++ when it is generally true, not carried forever as one-off proof flags.

## 15. Minimal Call Chain

This is the compact call chain to keep in mind:

```text
Objects::insert / RenderingManager player path
  -> new ESM4NpcAnimation(ptr, baseNode, resourceSystem)
  -> ESM4NpcAnimation::ESM4NpcAnimation
  -> setObjectRoot(skeletonModel)
  -> updateParts()
  -> updatePartsFONV()
  -> insertPart / insertAttachedPart
  -> addFonvAnimationSource()
  -> Animation::addSingleAnimSource()
  -> NifOsg::Loader::loadKf()
  -> controller map + text keys
  -> Animation::play(group)
  -> controller callbacks installed
  -> Animation::runAnimation(duration)
  -> sampled KF transforms applied to skeleton nodes
  -> applyFalloutSeatedHumanIk / audits / helper skips
  -> ESM4NpcAnimation::runAnimation(duration)
  -> applyFalloutWeaponGripIk / weapon frame support
  -> Skeleton::markBoneMatriceDirty()
  -> Skeleton::updateBoneMatrices()
  -> RigGeometry::accept/cull/update
  -> OSG draws skinned geometry
  -> ScreenshotManager::screenshot()
  -> readPixels()
  -> SceneUtil::writeScreenshotToFile()
  -> Invoke-ActorRenderingProof ledgers/contact sheet
```

## 16. Where NPCs Can Fail

No NPC:

- `Objects` did not create `ESM4NpcAnimation`.
- Actor was not loaded into the cell.
- Actor was hidden by proof/player visual settings.

Visible but T-pose:

- `addSingleAnimSource` did not bind controllers.
- Text-key group did not match `Animation::play`.
- Active controller set is empty.
- KF file is missing or unreadable.

Visible but twisted:

- Controller target names bound to wrong nodes.
- Synthetic helper nodes were animated as if they were bones.
- Root/NonAccum/root-motion handling is wrong.
- Fallout transform basis or bind basis is wrong.
- RigGeometry skinning matrix order is wrong.
- Bone aliases are wrong or duplicate transform targets are stale.

Visible and moving but limbs wrong:

- Upper-body/hands need IK or correct group/source selection.
- Weapon helper is attached but hand/weapon pose is not a human grip.
- The animation is alive, but the pose semantics fail limb anatomy.

Pixels stale or misleading:

- RigGeometry last-frame/update path did not refresh.
- Culling used stale bounds.
- Screenshot was captured before actor settled.
- Contact sheet is good-looking but math ledgers fail.

## 17. What To Inspect First In A Bad Run

Use the run-local `openmw.log` and ledgers.

Search log for:

```text
World viewer actor ledger: phase=npc-root-begin
World viewer actor ledger: phase=npc-root-end
World viewer actor ledger: phase=animation-source
FNV/ESM4 diag: animation source
FNV/ESM4 diag: play matched
FNV/ESM4 diag: manually applied
FNV/ESM4 diag: skipped synthetic attachment helper controller
FNV/ESM4 diag: standing upper body audit
FNV/ESM4 diag: runtime part audit
FNV/ESM4 proof: actor frame forced rig mesh refresh
FNV/ESM4 telemetry: weapon IK frame
```

Then inspect:

- `actor-runtime-warnings.jsonl`
- `actor-part-telemetry.jsonl`
- `actor-render-live-telemetry.jsonl`
- `actor-basis-telemetry.jsonl`
- `actor-root-attachment-telemetry.jsonl`
- `actor-fabrik-telemetry.jsonl`
- `actor-weapon-ik-telemetry.jsonl`
- `actor-weapon-mesh-telemetry.jsonl`
- `actor-limb-anatomy.jsonl`
- `actor-proof-status.jsonl`
- `contact-sheet.png`

## 18. One-Line Summary

NPCs appear because `Objects` creates `ESM4NpcAnimation`, which loads the FO3/FNV skeleton and parts through the NIF loader; NPCs move because `Animation::addSingleAnimSource`, `Animation::play`, and `Animation::runAnimation` bind and sample KF controller data onto skeleton nodes; pixels update because `Skeleton` bone matrices feed `RigGeometry`, OSG culls/draws the skinned geometry, and the screenshot pipeline reads the framebuffer into proof artifacts.
