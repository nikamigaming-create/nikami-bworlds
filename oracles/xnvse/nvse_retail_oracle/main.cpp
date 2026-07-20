#include "nvse/PluginAPI.h"
#include "nvse/GameForms.h"
#include "nvse/GameExtraData.h"
#include "nvse/GameObjects.h"
#include "nvse/GameSettings.h"
#include "nvse/NiObjects.h"

#include "sidecar_protocol.h"

#include <Windows.h>
#include <d3d9.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <limits>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

namespace
{
    struct ObserverWaypoint
    {
        float x = 0.f;
        float y = 0.f;
    };

    struct SidecarActionPlan
    {
        UInt32 index = 0;
        std::string id;
        std::string playGroup;
        UInt32 frames = 1;
    };

    struct SidecarActorPlan
    {
        UInt32 index = 0;
        UInt32 authoredRefForm = 0;
        UInt32 baseForm = 0;
        UInt32 weaponForm = 0;
        UInt32 enableParentForm = 0;
    };

    struct SidecarPlan
    {
        std::string sequenceId;
        UInt32 anchorForm = 0;
        UInt32 weatherForm = 0;
        float gameHour = 12.f;
        float timeScale = 0.f;
        float targetX = 0.f;
        float targetY = 0.f;
        float targetZ = 0.f;
        float targetYaw = 0.f;
        float playerX = 0.f;
        float playerY = 0.f;
        float playerZ = 0.f;
        float fullBodyDistanceScale = 1.6f;
        float minimumCameraHeight = 48.f;
        float minimumAimHeight = 16.f;
        UInt32 initializationFrames = 30;
        UInt32 targetSettleFrames = 15;
        std::vector<SidecarActionPlan> actions;
        std::vector<SidecarActorPlan> actors;
    };

    enum class SidecarPhase
    {
        Disabled,
        LoadProofVolume,
        WaitProofVolume,
        FreezeTime,
        SelectActor,
        WaitSpawn,
        StageActor,
        WaitActor3D,
        ApplyWeapon,
        VerifyWeapon,
        StartAction,
        SettleAction,
        PublishRetailReady,
        WaitOpenMwReady,
        RequestScreenshot,
        WaitScreenshotFile,
        WaitCaptureAck,
        AdvanceAction,
        CleanupActor,
        Complete,
        Error,
    };

    struct SidecarScreenshotFile
    {
        bool valid = false;
        unsigned long ordinal = 0;
        unsigned long long writeTime = 0;
        unsigned long long size = 0;
        UInt32 width = 0;
        UInt32 height = 0;
        UInt16 bitsPerPixel = 0;
        std::string path;
    };

    PluginHandle gPluginHandle = kPluginHandle_Invalid;
    NVSEMessagingInterface* gMessaging = nullptr;
    NVSEConsoleInterface* gConsole = nullptr;
    std::ofstream gOutput;
    unsigned int gFrame = 0;
    unsigned int gGameLoopFrame = 0;
    unsigned int gWorldLoopFrame = 0;
    unsigned int gSampleEvery = 1;
    unsigned int gMaxFrames = 3600;
    UInt32 gTargetForm = 0;
    UInt32 gEquipForm = 0;
    UInt32 gObserverApproachForm = 0;
    float gObserverApproachStopDistance = 1400.f;
    float gObserverApproachStepDistance = 64.f;
    bool gObserverApproachStarted = false;
    bool gObserverApproachComplete = false;
    bool gObserverApproachWaitingLogged = false;
    std::vector<ObserverWaypoint> gObserverWaypoints;
    std::size_t gObserverWaypointIndex = 0;
    bool gAllHighActors = true;
    bool gCaptureAnimation = true;
    bool gFurnitureOnly = false;
    bool gExitAfterFurnitureRelease = false;
    unsigned int gExitAfterFurnitureSettledSamples = 0;
    bool gFurnitureClaimObserved = false;
    bool gFurnitureLifecycleComplete = false;
    bool gFurnitureSettledCommandsRun = false;
    unsigned int gFurnitureSettledStableSamples = 0;
    unsigned int gFurnitureReleaseSamples = 3;
    unsigned int gFurnitureReleaseStableSamples = 0;
    bool gCloseMenusDuringCapture = false;
    bool gCloseMenusLogged = false;
    bool gLoadRequested = false;
    bool gWorldReady = false;
    bool gPrepareRequested = false;
    bool gEquipRequested = false;
    bool gDriveRequested = false;
    bool gFinishRequested = false;
    bool gExitWhenDone = false;
    std::string gSaveName;
    std::string gPlayGroup;
    std::string gDriveCommand;
    std::vector<UInt32> gQuestForms;
    std::vector<UInt32> gGlobalForms;
    std::vector<std::string> gGameSettingEditorIds;
    bool gGameSettingsCaptured = false;
    std::vector<std::string> gBehaviorCommands;
    std::vector<std::string> gActorCommands;
    std::vector<std::string> gFurnitureSettledCommands;
    std::vector<UInt32> gScreenshotFrames;
    std::size_t gScreenshotFrameIndex = 0;
    std::vector<UInt32> gBatchTargetForms;
    std::size_t gBatchTargetIndex = 0;
    UInt32 gBatchTargetReadyFrame = 0;
    bool gBatchScreenshotRequested = false;
    unsigned int gBatchSettleFrames = 20;
    unsigned int gBatchAdvanceFrames = 3;
    bool gBatchMoveToTargets = false;
    bool gBatchEnableTargets = false;
    bool gBatchTargetLoadRequested = false;
    bool gBatchProofStaging = false;
    UInt32 gBatchProofAnchorForm = 0;
    float gBatchProofTargetX = 0.f;
    float gBatchProofTargetY = 0.f;
    float gBatchProofTargetZ = 0.f;
    float gBatchProofTargetYaw = 0.f;
    float gBatchProofPlayerX = 0.f;
    float gBatchProofPlayerY = 0.f;
    float gBatchProofPlayerZ = 0.f;
    float gBatchProofMinimumCameraHeight = 48.f;
    float gBatchProofMinimumAimHeight = 16.f;
    unsigned int gBatchProofInitializationFrames = 30;
    unsigned int gBatchProofTargetSettleFrames = 15;
    bool gBatchProofLoadRequested = false;
    UInt32 gBatchProofLoadFrame = 0;
    bool gBatchProofVolumeReady = false;
    bool gBatchProofCensusLogged = false;
    UInt32 gBatchProofEvictionCount = 0;
    bool gBatchTargetStaged = false;
    UInt32 gBatchTargetStageFrame = 0;
    bool gBatchTargetStageWaitingLogged = false;
    bool gBatchVisualStageGateLogged = false;
    bool gBatchVisualStageGatePassed = false;
    bool gBatchTargetReleaseRequested = false;
    bool gBatchTargetReleased = false;
    std::vector<UInt32> gBatchEnableParentForms;
    bool gBatchEnableParentsRequested = false;
    bool gPortraitCamera = false;
    bool gPortraitCameraRequested = false;
    bool gPortraitCameraLogged = false;
    bool gPortraitCameraWaitingLogged = false;
    std::string gCameraShotKind = "front-portrait";
    bool gFullBodyCamera = false;
    float gFullBodyDistanceScale = 1.6f;
    bool gFullBodyBoundsWaitingLogged = false;
    bool gBatchForceWeaponOut = false;
    bool gBatchWeaponStateLogged = false;
    bool gBatchWeaponWaitingLogged = false;
    UInt32 gBatchWeaponProbeStartFrame = 0;
    unsigned int gBatchWeaponProbeFrames = 12;
    bool gAppearanceLogged = false;
    bool gRenderEnvironmentLogged = false;
    bool gImageSpaceShaderHookLogged = false;
    std::set<UInt32> gActorGeometryLogged;
    float gPortraitDistance = 110.f;
    unsigned int gBehaviorBeforeFrame = 60;
    unsigned int gBehaviorCommandFrame = 90;
    unsigned int gBehaviorAfterFrame = 150;
    unsigned int gPrepareActorFrame = 60;
    unsigned int gEquipActorFrame = 60;
    unsigned int gDriveActorFrame = 180;
    unsigned int gFootIkToggleFrame = 0;
    bool gFootIkToggleEnabled = false;
    bool gFootIkToggleRequested = false;
    UInt32 gSetStageQuestForm = 0;
    unsigned int gSetStageIndex = 0xffff;
    bool gBehaviorBeforeCaptured = false;
    bool gBehaviorCommandsRun = false;
    bool gBehaviorAfterCaptured = false;
    bool gBoneLodCodeReferencesWritten = false;
    bool gBoneLodWriterCallsHooked = false;
    bool gHighProcessBoneLodPathHooked = false;
    Actor* gDrivenActor = nullptr;

    bool gSidecarPlanActive = false;
    std::string gSidecarPlanPath;
    SidecarPlan gSidecarPlan;
    SidecarPhase gSidecarPhase = SidecarPhase::Disabled;
    std::size_t gSidecarActorIndex = 0;
    std::size_t gSidecarActionIndex = 0;
    UInt32 gSidecarPhaseFrame = 0;
    UInt32 gSidecarActionStartFrame = 0;
    UInt32 gSidecarScreenshotRequestFrame = 0;
    UInt32 gSidecarWeaponVerifyStartFrame = 0;
    UInt32 gSidecarSpawnRequestFrame = 0;
    UInt32 gSidecarResolvedRef = 0;
    bool gSidecarResolvedSpawned = false;
    UInt64 gSidecarGeneration = 0;
    bool gSidecarActionAccepted = false;
    bool gSidecarScreenshotAccepted = false;
    bool gSidecarWeaponPolicyApplied = false;
    bool gSidecarSceneStateRequested = false;
    UInt32 gSidecarSceneStateCommandIndex = 0;
    bool gSidecarTimeFreezeRequested = false;
    UInt32 gSidecarTimeFreezeRequestFrame = 0;
    bool gSidecarRetailReadyPublished = false;
    std::set<UInt32> gSidecarSpawnBaselineRefs;
    SidecarScreenshotFile gSidecarScreenshotBaseline;
    SidecarScreenshotFile gSidecarScreenshotCandidate;
    SidecarScreenshotFile gSidecarScreenshotReady;
    UInt32 gSidecarScreenshotStableFrames = 0;
    unsigned long long gSidecarBarrierTimeoutMs = 30000;
    unsigned long long gSidecarBarrierDeadlineMs = 0;
    std::string gSidecarSharedMemoryName;
    HANDLE gSidecarMapping = nullptr;
    HANDLE gSidecarRetailReadyEvent = nullptr;
    HANDLE gSidecarOpenMwReadyEvent = nullptr;
    HANDLE gSidecarCaptureAckEvent = nullptr;
    HANDLE gSidecarErrorEvent = nullptr;
    NikamiFNVSidecar::SharedBlock* gSidecarShared = nullptr;

    using DrawPrimitiveFn = HRESULT(STDMETHODCALLTYPE*)(IDirect3DDevice9*, D3DPRIMITIVETYPE, UINT, UINT);
    using DrawIndexedPrimitiveFn = HRESULT(STDMETHODCALLTYPE*)(
        IDirect3DDevice9*, D3DPRIMITIVETYPE, INT, UINT, UINT, UINT, UINT);
    using DrawPrimitiveUpFn
        = HRESULT(STDMETHODCALLTYPE*)(IDirect3DDevice9*, D3DPRIMITIVETYPE, UINT, const void*, UINT);
    using DrawIndexedPrimitiveUpFn = HRESULT(STDMETHODCALLTYPE*)(
        IDirect3DDevice9*, D3DPRIMITIVETYPE, UINT, UINT, UINT, const void*, D3DFORMAT, const void*, UINT);
    DrawPrimitiveFn gOriginalDrawPrimitive = nullptr;
    DrawIndexedPrimitiveFn gOriginalDrawIndexedPrimitive = nullptr;
    DrawPrimitiveUpFn gOriginalDrawPrimitiveUp = nullptr;
    DrawIndexedPrimitiveUpFn gOriginalDrawIndexedPrimitiveUp = nullptr;
    bool gImageSpaceShaderHooked = false;

    struct ImageSpaceShaderCapture
    {
        volatile LONG ready = 0;
        UInt32 frame = 0;
        UInt32 byteCount = 0;
        UInt32 hash = 0;
        bool hdrBlend = false;
        bool alphaMask = false;
        HRESULT constantsResult = E_FAIL;
        float constants[24][4] = {};
    } gImageSpaceShaderCapture;

    constexpr const char* sSchema = "nikami-retail-oracle/v4";
    constexpr const char* sSchemaJson = "\"nikami-retail-oracle/v4\"";
    constexpr std::size_t sNiAVObjectWorldBoundOffset = 0x20;
    constexpr std::size_t sNiAVObjectLocalTransformOffset = 0x34;
    constexpr std::size_t sNiAVObjectWorldTransformOffset = 0x68;

    bool runReferenceFloatCommand(TESObjectREFR* reference, const char* commandName, float value);

    static_assert(sizeof(NiTransform) == 0x34);

    bool containsAscii(const UInt8* bytes, std::size_t byteCount, const char* needle)
    {
        const std::size_t needleLength = std::strlen(needle);
        if (bytes == nullptr || needleLength == 0 || byteCount < needleLength)
            return false;
        for (std::size_t i = 0; i + needleLength <= byteCount; ++i)
        {
            if (std::memcmp(bytes + i, needle, needleLength) == 0)
                return true;
        }
        return false;
    }

    UInt32 fnv1a32(const UInt8* bytes, std::size_t byteCount)
    {
        UInt32 hash = 2166136261u;
        for (std::size_t i = 0; i < byteCount; ++i)
        {
            hash ^= bytes[i];
            hash *= 16777619u;
        }
        return hash;
    }

    void captureImageSpaceShaderConstants(IDirect3DDevice9* device)
    {
        if (gWorldReady && gFrame > 0 && gImageSpaceShaderCapture.ready == 0 && device != nullptr)
        {
            IDirect3DPixelShader9* shader = nullptr;
            if (SUCCEEDED(device->GetPixelShader(&shader)) && shader != nullptr)
            {
                UINT byteCount = 0;
                if (SUCCEEDED(shader->GetFunction(nullptr, &byteCount)) && byteCount > 0 && byteCount <= 4096)
                {
                    UInt8 bytes[4096] = {};
                    UINT actualByteCount = byteCount;
                    if (SUCCEEDED(shader->GetFunction(bytes, &actualByteCount)))
                    {
                        const bool cinematic = containsAscii(bytes, actualByteCount, "Cinematic")
                            && containsAscii(bytes, actualByteCount, "Tint")
                            && containsAscii(bytes, actualByteCount, "Fade");
                        const bool hdrBlend = containsAscii(bytes, actualByteCount, "HDRParam")
                            && containsAscii(bytes, actualByteCount, "DestBlend");
                        if (cinematic
                            && InterlockedCompareExchange(&gImageSpaceShaderCapture.ready, -1, 0) == 0)
                        {
                            gImageSpaceShaderCapture.frame = gFrame;
                            gImageSpaceShaderCapture.byteCount = actualByteCount;
                            gImageSpaceShaderCapture.hash = fnv1a32(bytes, actualByteCount);
                            gImageSpaceShaderCapture.hdrBlend = hdrBlend;
                            gImageSpaceShaderCapture.alphaMask = containsAscii(bytes, actualByteCount, "UseAlphaMask");
                            gImageSpaceShaderCapture.constantsResult = device->GetPixelShaderConstantF(
                                0, &gImageSpaceShaderCapture.constants[0][0], 24);
                            MemoryBarrier();
                            InterlockedExchange(&gImageSpaceShaderCapture.ready, 1);
                        }
                    }
                }
                shader->Release();
            }
        }
    }

    HRESULT STDMETHODCALLTYPE imageSpaceDrawPrimitiveHook(
        IDirect3DDevice9* device, D3DPRIMITIVETYPE primitiveType, UINT startVertex, UINT primitiveCount)
    {
        captureImageSpaceShaderConstants(device);
        return gOriginalDrawPrimitive(device, primitiveType, startVertex, primitiveCount);
    }

    HRESULT STDMETHODCALLTYPE imageSpaceDrawIndexedPrimitiveHook(IDirect3DDevice9* device,
        D3DPRIMITIVETYPE primitiveType, INT baseVertexIndex, UINT minimumVertexIndex, UINT vertexCount,
        UINT startIndex, UINT primitiveCount)
    {
        captureImageSpaceShaderConstants(device);
        return gOriginalDrawIndexedPrimitive(device, primitiveType, baseVertexIndex, minimumVertexIndex,
            vertexCount, startIndex, primitiveCount);
    }

    HRESULT STDMETHODCALLTYPE imageSpaceDrawPrimitiveUpHook(IDirect3DDevice9* device,
        D3DPRIMITIVETYPE primitiveType, UINT primitiveCount, const void* vertexData, UINT vertexStride)
    {
        captureImageSpaceShaderConstants(device);
        return gOriginalDrawPrimitiveUp(device, primitiveType, primitiveCount, vertexData, vertexStride);
    }

    HRESULT STDMETHODCALLTYPE imageSpaceDrawIndexedPrimitiveUpHook(IDirect3DDevice9* device,
        D3DPRIMITIVETYPE primitiveType, UINT minimumVertexIndex, UINT vertexCount, UINT primitiveCount,
        const void* indexData, D3DFORMAT indexFormat, const void* vertexData, UINT vertexStride)
    {
        captureImageSpaceShaderConstants(device);
        return gOriginalDrawIndexedPrimitiveUp(device, primitiveType, minimumVertexIndex, vertexCount,
            primitiveCount, indexData, indexFormat, vertexData, vertexStride);
    }

    bool hookD3DDeviceMethod(void** vtable, std::size_t index, void* hook, void** original)
    {
        if (vtable[index] == hook)
            return *original != nullptr;
        DWORD oldProtect = 0;
        if (VirtualProtect(&vtable[index], sizeof(void*), PAGE_EXECUTE_READWRITE, &oldProtect) == FALSE)
            return false;
        *original = vtable[index];
        vtable[index] = hook;
        FlushInstructionCache(GetCurrentProcess(), &vtable[index], sizeof(void*));
        DWORD restoredProtect = 0;
        VirtualProtect(&vtable[index], sizeof(void*), oldProtect, &restoredProtect);
        return true;
    }

    bool hookImageSpaceDrawPrimitive()
    {
        if (gImageSpaceShaderHooked)
            return true;
        UInt8* renderer = *reinterpret_cast<UInt8**>(0x011F4748);
        if (renderer == nullptr)
            return false;
        IDirect3DDevice9* device = *reinterpret_cast<IDirect3DDevice9**>(renderer + 0x288);
        if (device == nullptr)
            return false;
        void** vtable = *reinterpret_cast<void***>(device);
        if (vtable == nullptr)
            return false;
        const bool drawPrimitive = hookD3DDeviceMethod(vtable, 81,
            reinterpret_cast<void*>(imageSpaceDrawPrimitiveHook),
            reinterpret_cast<void**>(&gOriginalDrawPrimitive));
        const bool drawIndexedPrimitive = hookD3DDeviceMethod(vtable, 82,
            reinterpret_cast<void*>(imageSpaceDrawIndexedPrimitiveHook),
            reinterpret_cast<void**>(&gOriginalDrawIndexedPrimitive));
        const bool drawPrimitiveUp = hookD3DDeviceMethod(vtable, 83,
            reinterpret_cast<void*>(imageSpaceDrawPrimitiveUpHook),
            reinterpret_cast<void**>(&gOriginalDrawPrimitiveUp));
        const bool drawIndexedPrimitiveUp = hookD3DDeviceMethod(vtable, 84,
            reinterpret_cast<void*>(imageSpaceDrawIndexedPrimitiveUpHook),
            reinterpret_cast<void**>(&gOriginalDrawIndexedPrimitiveUp));
        gImageSpaceShaderHooked
            = drawPrimitive && drawIndexedPrimitive && drawPrimitiveUp && drawIndexedPrimitiveUp;
        return gImageSpaceShaderHooked;
    }

    void writeImageSpaceShaderCapture()
    {
        if (InterlockedCompareExchange(&gImageSpaceShaderCapture.ready, 0, 0) != 1 || !gOutput.is_open())
            return;
        MemoryBarrier();
        gOutput << std::setprecision(9)
                << "{\"schema\":" << sSchemaJson << ",\"event\":\"image-space-shader-constants\""
                << ",\"frame\":" << gImageSpaceShaderCapture.frame
                << ",\"byteCount\":" << gImageSpaceShaderCapture.byteCount
                << ",\"fnv1a32\":" << gImageSpaceShaderCapture.hash
                << ",\"path\":\"" << (gImageSpaceShaderCapture.hdrBlend
                        ? (gImageSpaceShaderCapture.alphaMask ? "hdr-cinematic-alpha-mask" : "hdr-cinematic")
                        : "cinematic") << '"'
                << ",\"getConstantsResult\":" << static_cast<long>(gImageSpaceShaderCapture.constantsResult)
                << ",\"registers\":[";
        for (unsigned int reg = 0; reg < 24; ++reg)
        {
            if (reg != 0)
                gOutput << ',';
            gOutput << '[';
            for (unsigned int component = 0; component < 4; ++component)
            {
                if (component != 0)
                    gOutput << ',';
                const float value = gImageSpaceShaderCapture.constants[reg][component];
                if (std::isfinite(value))
                    gOutput << value;
                else
                    gOutput << "null";
            }
            gOutput << ']';
        }
        gOutput << "]}\n";
        gOutput.flush();
        InterlockedExchange(&gImageSpaceShaderCapture.ready, 2);
    }

    void __cdecl recordBoneLodWriterCall(HighProcess* process, Actor* actor)
    {
        if (!gCaptureAnimation || !gOutput.is_open() || process == nullptr || actor == nullptr
            || (gTargetForm != 0 && actor->refID != gTargetForm
                && (actor->baseForm == nullptr || actor->baseForm->refID != gTargetForm)))
            return;

        SInt32 controllerLod = -2;
        if (process->ptr2E4 != nullptr)
            std::memcpy(&controllerLod, reinterpret_cast<const UInt8*>(process->ptr2E4) + 0x34, sizeof(controllerLod));
        gOutput << "{\"schema\":" << sSchemaJson << ",\"event\":\"bone-lod-writer-call\""
                << ",\"frame\":" << gFrame
                << ",\"worldLoopFrame\":" << gWorldLoopFrame
                << ",\"refForm\":" << actor->refID
                << ",\"actorLifeState\":" << actor->lifeState
                << ",\"processCachedLod\":" << static_cast<SInt32>(process->unk2E8)
                << ",\"controllerLod\":" << controllerLod << "}\n";
        gOutput.flush();
    }

    void __cdecl recordHighProcessBoneLodPath(HighProcess* process, Actor* actor)
    {
        if (!gCaptureAnimation || !gOutput.is_open() || process == nullptr || actor == nullptr
            || (gTargetForm != 0 && actor->refID != gTargetForm
                && (actor->baseForm == nullptr || actor->baseForm->refID != gTargetForm)))
            return;
        bool refGate = false;
        bool refFlagA = false;
        bool refFlagB = false;
        void* actorState = nullptr;
        bool actorStateReady = false;
        bool actorTypeGate = false;
        void* processState = nullptr;
        bool processStateGate = false;
        __try
        {
            refGate = reinterpret_cast<bool(__thiscall*)(Actor*)>(0x00574900)(actor);
            refFlagA = reinterpret_cast<bool(__thiscall*)(Actor*)>(0x00440D80)(actor);
            refFlagB = reinterpret_cast<bool(__thiscall*)(Actor*)>(0x00440DA0)(actor);
            actorState = reinterpret_cast<void*(__thiscall*)(Actor*)>(0x008D6F30)(actor);
            if (actorState != nullptr)
                actorStateReady = reinterpret_cast<bool(__thiscall*)(void*)>(0x00450FF0)(actorState);
            void** actorVtable = *reinterpret_cast<void***>(actor);
            actorTypeGate = reinterpret_cast<bool(__thiscall*)(Actor*)>(actorVtable[0x100 / 4])(actor);
            void** processVtable = *reinterpret_cast<void***>(process);
            processState = reinterpret_cast<void*(__thiscall*)(HighProcess*)>(processVtable[0x1B8 / 4])(process);
            if (processState != nullptr)
                processStateGate = reinterpret_cast<bool(__thiscall*)(void*)>(0x00493830)(processState);
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
        }
        gOutput << "{\"schema\":" << sSchemaJson << ",\"event\":\"high-process-bone-lod-path\""
                << ",\"frame\":" << gFrame
                << ",\"worldLoopFrame\":" << gWorldLoopFrame
                << ",\"refForm\":" << actor->refID
                << ",\"actorLifeState\":" << actor->lifeState
                << ",\"fadeType\":" << process->fadeType
                << ",\"guards\":{\"refGate\":" << (refGate ? "true" : "false")
                << ",\"refFlagA\":" << (refFlagA ? "true" : "false")
                << ",\"refFlagB\":" << (refFlagB ? "true" : "false")
                << ",\"actorState\":"
                << static_cast<unsigned long>(reinterpret_cast<std::uintptr_t>(actorState))
                << ",\"actorStateReady\":" << (actorStateReady ? "true" : "false")
                << ",\"actorTypeGate\":" << (actorTypeGate ? "true" : "false")
                << ",\"processState\":"
                << static_cast<unsigned long>(reinterpret_cast<std::uintptr_t>(processState))
                << ",\"processStateGate\":" << (processStateGate ? "true" : "false") << "}}\n";
        gOutput.flush();
    }

    __declspec(naked) void boneLodWriterHook()
    {
        __asm
        {
            push ebp
            mov ebp, esp
            push ecx
            mov eax, dword ptr [ebp + 8]
            push eax
            mov ecx, dword ptr [ebp - 4]
            mov eax, 0x008E5730
            call eax
            // The replaced thiscall returns a value in EAX. Preserve it across
            // the diagnostic callback so the patched call sites observe the
            // exact same ABI as the retail function.
            push eax
            mov eax, dword ptr [ebp + 8]
            push eax
            mov eax, dword ptr [ebp - 4]
            push eax
            call recordBoneLodWriterCall
            add esp, 8
            pop eax
            mov esp, ebp
            pop ebp
            ret 4
        }
    }

    __declspec(naked) void highProcessBoneLodPathHook()
    {
        __asm
        {
            push ebp
            mov ebp, esp
            push ecx
            mov eax, dword ptr [ebp + 8]
            push eax
            mov eax, dword ptr [ebp - 4]
            push eax
            call recordHighProcessBoneLodPath
            add esp, 8
            mov eax, dword ptr [ebp + 8]
            push eax
            mov ecx, dword ptr [ebp - 4]
            mov eax, 0x008EEEC0
            call eax
            mov esp, ebp
            pop ebp
            ret 4
        }
    }

    bool hookRetailCall(std::uintptr_t callAddress, std::uintptr_t expectedTarget, const void* hook)
    {
        UInt8 opcode = 0;
        SInt32 displacement = 0;
        std::memcpy(&opcode, reinterpret_cast<const void*>(callAddress), sizeof(opcode));
        std::memcpy(&displacement, reinterpret_cast<const void*>(callAddress + 1), sizeof(displacement));
        if (opcode != 0xE8 || callAddress + 5 + displacement != expectedTarget)
            return false;

        DWORD oldProtect = 0;
        if (VirtualProtect(reinterpret_cast<void*>(callAddress), 5, PAGE_EXECUTE_READWRITE, &oldProtect) == FALSE)
            return false;
        const SInt32 hookDisplacement = static_cast<SInt32>(reinterpret_cast<std::uintptr_t>(hook) - callAddress - 5);
        std::memcpy(reinterpret_cast<void*>(callAddress + 1), &hookDisplacement, sizeof(hookDisplacement));
        FlushInstructionCache(GetCurrentProcess(), reinterpret_cast<const void*>(callAddress), 5);
        DWORD restoredProtect = 0;
        VirtualProtect(reinterpret_cast<void*>(callAddress), 5, oldProtect, &restoredProtect);
        return true;
    }

    bool hookBoneLodWriterCalls()
    {
        const bool primary = hookRetailCall(0x008EF21D, 0x008E5730, boneLodWriterHook);
        const bool refresh = hookRetailCall(0x008FE3F2, 0x008E5730, boneLodWriterHook);
        return primary && refresh;
    }

    bool hookHighProcessBoneLodPath()
    {
        constexpr std::uintptr_t vtableEntry = 0x01087864 + 4 * sizeof(std::uintptr_t);
        constexpr std::uintptr_t expectedTarget = 0x008EEEC0;
        std::uintptr_t currentTarget = 0;
        std::memcpy(&currentTarget, reinterpret_cast<const void*>(vtableEntry), sizeof(currentTarget));
        if (currentTarget != expectedTarget)
            return false;
        DWORD oldProtect = 0;
        if (VirtualProtect(reinterpret_cast<void*>(vtableEntry), sizeof(currentTarget), PAGE_READWRITE, &oldProtect)
            == FALSE)
            return false;
        const std::uintptr_t hook = reinterpret_cast<std::uintptr_t>(highProcessBoneLodPathHook);
        std::memcpy(reinterpret_cast<void*>(vtableEntry), &hook, sizeof(hook));
        DWORD restoredProtect = 0;
        VirtualProtect(reinterpret_cast<void*>(vtableEntry), sizeof(currentTarget), oldProtect, &restoredProtect);
        return true;
    }

    // xNVSE's public NiControllerSequence declaration predates the fully reversed
    // Gamebryo runtime layout.  Keep the retail-oracle-only views here so the
    // telemetry can describe the blend graph without changing xNVSE itself.
    struct OracleQuatTransform
    {
        // FalloutNV.exe stores the interpolator's cached transform channels in
        // translation/rotation/scale order.  Treating this as the later
        // rotation/translation declaration produces impossible "quaternions"
        // containing bone offsets such as (5.88, 11.74, ...).
        NiVector3 translation;
        NiQuaternion rotation;
        float scale;
    };

    struct OracleTransformInterpolator
    {
        void** vtable;
        UInt32 refCount;
        float lastUpdateTime;
        OracleQuatTransform value;
    };

    struct OracleBlendItem
    {
        NiObject* interpolator;
        float weight;
        float normalizedWeight;
        UInt8 priority;
        UInt8 pad0D[3];
        float easeSpinner;
        float updateTime;
    };

    struct OracleBlendInterpolator
    {
        void** vtable;
        UInt32 refCount;
        float lastUpdateTime;
        UInt8 flags;
        UInt8 arraySize;
        UInt8 interpolatorCount;
        UInt8 singleIndex;
        UInt8 highPriority;
        UInt8 nextHighPriority;
        UInt8 pad12[2];
        OracleBlendItem* items;
        NiObject* singleInterpolator;
        float weightThreshold;
        float singleTime;
        float highWeightSum;
        float nextHighWeightSum;
        float highEaseSpinner;
    };

    struct OracleControlledBlock
    {
        NiObject* interpolator;
        NiObject* multiTargetController;
        OracleBlendInterpolator* blendInterpolator;
        UInt8 blendIndex;
        UInt8 priority;
        UInt8 pad0E[2];
    };

    struct OracleControlledBlockId
    {
        const char* objectName;
        const char* propertyType;
        const char* controllerType;
        const char* controllerId;
        const char* interpolatorId;
    };

    struct OracleMultiTargetTransformController
    {
        UInt8 controller[0x34];
        OracleBlendInterpolator* blendInterpolator;
        NiAVObject** targets;
        UInt16 targetCount;
        UInt8 pad3E[2];
    };

    struct OracleTimeController
    {
        void** vtable;
        UInt32 refCount;
        UInt16 flags;
        UInt16 unknown0A;
        float frequency;
        float phaseTime;
        float lowKeyTime;
        float highKeyTime;
        float startTime;
        float lastTime;
        float weightedLastTime;
        float scaledTime;
        NiObject* target;
        OracleTimeController* next;
    };

    struct OracleSetting
    {
        void** vtable;
        UInt32 rawValue;
        const char* name;
    };

    struct OracleVector3
    {
        float x;
        float y;
        float z;
    };

    // Retail NiAVObject::m_kWorldBound is a NiBound pointer at runtime offset
    // 0x20. Read both the pointer and pointee defensively; treating the pointer
    // bytes as an inline sphere produces a zero radius on every scene object.
    struct OracleBound
    {
        OracleVector3 center;
        float radius;
    };

    struct OracleAssembledBound
    {
        OracleVector3 minimum;
        OracleVector3 maximum;
        UInt32 visitedObjects;
        UInt32 readableBoundPointers;
        UInt32 readableBounds;
        UInt32 nullBoundPointers;
        UInt32 boundPointerReadFailures;
        UInt32 boundDataReadFailures;
        UInt32 acceptedBounds;
        UInt32 rejectedNonFinite;
        UInt32 rejectedRadius;
        UInt32 rejectedDistance;
        UInt32 readableChildArrays;
        UInt32 childArrayReadFailures;
        UInt32 childPointerReadFailures;
        bool initialized;
        bool traversalLimitHit;
    };

    // Runtime 1.4.0.525 point-to-point query packet consumed by TES::RayCast
    // at 0x00458440. This is a clean-room, zero-initialized adaptation of the
    // engine ABI; do not call JIP-LN's naked internal helper from another frame.
    struct alignas(16) OracleRayCastData
    {
        float position0[4];        // 00, Havok units
        float position1[4];        // 10, Havok units
        UInt8 byte20;              // 20
        UInt8 pad21[3];
        UInt32 collisionFilter;    // 24: layer, flags, group
        UInt32 unknown28[6];       // 28
        float hitFraction;         // 40
        UInt32 unknown44[15];      // 44
        void* collisionBody;       // 80
        UInt32 unknown84[3];       // 84
        float vector90[4];         // 90
        UInt32 unknownA0[3];       // A0
        UInt8 byteAC;              // AC
        UInt8 padAD[3];
    };

    struct OracleRayCastResult
    {
        bool filterAvailable;
        bool tesAvailable;
        bool invoked;
        bool faulted;
        bool fractionValid;
        bool hit;
        bool passed;
        UInt32 collisionFilter;
        float hitFraction;
        NiAVObject* hitObject;
    };

    // MiddleHighProcess::FurnitureMark at 0x148 in the retail 1.4.0.525 runtime.
    // Keep this private to the oracle: the public xNVSE headers deliberately leave
    // the surrounding process members unnamed, while JIP-LN documents this layout.
    struct OracleFurnitureMark
    {
        OracleVector3 position;
        UInt16 rotation;
        UInt8 type;
        UInt8 unknown0F;
    };

    static_assert(sizeof(OracleQuatTransform) == 0x20);
    static_assert(sizeof(OracleTransformInterpolator) == 0x2c);
    static_assert(sizeof(OracleBlendItem) == 0x18);
    static_assert(sizeof(OracleBlendInterpolator) == 0x30);
    static_assert(sizeof(OracleControlledBlock) == 0x10);
    static_assert(sizeof(OracleMultiTargetTransformController) == 0x40);
    static_assert(sizeof(OracleTimeController) == 0x34);
    static_assert(sizeof(OracleSetting) == 0x0c);
    static_assert(sizeof(OracleVector3) == 0x0c);
    static_assert(sizeof(OracleBound) == 0x10);
    static_assert(alignof(OracleRayCastData) == 0x10);
    static_assert(sizeof(OracleRayCastData) == 0xB0);
    static_assert(offsetof(OracleRayCastData, collisionFilter) == 0x24);
    static_assert(offsetof(OracleRayCastData, hitFraction) == 0x40);
    static_assert(offsetof(OracleRayCastData, collisionBody) == 0x80);
    static_assert(offsetof(OracleRayCastData, vector90) == 0x90);
    static_assert(sizeof(OracleFurnitureMark) == 0x10);
    template <class T>
    bool safeRead(const void* address, T& value)
    {
        if (address == nullptr)
            return false;
        SIZE_T bytesRead = 0;
        return ReadProcessMemory(GetCurrentProcess(), address, &value, sizeof(T), &bytesRead) != FALSE
            && bytesRead == sizeof(T);
    }

    bool readPlayerRayCastFilter(PlayerCharacter* player, UInt32& filter)
    {
        filter = 0;
        if (player == nullptr)
            return false;
        UInt8* process = nullptr;
        UInt8* controller = nullptr;
        UInt8* wrapper = nullptr;
        UInt8* phantom = nullptr;
        return safeRead(reinterpret_cast<const UInt8*>(player) + 0x68, process)
            && process != nullptr
            && safeRead(process + 0x138, controller) && controller != nullptr
            && safeRead(controller + 0x594, wrapper) && wrapper != nullptr
            && safeRead(wrapper + 0x08, phantom) && phantom != nullptr
            && safeRead(phantom + 0x2C, filter);
    }

    NiAVObject* invokeEngineRayCast(
        void* tes, OracleRayCastData* data, bool& invoked, bool& faulted)
    {
        invoked = false;
        faulted = false;
        __try
        {
            using RayCastFunction = NiAVObject* (__thiscall*)(void*, OracleRayCastData*, UInt32);
            invoked = true;
            return reinterpret_cast<RayCastFunction>(0x00458440)(tes, data, 1);
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            faulted = true;
            return nullptr;
        }
    }

    OracleRayCastResult castProofCorridor(PlayerCharacter* player,
        float startX, float startY, float startZ, float endX, float endY, float endZ)
    {
        OracleRayCastResult result = {};
        UInt32 playerFilter = 0;
        result.filterAvailable = readPlayerRayCastFilter(player, playerFilter);
        void* tes = nullptr;
        result.tesAvailable = safeRead(reinterpret_cast<void*>(0x011DEA10), tes) && tes != nullptr;
        if (!result.filterAvailable || !result.tesAvailable)
            return result;

        constexpr float gameToHavok = 0.1428749859f; // exact engine constant 0x3E124DD2
        OracleRayCastData data = {};
        data.position0[0] = startX * gameToHavok;
        data.position0[1] = startY * gameToHavok;
        data.position0[2] = startZ * gameToHavok;
        data.position1[0] = endX * gameToHavok;
        data.position1[1] = endY * gameToHavok;
        data.position1[2] = endZ * gameToHavok;
        data.byte20 = 0;
        // Preserve only the player's collision group; query projectile layer 6.
        result.collisionFilter = (playerFilter & 0xFFFF0000u) | 6u;
        data.collisionFilter = result.collisionFilter;
        data.hitFraction = 1.f;
        data.unknown44[0] = 0xFFFFFFFFu;
        data.unknown44[3] = 0xFFFFFFFFu;
        result.hitObject = invokeEngineRayCast(
            tes, &data, result.invoked, result.faulted);
        result.hitFraction = data.hitFraction;
        result.fractionValid = std::isfinite(data.hitFraction)
            && data.hitFraction >= 0.f && data.hitFraction <= 1.f;
        result.hit = result.fractionValid && data.hitFraction < 0.99999f;
        result.passed = result.invoked && !result.faulted && result.fractionValid && !result.hit;
        return result;
    }

    enum class OracleBoundValidation
    {
        Accepted,
        NonFinite,
        Radius,
        Distance,
    };

    bool readObjectWorldBound(
        const NiAVObject* object, OracleBound*& address, bool& pointerReadable, OracleBound& bound)
    {
        address = nullptr;
        pointerReadable = object != nullptr
            && safeRead(reinterpret_cast<const UInt8*>(object) + sNiAVObjectWorldBoundOffset, address);
        return pointerReadable && address != nullptr && safeRead(address, bound);
    }

    OracleBoundValidation validateActorWorldBound(const OracleBound& bound, const Actor* actor)
    {
        if (actor == nullptr || !std::isfinite(bound.center.x) || !std::isfinite(bound.center.y)
            || !std::isfinite(bound.center.z) || !std::isfinite(bound.radius))
            return OracleBoundValidation::NonFinite;
        if (bound.radius < 0.01f || bound.radius > 2048.f)
            return OracleBoundValidation::Radius;
        const double dx = static_cast<double>(bound.center.x) - actor->posX;
        const double dy = static_cast<double>(bound.center.y) - actor->posY;
        const double dz = static_cast<double>(bound.center.z) - actor->posZ;
        const double maximumOffset = 4096.0 + bound.radius;
        if (dx * dx + dy * dy + dz * dz > maximumOffset * maximumOffset)
            return OracleBoundValidation::Distance;
        return OracleBoundValidation::Accepted;
    }

    void expandAssembledBound(OracleAssembledBound& assembled, const OracleBound& bound)
    {
        const OracleVector3 minimum = {
            bound.center.x - bound.radius,
            bound.center.y - bound.radius,
            bound.center.z - bound.radius,
        };
        const OracleVector3 maximum = {
            bound.center.x + bound.radius,
            bound.center.y + bound.radius,
            bound.center.z + bound.radius,
        };
        if (!assembled.initialized)
        {
            assembled.minimum = minimum;
            assembled.maximum = maximum;
            assembled.initialized = true;
            return;
        }
        assembled.minimum.x = (std::min)(assembled.minimum.x, minimum.x);
        assembled.minimum.y = (std::min)(assembled.minimum.y, minimum.y);
        assembled.minimum.z = (std::min)(assembled.minimum.z, minimum.z);
        assembled.maximum.x = (std::max)(assembled.maximum.x, maximum.x);
        assembled.maximum.y = (std::max)(assembled.maximum.y, maximum.y);
        assembled.maximum.z = (std::max)(assembled.maximum.z, maximum.z);
    }

    void collectActorWorldBounds(
        Actor* actor, NiAVObject* object, unsigned int depth, OracleAssembledBound& assembled)
    {
        constexpr UInt32 maximumObjects = 8192;
        constexpr unsigned int maximumDepth = 64;
        constexpr unsigned int maximumChildrenPerNode = 2048;
        if (actor == nullptr || object == nullptr)
            return;
        if (depth > maximumDepth || assembled.visitedObjects >= maximumObjects)
        {
            assembled.traversalLimitHit = true;
            return;
        }
        ++assembled.visitedObjects;

        OracleBound* candidateAddress = nullptr;
        bool candidatePointerReadable = false;
        OracleBound candidate = {};
        const bool candidateReadable = readObjectWorldBound(
            object, candidateAddress, candidatePointerReadable, candidate);
        if (!candidatePointerReadable)
            ++assembled.boundPointerReadFailures;
        else if (candidateAddress == nullptr)
            ++assembled.nullBoundPointers;
        else
            ++assembled.readableBoundPointers;
        if (!candidateReadable && candidateAddress != nullptr)
            ++assembled.boundDataReadFailures;
        if (candidateReadable)
        {
            ++assembled.readableBounds;
            switch (validateActorWorldBound(candidate, actor))
            {
                case OracleBoundValidation::Accepted:
                    ++assembled.acceptedBounds;
                    expandAssembledBound(assembled, candidate);
                    break;
                case OracleBoundValidation::NonFinite: ++assembled.rejectedNonFinite; break;
                case OracleBoundValidation::Radius: ++assembled.rejectedRadius; break;
                case OracleBoundValidation::Distance: ++assembled.rejectedDistance; break;
            }
        }

        NiNode* node = object->GetAsNiNode();
        if (node == nullptr)
            return;
        NiTArray<NiAVObject*> children = {};
        if (!safeRead(&node->m_children, children))
        {
            ++assembled.childArrayReadFailures;
            return;
        }
        ++assembled.readableChildArrays;
        const unsigned int count = (std::min)(
            (std::min)(static_cast<unsigned int>(children.firstFreeEntry),
                static_cast<unsigned int>(children.capacity)),
            maximumChildrenPerNode);
        if (count > 0 && children.data == nullptr)
        {
            ++assembled.childArrayReadFailures;
            return;
        }
        for (unsigned int index = 0; index < count; ++index)
        {
            NiAVObject* child = nullptr;
            if (!safeRead(children.data + index, child))
            {
                ++assembled.childPointerReadFailures;
                continue;
            }
            if (child != nullptr)
                collectActorWorldBounds(actor, child, depth + 1, assembled);
        }
    }

    bool finalizeAssembledBound(const OracleAssembledBound& assembled, OracleBound& bound)
    {
        if (!assembled.initialized || assembled.acceptedBounds == 0 || assembled.traversalLimitHit
            || assembled.boundPointerReadFailures != 0 || assembled.boundDataReadFailures != 0
            || assembled.childArrayReadFailures != 0 || assembled.childPointerReadFailures != 0)
            return false;
        bound.center.x = (assembled.minimum.x + assembled.maximum.x) * 0.5f;
        bound.center.y = (assembled.minimum.y + assembled.maximum.y) * 0.5f;
        bound.center.z = (assembled.minimum.z + assembled.maximum.z) * 0.5f;
        const float halfX = (assembled.maximum.x - assembled.minimum.x) * 0.5f;
        const float halfY = (assembled.maximum.y - assembled.minimum.y) * 0.5f;
        const float halfZ = (assembled.maximum.z - assembled.minimum.z) * 0.5f;
        bound.radius = std::sqrt(halfX * halfX + halfY * halfY + halfZ * halfZ);
        return std::isfinite(bound.center.x) && std::isfinite(bound.center.y)
            && std::isfinite(bound.center.z) && std::isfinite(bound.radius)
            && bound.radius >= 8.f && bound.radius <= 4096.f && halfZ >= 16.f;
    }

    void writeFiniteFloat(std::ostream& out, float value)
    {
        if (std::isfinite(value))
            out << value;
        else
            out << "null";
    }

    void writeBoundVector(std::ostream& out, const OracleVector3& value)
    {
        out << '[';
        writeFiniteFloat(out, value.x);
        out << ',';
        writeFiniteFloat(out, value.y);
        out << ',';
        writeFiniteFloat(out, value.z);
        out << ']';
    }

    void writeRawBoundDiagnostics(
        std::ostream& out, bool pointerReadable, const OracleBound* address, bool readable,
        OracleBoundValidation validation, const OracleBound& bound)
    {
        out << "{\"pointerReadable\":" << (pointerReadable ? "true" : "false")
            << ",\"address\":";
        if (address != nullptr)
            out << static_cast<unsigned long>(reinterpret_cast<std::uintptr_t>(address));
        else
            out << "null";
        out << ",\"readable\":" << (readable ? "true" : "false")
            << ",\"validation\":";
        switch (validation)
        {
            case OracleBoundValidation::Accepted: out << "\"accepted\""; break;
            case OracleBoundValidation::NonFinite: out << "\"nonfinite\""; break;
            case OracleBoundValidation::Radius: out << "\"radius\""; break;
            case OracleBoundValidation::Distance: out << "\"distance\""; break;
        }
        out << ",\"center\":";
        writeBoundVector(out, bound.center);
        out << ",\"radius\":";
        writeFiniteFloat(out, bound.radius);
        out << '}';
    }

    void writeAssembledBoundDiagnostics(
        std::ostream& out, bool valid, const OracleAssembledBound& assembled, const OracleBound& bound)
    {
        out << "{\"valid\":" << (valid ? "true" : "false")
            << ",\"visitedObjects\":" << assembled.visitedObjects
            << ",\"readableBoundPointers\":" << assembled.readableBoundPointers
            << ",\"readableBounds\":" << assembled.readableBounds
            << ",\"nullBoundPointers\":" << assembled.nullBoundPointers
            << ",\"boundPointerReadFailures\":" << assembled.boundPointerReadFailures
            << ",\"boundDataReadFailures\":" << assembled.boundDataReadFailures
            << ",\"acceptedBounds\":" << assembled.acceptedBounds
            << ",\"rejectedNonFinite\":" << assembled.rejectedNonFinite
            << ",\"rejectedRadius\":" << assembled.rejectedRadius
            << ",\"rejectedDistance\":" << assembled.rejectedDistance
            << ",\"readableChildArrays\":" << assembled.readableChildArrays
            << ",\"childArrayReadFailures\":" << assembled.childArrayReadFailures
            << ",\"childPointerReadFailures\":" << assembled.childPointerReadFailures
            << ",\"traversalLimitHit\":" << (assembled.traversalLimitHit ? "true" : "false")
            << ",\"minimum\":";
        writeBoundVector(out, assembled.minimum);
        out << ",\"maximum\":";
        writeBoundVector(out, assembled.maximum);
        out << ",\"center\":";
        writeBoundVector(out, bound.center);
        out << ",\"radius\":";
        writeFiniteFloat(out, bound.radius);
        out << '}';
    }

    std::string safeRuntimeString(const char* address, std::size_t maximumLength = 512)
    {
        std::string value;
        value.reserve(std::min<std::size_t>(maximumLength, 64));
        for (std::size_t i = 0; i < maximumLength; ++i)
        {
            char character = '\0';
            if (!safeRead(address + i, character) || character == '\0')
                break;
            value.push_back(character);
        }
        return value;
    }

    std::string jsonString(const char* value)
    {
        if (value == nullptr)
            return "null";

        std::ostringstream out;
        out << '"';
        for (const unsigned char ch : std::string(value))
        {
            switch (ch)
            {
                case '\\': out << "\\\\"; break;
                case '"': out << "\\\""; break;
                case '\n': out << "\\n"; break;
                case '\r': out << "\\r"; break;
                case '\t': out << "\\t"; break;
                default:
                    if (ch < 0x20)
                        out << "\\u" << std::hex << std::setw(4) << std::setfill('0')
                            << static_cast<unsigned int>(ch) << std::dec;
                    else
                        out << static_cast<char>(ch);
                    break;
            }
        }
        out << '"';
        return out.str();
    }

    unsigned int envUInt(const char* name, unsigned int fallback)
    {
        char value[64] = {};
        const DWORD length = GetEnvironmentVariableA(name, value, static_cast<DWORD>(std::size(value)));
        if (length == 0 || length >= std::size(value))
            return fallback;
        char* end = nullptr;
        const unsigned long parsed = std::strtoul(value, &end, 0);
        return end != value ? static_cast<unsigned int>(parsed) : fallback;
    }

    float envFloat(const char* name, float fallback)
    {
        char value[64] = {};
        const DWORD length = GetEnvironmentVariableA(name, value, static_cast<DWORD>(std::size(value)));
        if (length == 0 || length >= std::size(value))
            return fallback;
        char* end = nullptr;
        const float parsed = std::strtof(value, &end);
        return end != value && std::isfinite(parsed) ? parsed : fallback;
    }

    std::string envString(const char* name)
    {
        char value[4096] = {};
        const DWORD length = GetEnvironmentVariableA(name, value, static_cast<DWORD>(std::size(value)));
        if (length == 0 || length >= std::size(value))
            return {};
        return std::string(value, length);
    }

    std::vector<UInt32> envUIntList(const char* name)
    {
        std::vector<UInt32> result;
        std::string value = envString(name);
        std::size_t offset = 0;
        while (offset < value.size())
        {
            const std::size_t separator = value.find(',', offset);
            const std::string token = value.substr(offset,
                separator == std::string::npos ? std::string::npos : separator - offset);
            char* end = nullptr;
            const unsigned long parsed = std::strtoul(token.c_str(), &end, 0);
            if (end != token.c_str())
                result.push_back(static_cast<UInt32>(parsed));
            if (separator == std::string::npos)
                break;
            offset = separator + 1;
        }
        return result;
    }

    std::vector<std::string> envCommandList(const char* name)
    {
        std::vector<std::string> result;
        std::string value = envString(name);
        std::size_t offset = 0;
        while (offset < value.size())
        {
            const std::size_t separator = value.find('|', offset);
            std::string command = value.substr(offset,
                separator == std::string::npos ? std::string::npos : separator - offset);
            const std::size_t first = command.find_first_not_of(" \t");
            const std::size_t last = command.find_last_not_of(" \t");
            if (first != std::string::npos)
                result.push_back(command.substr(first, last - first + 1));
            if (separator == std::string::npos)
                break;
            offset = separator + 1;
        }
        return result;
    }

    std::vector<std::string> envEditorIdList(const char* name)
    {
        std::vector<std::string> result;
        const std::string value = envString(name);
        std::size_t offset = 0;
        while (offset < value.size())
        {
            const std::size_t separator = value.find(',', offset);
            std::string editorId = value.substr(offset,
                separator == std::string::npos ? std::string::npos : separator - offset);
            const std::size_t first = editorId.find_first_not_of(" \t");
            const std::size_t last = editorId.find_last_not_of(" \t");
            if (first != std::string::npos)
                result.push_back(editorId.substr(first, last - first + 1));
            if (separator == std::string::npos)
                break;
            offset = separator + 1;
        }
        return result;
    }

    std::vector<ObserverWaypoint> envObserverWaypoints(const char* name)
    {
        std::vector<ObserverWaypoint> result;
        const std::string value = envString(name);
        std::size_t offset = 0;
        while (offset < value.size())
        {
            const std::size_t separator = value.find(';', offset);
            const std::string token = value.substr(offset,
                separator == std::string::npos ? std::string::npos : separator - offset);
            const std::size_t comma = token.find(',');
            if (comma != std::string::npos)
            {
                const std::string xText = token.substr(0, comma);
                const std::string yText = token.substr(comma + 1);
                char* xEnd = nullptr;
                char* yEnd = nullptr;
                const float x = std::strtof(xText.c_str(), &xEnd);
                const float y = std::strtof(yText.c_str(), &yEnd);
                if (xEnd != xText.c_str() && yEnd != yText.c_str() && std::isfinite(x) && std::isfinite(y))
                    result.push_back({ x, y });
            }
            if (separator == std::string::npos)
                break;
            offset = separator + 1;
        }
        return result;
    }

    std::vector<std::string> splitSidecarPlanLine(const std::string& line)
    {
        std::vector<std::string> fields;
        std::size_t offset = 0;
        while (offset <= line.size())
        {
            const std::size_t separator = line.find('\t', offset);
            fields.push_back(line.substr(offset,
                separator == std::string::npos ? std::string::npos : separator - offset));
            if (separator == std::string::npos)
                break;
            offset = separator + 1;
        }
        return fields;
    }

    bool parseSidecarUInt(const std::string& text, UInt32& value)
    {
        if (text.empty())
            return false;
        char* end = nullptr;
        const unsigned long parsed = std::strtoul(text.c_str(), &end, 0);
        if (end == text.c_str() || *end != '\0' || parsed > (std::numeric_limits<UInt32>::max)())
            return false;
        value = static_cast<UInt32>(parsed);
        return true;
    }

    bool parseSidecarFloat(const std::string& text, float& value)
    {
        if (text.empty())
            return false;
        char* end = nullptr;
        const float parsed = std::strtof(text.c_str(), &end);
        if (end == text.c_str() || *end != '\0' || !std::isfinite(parsed))
            return false;
        value = parsed;
        return true;
    }

    bool isSidecarToken(const std::string& value)
    {
        if (value.empty() || value.size() > 127)
            return false;
        for (const unsigned char ch : value)
        {
            if (!(std::isalnum(ch) || ch == '_' || ch == '-' || ch == '.'))
                return false;
        }
        return true;
    }

    bool isSidecarConsoleToken(const std::string& value)
    {
        if (value.empty() || value.size() > 63)
            return false;
        for (const unsigned char ch : value)
        {
            if (!(std::isalnum(ch) || ch == '_'))
                return false;
        }
        return true;
    }

    bool loadSidecarPlan(const std::string& path, SidecarPlan& result, std::string& error)
    {
        std::ifstream input(path, std::ios::in | std::ios::binary);
        if (!input)
        {
            error = "open-failed";
            return false;
        }

        input.seekg(0, std::ios::end);
        const std::streamoff fileBytes = input.tellg();
        if (fileBytes <= 0 || fileBytes > 16 * 1024 * 1024)
        {
            error = "invalid-plan-file-size";
            return false;
        }
        input.seekg(0, std::ios::beg);

        SidecarPlan parsed;
        std::string line;
        UInt32 lineNumber = 0;
        bool headerRead = false;
        bool endRead = false;
        enum class RecordPhase
        {
            Header,
            Sequence,
            Scene,
            Actions,
            Actors,
            End,
        };
        RecordPhase recordPhase = RecordPhase::Header;
        std::set<std::string> actionIds;
        std::set<UInt32> authoredReferences;
        while (std::getline(input, line))
        {
            ++lineNumber;
            if (line.size() > 4096 || line.find('\0') != std::string::npos)
            {
                error = "invalid-line-size-or-nul-line-" + std::to_string(lineNumber);
                return false;
            }
            if (!line.empty() && line.back() == '\r')
                line.pop_back();
            if (lineNumber == 1 && line.size() >= 3
                && static_cast<unsigned char>(line[0]) == 0xEF
                && static_cast<unsigned char>(line[1]) == 0xBB
                && static_cast<unsigned char>(line[2]) == 0xBF)
                line.erase(0, 3);
            if (line.empty())
                continue;
            if (endRead)
            {
                error = "record-after-end-line-" + std::to_string(lineNumber);
                return false;
            }
            if (line[0] == '#')
                continue;
            if (!headerRead)
            {
                if (line != "nikami-fnv-retail-plan-v1")
                {
                    error = "bad-header-line-" + std::to_string(lineNumber);
                    return false;
                }
                headerRead = true;
                recordPhase = RecordPhase::Sequence;
                continue;
            }

            const std::vector<std::string> fields = splitSidecarPlanLine(line);
            if (fields.empty())
                continue;
            if (fields[0] == "sequence")
            {
                if (recordPhase != RecordPhase::Sequence || fields.size() != 2
                    || !parsed.sequenceId.empty() || !isSidecarToken(fields[1]))
                {
                    error = "bad-sequence-line-" + std::to_string(lineNumber);
                    return false;
                }
                parsed.sequenceId = fields[1];
                recordPhase = RecordPhase::Scene;
            }
            else if (fields[0] == "scene")
            {
                if (recordPhase != RecordPhase::Scene || fields.size() != 17
                    || parsed.anchorForm != 0
                    || !parseSidecarUInt(fields[1], parsed.anchorForm)
                    || !parseSidecarUInt(fields[2], parsed.weatherForm)
                    || !parseSidecarFloat(fields[3], parsed.gameHour)
                    || !parseSidecarFloat(fields[4], parsed.timeScale)
                    || !parseSidecarFloat(fields[5], parsed.targetX)
                    || !parseSidecarFloat(fields[6], parsed.targetY)
                    || !parseSidecarFloat(fields[7], parsed.targetZ)
                    || !parseSidecarFloat(fields[8], parsed.targetYaw)
                    || !parseSidecarFloat(fields[9], parsed.playerX)
                    || !parseSidecarFloat(fields[10], parsed.playerY)
                    || !parseSidecarFloat(fields[11], parsed.playerZ)
                    || !parseSidecarFloat(fields[12], parsed.fullBodyDistanceScale)
                    || !parseSidecarFloat(fields[13], parsed.minimumCameraHeight)
                    || !parseSidecarFloat(fields[14], parsed.minimumAimHeight)
                    || !parseSidecarUInt(fields[15], parsed.initializationFrames)
                    || !parseSidecarUInt(fields[16], parsed.targetSettleFrames))
                {
                    error = "bad-scene-line-" + std::to_string(lineNumber);
                    return false;
                }
                recordPhase = RecordPhase::Actions;
            }
            else if (fields[0] == "action")
            {
                SidecarActionPlan action;
                if (recordPhase != RecordPhase::Actions || parsed.actions.size() >= 64
                    || fields.size() != 5 || !parseSidecarUInt(fields[1], action.index)
                    || action.index != parsed.actions.size() || !isSidecarToken(fields[2])
                    || !isSidecarConsoleToken(fields[3])
                    || !parseSidecarUInt(fields[4], action.frames)
                    || action.frames == 0 || action.frames > 36000
                    || !actionIds.insert(fields[2]).second)
                {
                    error = "bad-action-line-" + std::to_string(lineNumber);
                    return false;
                }
                action.id = fields[2];
                action.playGroup = fields[3];
                parsed.actions.push_back(action);
            }
            else if (fields[0] == "actor")
            {
                SidecarActorPlan actor;
                if ((recordPhase != RecordPhase::Actions && recordPhase != RecordPhase::Actors)
                    || parsed.actions.empty() || parsed.actors.size() >= 8192
                    || fields.size() != 6 || !parseSidecarUInt(fields[1], actor.index)
                    || actor.index != parsed.actors.size()
                    || !parseSidecarUInt(fields[2], actor.authoredRefForm)
                    || !parseSidecarUInt(fields[3], actor.baseForm)
                    || !parseSidecarUInt(fields[4], actor.weaponForm)
                    || !parseSidecarUInt(fields[5], actor.enableParentForm)
                    || actor.baseForm == 0
                    || (actor.authoredRefForm != 0
                        && !authoredReferences.insert(actor.authoredRefForm).second))
                {
                    error = "bad-actor-line-" + std::to_string(lineNumber);
                    return false;
                }
                parsed.actors.push_back(actor);
                recordPhase = RecordPhase::Actors;
            }
            else if (fields[0] == "end")
            {
                if (recordPhase != RecordPhase::Actors || parsed.actors.empty()
                    || fields.size() != 1)
                {
                    error = "bad-end-line-" + std::to_string(lineNumber);
                    return false;
                }
                endRead = true;
                recordPhase = RecordPhase::End;
            }
            else
            {
                error = "unknown-record-line-" + std::to_string(lineNumber);
                return false;
            }
        }

        if (input.bad())
        {
            error = "plan-read-failed";
            return false;
        }

        if (!headerRead || !endRead || parsed.sequenceId.empty() || parsed.anchorForm == 0
            || parsed.weatherForm == 0 || parsed.actions.empty() || parsed.actors.empty()
            || recordPhase != RecordPhase::End
            || parsed.gameHour < 0.f || parsed.gameHour >= 24.f || parsed.timeScale < 0.f
            || parsed.timeScale > 10000.f
            || parsed.fullBodyDistanceScale < 1.25f || parsed.fullBodyDistanceScale > 10.f
            || parsed.minimumCameraHeight < parsed.minimumAimHeight
            || parsed.minimumAimHeight < 0.f || parsed.initializationFrames == 0
            || parsed.initializationFrames > 1200 || parsed.targetSettleFrames == 0
            || parsed.targetSettleFrames > 600)
        {
            error = "incomplete-plan";
            return false;
        }
        result = std::move(parsed);
        return true;
    }

    UInt32 sidecarCrc32(const char* data, std::size_t size)
    {
        UInt32 crc = 0xFFFFFFFFu;
        for (std::size_t index = 0; index < size; ++index)
        {
            crc ^= static_cast<unsigned char>(data[index]);
            for (unsigned int bit = 0; bit < 8; ++bit)
                crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
        }
        return ~crc;
    }

    bool lockSidecarShared()
    {
        if (gSidecarShared == nullptr)
            return false;
        auto* mutex = reinterpret_cast<volatile LONG*>(&gSidecarShared->header.mutex);
        for (unsigned int attempt = 0; attempt < 256; ++attempt)
        {
            if (InterlockedCompareExchange(mutex, 1, 0) == 0)
                return true;
            SwitchToThread();
        }
        return false;
    }

    void unlockSidecarShared()
    {
        if (gSidecarShared != nullptr)
        {
            MemoryBarrier();
            InterlockedExchange(reinterpret_cast<volatile LONG*>(&gSidecarShared->header.mutex), 0);
        }
    }

    std::string sidecarObjectName(const char* suffix)
    {
        return gSidecarSharedMemoryName + suffix;
    }

    void closeSidecarSharedMemory()
    {
        if (gSidecarShared != nullptr)
        {
            UnmapViewOfFile(gSidecarShared);
            gSidecarShared = nullptr;
        }
        HANDLE* handles[] = {
            &gSidecarRetailReadyEvent,
            &gSidecarOpenMwReadyEvent,
            &gSidecarCaptureAckEvent,
            &gSidecarErrorEvent,
            &gSidecarMapping,
        };
        for (HANDLE* handle : handles)
        {
            if (*handle != nullptr)
            {
                CloseHandle(*handle);
                *handle = nullptr;
            }
        }
    }

    bool validateSidecarCoordinatorPlanStateLocked(std::string& error)
    {
        if (gSidecarShared == nullptr)
        {
            error = "shared-memory-unavailable";
            return false;
        }
        const auto& header = gSidecarShared->header;
        const std::size_t sequenceLength
            = strnlen_s(header.sequenceId, std::size(header.sequenceId));
        if (sequenceLength == std::size(header.sequenceId)
            || sequenceLength == 0
            || gSidecarPlan.sequenceId != std::string(header.sequenceId, sequenceLength))
        {
            error = "shared-memory-sequence-mismatch";
            return false;
        }
        if ((header.flags & NikamiFNVSidecar::ErrorFlag) != 0
            || header.errorCode != static_cast<UInt32>(NikamiFNVSidecar::ErrorCode::None))
        {
            error = "shared-memory-peer-error-active";
            return false;
        }
        if (header.state != static_cast<UInt32>(NikamiFNVSidecar::State::PlanLoaded)
            || header.actorIndex != 0 || header.actionIndex != 0
            || header.actionCount != static_cast<UInt32>(gSidecarPlan.actions.size())
            || header.generation != 0)
        {
            error = "shared-memory-initial-state-mismatch";
            return false;
        }
        return true;
    }

    bool initializeSidecarSharedMemory(std::string& error)
    {
        if (gSidecarSharedMemoryName.empty() || gSidecarSharedMemoryName.size() > 180)
        {
            error = "invalid-shared-memory-name";
            return false;
        }
        gSidecarMapping = OpenFileMappingA(
            FILE_MAP_ALL_ACCESS, FALSE, gSidecarSharedMemoryName.c_str());
        if (gSidecarMapping == nullptr)
        {
            error = "open-file-mapping-failed-" + std::to_string(GetLastError());
            return false;
        }
        gSidecarShared = static_cast<NikamiFNVSidecar::SharedBlock*>(MapViewOfFile(
            gSidecarMapping, FILE_MAP_ALL_ACCESS, 0, 0, NikamiFNVSidecar::SharedBlockBytes));
        if (gSidecarShared == nullptr)
        {
            error = "map-view-failed-" + std::to_string(GetLastError());
            closeSidecarSharedMemory();
            return false;
        }
        if (gSidecarShared->header.magic != NikamiFNVSidecar::Magic
            || gSidecarShared->header.version != NikamiFNVSidecar::Version
            || gSidecarShared->header.headerBytes != NikamiFNVSidecar::SharedHeaderBytes
            || gSidecarShared->header.totalBytes != NikamiFNVSidecar::SharedBlockBytes)
        {
            error = "shared-memory-contract-mismatch";
            closeSidecarSharedMemory();
            return false;
        }
        if (!lockSidecarShared())
        {
            error = "shared-memory-initial-lock-failed";
            closeSidecarSharedMemory();
            return false;
        }
        const bool initialStateValid = validateSidecarCoordinatorPlanStateLocked(error);
        unlockSidecarShared();
        if (!initialStateValid)
        {
            closeSidecarSharedMemory();
            return false;
        }

        const std::string retailReadyName = sidecarObjectName(".retail-ready");
        const std::string openMwReadyName = sidecarObjectName(".openmw-ready");
        const std::string captureAckName = sidecarObjectName(".capture-ack");
        const std::string errorName = sidecarObjectName(".error");
        constexpr DWORD eventAccess = EVENT_MODIFY_STATE | SYNCHRONIZE;
        gSidecarRetailReadyEvent = OpenEventA(eventAccess, FALSE, retailReadyName.c_str());
        gSidecarOpenMwReadyEvent = OpenEventA(eventAccess, FALSE, openMwReadyName.c_str());
        gSidecarCaptureAckEvent = OpenEventA(eventAccess, FALSE, captureAckName.c_str());
        gSidecarErrorEvent = OpenEventA(eventAccess, FALSE, errorName.c_str());
        if (gSidecarRetailReadyEvent == nullptr || gSidecarOpenMwReadyEvent == nullptr
            || gSidecarCaptureAckEvent == nullptr || gSidecarErrorEvent == nullptr)
        {
            error = "open-shared-event-failed-" + std::to_string(GetLastError());
            closeSidecarSharedMemory();
            return false;
        }
        return true;
    }

    bool publishSidecarRetailPlanPayload(const std::string& payload, std::string& error)
    {
        if (payload.size() > NikamiFNVSidecar::PayloadBytes
            || gSidecarShared == nullptr || !lockSidecarShared())
        {
            error = "plan-payload-too-large-or-lock-failed";
            return false;
        }
        if (!validateSidecarCoordinatorPlanStateLocked(error))
        {
            unlockSidecarShared();
            return false;
        }
        const std::size_t size = payload.size();
        std::memcpy(gSidecarShared->retailPayload, payload.data(), size);
        if (size < NikamiFNVSidecar::PayloadBytes)
            gSidecarShared->retailPayload[size] = '\0';
        gSidecarShared->header.retailPayloadLength = static_cast<UInt32>(size);
        gSidecarShared->header.retailPayloadCrc32 = sidecarCrc32(payload.data(), size);
        gSidecarShared->header.retailFrame = gFrame;
        unlockSidecarShared();
        return true;
    }

    bool publishSidecarRetailPayload(const std::string& payload, NikamiFNVSidecar::State state,
        UInt32 flagsToSet, bool replaceReadyFlags)
    {
        if (payload.size() > NikamiFNVSidecar::PayloadBytes
            || gSidecarShared == nullptr || !lockSidecarShared())
            return false;
        const std::size_t size = payload.size();
        std::memcpy(gSidecarShared->retailPayload, payload.data(), size);
        if (size < NikamiFNVSidecar::PayloadBytes)
            gSidecarShared->retailPayload[size] = '\0';
        gSidecarShared->header.retailPayloadLength = static_cast<UInt32>(size);
        gSidecarShared->header.retailPayloadCrc32 = sidecarCrc32(payload.data(), size);
        gSidecarShared->header.retailFrame = gFrame;
        gSidecarShared->header.state = static_cast<UInt32>(state);
        if (replaceReadyFlags)
        {
            constexpr UInt32 transient = NikamiFNVSidecar::RetailReadyFlag
                | NikamiFNVSidecar::OpenMwReadyFlag | NikamiFNVSidecar::RetailCapturedFlag
                | NikamiFNVSidecar::OpenMwCapturedFlag | NikamiFNVSidecar::CaptureAckFlag;
            gSidecarShared->header.flags &= ~transient;
        }
        gSidecarShared->header.flags |= flagsToSet;
        unlockSidecarShared();
        return true;
    }

    void setSidecarSharedError(NikamiFNVSidecar::ErrorCode code, const std::string& message)
    {
        if (gSidecarShared != nullptr && lockSidecarShared())
        {
            const bool peerErrorActive
                = (gSidecarShared->header.flags & NikamiFNVSidecar::ErrorFlag) != 0
                || gSidecarShared->header.errorCode
                    != static_cast<UInt32>(NikamiFNVSidecar::ErrorCode::None);
            if (!peerErrorActive)
            {
                gSidecarShared->header.state
                    = static_cast<UInt32>(NikamiFNVSidecar::State::Error);
                gSidecarShared->header.flags |= NikamiFNVSidecar::ErrorFlag;
                gSidecarShared->header.errorCode = static_cast<UInt32>(code);
                strncpy_s(gSidecarShared->header.errorMessage, message.c_str(), _TRUNCATE);
                gSidecarShared->header.retailFrame = gFrame;
            }
            unlockSidecarShared();
        }
        if (gSidecarErrorEvent != nullptr)
            SetEvent(gSidecarErrorEvent);
    }

    unsigned int handGripIndex(UInt8 value)
    {
        if (value == TESObjectWEAP::eHandGrip_Default)
            return 0;
        if (value >= TESObjectWEAP::eHandGrip_1 && value <= TESObjectWEAP::eHandGrip_6)
            return static_cast<unsigned int>(value - TESObjectWEAP::eHandGrip_1 + 1);
        return 0xffff;
    }

    unsigned int attackAnimationIndex(UInt8 value)
    {
        static constexpr UInt8 values[] = { TESObjectWEAP::eAttackAnim_Default,
            TESObjectWEAP::eAttackAnim_Attack3, TESObjectWEAP::eAttackAnim_Attack4,
            TESObjectWEAP::eAttackAnim_Attack5, TESObjectWEAP::eAttackAnim_Attack6,
            TESObjectWEAP::eAttackAnim_Attack7, TESObjectWEAP::eAttackAnim_Attack8,
            TESObjectWEAP::eAttackAnim_Attack9, TESObjectWEAP::eAttackAnim_AttackLeft,
            TESObjectWEAP::eAttackAnim_AttackLoop, TESObjectWEAP::eAttackAnim_AttackRight,
            TESObjectWEAP::eAttackAnim_AttackSpin, TESObjectWEAP::eAttackAnim_AttackSpin2,
            TESObjectWEAP::eAttackAnim_AttackThrow, TESObjectWEAP::eAttackAnim_AttackThrow2,
            TESObjectWEAP::eAttackAnim_AttackThrow3, TESObjectWEAP::eAttackAnim_AttackThrow4,
            TESObjectWEAP::eAttackAnim_AttackThrow5, TESObjectWEAP::eAttackAnim_AttackThrow6,
            TESObjectWEAP::eAttackAnim_AttackThrow7, TESObjectWEAP::eAttackAnim_AttackThrow8,
            TESObjectWEAP::eAttackAnim_PlaceMine, TESObjectWEAP::eAttackAnim_PlaceMine2 };
        for (unsigned int i = 0; i < std::size(values); ++i)
            if (values[i] == value)
                return i;
        return 0xffff;
    }

    void openOutput()
    {
        if (gOutput.is_open())
            return;

        char path[MAX_PATH * 4] = {};
        const DWORD length = GetEnvironmentVariableA(
            "NIKAMI_ORACLE_OUTPUT", path, static_cast<DWORD>(std::size(path)));
        const char* outputPath = length > 0 && length < std::size(path)
            ? path
            : "Data\\NVSE\\Plugins\\nikami_retail_oracle.jsonl";
        gOutput.open(outputPath, std::ios::out | std::ios::trunc);
        if (gOutput)
        {
            gOutput << "{\"schema\":" << jsonString(sSchema) << ",\"event\":\"start\","
                       "\"runtime\":\"FalloutNV-1.4.0.525\","
                       "\"boneLodWriterCallsHooked\":" << (gBoneLodWriterCallsHooked ? "true" : "false") << ','
                    << "\"highProcessBoneLodPathHooked\":"
                    << (gHighProcessBoneLodPathHooked ? "true" : "false") << ','
                    << "\"niAvObjectTransformLayout\":\"local@0x34/world@0x68/NiTransform@0x34\","
                    << "\"batchProofStaging\":" << (gBatchProofStaging ? "true" : "false")
                    << ",\"batchProofAnchorForm\":" << gBatchProofAnchorForm
                    << ",\"batchProofTarget\":[" << gBatchProofTargetX << ',' << gBatchProofTargetY
                    << ',' << gBatchProofTargetZ << ',' << gBatchProofTargetYaw << ']'
                    << ",\"batchProofMinimumCameraHeight\":"
                    << gBatchProofMinimumCameraHeight
                    << ",\"batchProofMinimumAimHeight\":"
                    << gBatchProofMinimumAimHeight << "}\n";
            gOutput.flush();
        }
    }

    void writeMatrix(std::ostream& out, const NiMatrix33& value)
    {
        out << '[';
        for (unsigned int i = 0; i < 9; ++i)
        {
            if (i != 0)
                out << ',';
            out << value.data[i];
        }
        out << ']';
    }

    void writeVector(std::ostream& out, const NiVector3& value)
    {
        out << '[' << value.x << ',' << value.y << ',' << value.z << ']';
    }

    const char* runtimeTypeName(NiObject* object)
    {
        if (object == nullptr)
            return nullptr;
        __try
        {
            NiRTTI* type = object->GetType();
            return type != nullptr ? type->name : nullptr;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            return nullptr;
        }
    }

    void writeInterpolator(std::ostream& out, NiObject* interpolator)
    {
        const std::string type = safeRuntimeString(runtimeTypeName(interpolator));
        out << "{\"type\":" << jsonString(type.empty() ? nullptr : type.c_str());
        OracleTransformInterpolator transform = {};
        if (type == "NiTransformInterpolator" && safeRead(interpolator, transform))
        {
            out << ",\"lastUpdate\":" << transform.lastUpdateTime << ",\"value\":{"
                // Fallout's runtime quaternion storage is W,X,Y,Z while the public xNVSE NiQuaternion
                // fields are named X,Y,Z,W. Emit a conventional X,Y,Z,W JSON tuple.
                << "\"rotation\":[" << transform.value.rotation.y << ',' << transform.value.rotation.z << ','
                << transform.value.rotation.w << ',' << transform.value.rotation.x << "],\"translation\":";
            writeVector(out, transform.value.translation);
            out << ",\"scale\":" << transform.value.scale << '}';
        }
        out << '}';
    }

    bool isOracleBlendTarget(const std::string& name)
    {
        static const char* targets[] = { "Bip01", "Bip01 NonAccum", "Bip01 Looking", "Bip01 Translate",
            "Bip01 Rotate", "Bip01 Pelvis", "Bip01 Spine", "Bip01 Spine1", "Bip01 Spine2", "Bip01 Neck",
            "Bip01 Neck1", "Bip01 Head", "Bip01 L Clavicle", "Bip01 L UpperArm", "Bip01 L Forearm",
            "Bip01 L Hand", "Bip01 R Clavicle", "Bip01 R UpperArm", "Bip01 R Forearm", "Bip01 R Hand",
            "Bip01 L Thigh", "Bip01 L Calf", "Bip01 L Foot", "Bip01 L Toe0", "Bip01 R Thigh",
            "Bip01 R Calf", "Bip01 R Foot", "Bip01 R Toe0", "Bip01 LUpArmTwistBone",
            "Bip01 RUpArmTwistBone", "Bip01 L ForeTwist", "Bip01 R ForeTwist", "Bip01 L Thumb1",
            "Bip01 L Thumb11", "Bip01 L Thumb12", "Bip01 R Thumb1", "Bip01 R Thumb11", "Bip01 R Thumb12",
            "Bip01 L Finger1", "Bip01 L Finger11", "Bip01 L Finger12", "Bip01 L Finger2",
            "Bip01 L Finger21", "Bip01 L Finger22", "Bip01 L Finger3", "Bip01 L Finger31",
            "Bip01 L Finger32", "Bip01 L Finger4", "Bip01 L Finger41", "Bip01 L Finger42",
            "Bip01 R Finger1", "Bip01 R Finger11", "Bip01 R Finger12", "Bip01 R Finger2",
            "Bip01 R Finger21", "Bip01 R Finger22", "Bip01 R Finger3", "Bip01 R Finger31",
            "Bip01 R Finger32", "Bip01 R Finger4", "Bip01 R Finger41", "Bip01 R Finger42",
            "Bip01 LPauldron", "Bip01 RPauldron", "Weapon" };
        for (const char* target : targets)
        {
            if (_stricmp(name.c_str(), target) == 0)
                return true;
        }
        return false;
    }

    bool isPlausibleOracleName(const std::string& value)
    {
        if (value.empty() || value.size() > 160)
            return false;
        for (const unsigned char character : value)
        {
            if (character < 0x20 || character == 0x7f)
                return false;
        }
        return true;
    }

    bool readControlledBlockId(
        const BSAnimGroupSequence* sequence, unsigned int blockIndex, OracleControlledBlockId& id)
    {
        if (sequence->unk018 == nullptr)
            return false;

        // Retail sequence arrays have appeared in both contiguous and pointer-array declarations.
        // Validate the embedded fixed string rather than trusting either declaration.
        OracleControlledBlockId candidate = {};
        if (safeRead(reinterpret_cast<const OracleControlledBlockId*>(sequence->unk018) + blockIndex, candidate)
            && isPlausibleOracleName(safeRuntimeString(candidate.objectName)))
        {
            id = candidate;
            return true;
        }

        auto** ids = reinterpret_cast<OracleControlledBlockId**>(sequence->unk018);
        OracleControlledBlockId* address = nullptr;
        if (safeRead(ids + blockIndex, address) && safeRead(address, candidate)
            && isPlausibleOracleName(safeRuntimeString(candidate.objectName)))
        {
            id = candidate;
            return true;
        }
        return false;
    }

    std::string controlledBlockTargetName(
        const OracleControlledBlock& block, unsigned int blockIndex, unsigned int& targetIndex,
        unsigned long& blendArrayBaseAddress)
    {
        OracleMultiTargetTransformController controller = {};
        if (!safeRead(block.multiTargetController, controller) || controller.targets == nullptr
            || controller.targetCount == 0)
            return {};

        targetIndex = blockIndex;
        blendArrayBaseAddress
            = static_cast<unsigned long>(reinterpret_cast<std::uintptr_t>(controller.blendInterpolator));
        const std::uintptr_t blendBase = reinterpret_cast<std::uintptr_t>(controller.blendInterpolator);
        const std::uintptr_t blockBlend = reinterpret_cast<std::uintptr_t>(block.blendInterpolator);
        if (blendBase != 0 && blockBlend >= blendBase)
        {
            const std::uintptr_t difference = blockBlend - blendBase;
            if (difference % sizeof(OracleBlendInterpolator) == 0)
            {
                const std::uintptr_t candidate = difference / sizeof(OracleBlendInterpolator);
                if (candidate < controller.targetCount)
                    targetIndex = static_cast<unsigned int>(candidate);
            }
        }
        if (targetIndex >= controller.targetCount)
            return {};

        NiAVObject* target = nullptr;
        const char* targetName = nullptr;
        if (!safeRead(controller.targets + targetIndex, target) || target == nullptr
            || !safeRead(reinterpret_cast<const UInt8*>(target) + 0x08, targetName))
            return {};
        return safeRuntimeString(targetName);
    }

    void writeControlledBlockProbe(std::ostream& out, const BSAnimGroupSequence* sequence)
    {
        out << "[";
        bool firstBlock = true;
        const unsigned int blockCount = std::min<unsigned int>(sequence->arraySize, 512);
        auto** blocks = reinterpret_cast<OracleControlledBlock**>(sequence->unk014);
        if (blocks != nullptr)
        {
            for (unsigned int blockIndex = 0; blockIndex < blockCount; ++blockIndex)
            {
                OracleControlledBlock* blockAddress = nullptr;
                OracleControlledBlock block = {};
                // Retail FNV stores these as a contiguous ControlledBlock array.  Some later
                // reverse-engineered headers describe a pointer array, so accept that shape as
                // a fallback as well and validate it by resolving the controller's target.
                bool hasBlock = safeRead(reinterpret_cast<const OracleControlledBlock*>(sequence->unk014) + blockIndex,
                    block);
                unsigned int targetIndex = blockIndex;
                unsigned long blendArrayBaseAddress = 0;
                std::string controllerObjectName = hasBlock
                    ? controlledBlockTargetName(block, blockIndex, targetIndex, blendArrayBaseAddress)
                    : std::string();
                if (controllerObjectName.empty() && safeRead(blocks + blockIndex, blockAddress)
                    && safeRead(blockAddress, block))
                {
                    controllerObjectName
                        = controlledBlockTargetName(block, blockIndex, targetIndex, blendArrayBaseAddress);
                    hasBlock = !controllerObjectName.empty();
                }
                if (!hasBlock)
                    continue;

                OracleControlledBlockId id = {};
                const bool hasId = readControlledBlockId(sequence, blockIndex, id);
                const std::string idObjectName = hasId ? safeRuntimeString(id.objectName) : std::string();
                const std::string objectName
                    = isPlausibleOracleName(idObjectName) ? idObjectName : controllerObjectName;
                // High-priority blocks are included even when this old xNVSE ABI cannot resolve
                // their target by index.  Their shared blend pointer lets the oracle correlate
                // them with the named lower-priority block that owns the live blend array.
                if (!isOracleBlendTarget(objectName) && block.priority < 40)
                    continue;

                if (!firstBlock)
                    out << ',';
                firstBlock = false;
                const std::string controllerType = hasId ? safeRuntimeString(id.controllerType) : std::string();
                const std::string interpolatorId = hasId ? safeRuntimeString(id.interpolatorId) : std::string();
                const std::string sourceType = safeRuntimeString(runtimeTypeName(block.interpolator));
                const std::string controllerRuntimeType
                    = safeRuntimeString(runtimeTypeName(block.multiTargetController));
                const std::string blendRuntimeType
                    = safeRuntimeString(runtimeTypeName(reinterpret_cast<NiObject*>(block.blendInterpolator)));
                out << "{\"index\":" << blockIndex << ",\"object\":"
                    << jsonString(objectName.empty() ? "<unresolved>" : objectName.c_str())
                    << ",\"idObject\":"
                    << jsonString(idObjectName.empty() ? nullptr : idObjectName.c_str())
                    << ",\"controllerObject\":"
                    << jsonString(controllerObjectName.empty() ? nullptr : controllerObjectName.c_str())
                    << ",\"controllerTargetIndex\":" << targetIndex
                    << ",\"controllerType\":"
                    << jsonString(controllerType.empty() ? nullptr : controllerType.c_str())
                    << ",\"controllerRuntimeType\":"
                    << jsonString(controllerRuntimeType.empty() ? nullptr : controllerRuntimeType.c_str())
                    << ",\"interpolatorType\":"
                    << jsonString(interpolatorId.empty() ? nullptr : interpolatorId.c_str())
                    << ",\"sourceRuntimeType\":"
                    << jsonString(sourceType.empty() ? nullptr : sourceType.c_str())
                    << ",\"sourceAddress\":"
                    << static_cast<unsigned long>(reinterpret_cast<std::uintptr_t>(block.interpolator))
                    << ",\"controllerAddress\":"
                    << static_cast<unsigned long>(reinterpret_cast<std::uintptr_t>(block.multiTargetController))
                    << ",\"blendArrayBaseAddress\":" << blendArrayBaseAddress
                    << ",\"blendAddress\":"
                    << static_cast<unsigned long>(reinterpret_cast<std::uintptr_t>(block.blendInterpolator))
                    << ",\"blendRuntimeType\":"
                    << jsonString(blendRuntimeType.empty() ? nullptr : blendRuntimeType.c_str())
                    << ",\"priority\":" << static_cast<unsigned int>(block.priority)
                    << ",\"blendIndex\":" << static_cast<unsigned int>(block.blendIndex)
                    << ",\"sourceInterpolator\":";
                writeInterpolator(out, block.interpolator);

                const OracleBlendInterpolator* blendAddress = block.blendInterpolator;
                OracleBlendInterpolator blend = {};
                out << ",\"blend\":";
                if (!safeRead(blendAddress, blend))
                {
                    out << "null}";
                    continue;
                }

                out << "{\"flags\":" << static_cast<unsigned int>(blend.flags)
                    << ",\"arraySize\":" << static_cast<unsigned int>(blend.arraySize)
                    << ",\"count\":" << static_cast<unsigned int>(blend.interpolatorCount)
                    << ",\"singleIndex\":" << static_cast<unsigned int>(blend.singleIndex)
                    << ",\"highPriority\":" << static_cast<unsigned int>(blend.highPriority)
                    << ",\"nextHighPriority\":" << static_cast<unsigned int>(blend.nextHighPriority)
                    << ",\"weightThreshold\":" << blend.weightThreshold
                    << ",\"singleTime\":" << blend.singleTime
                    << ",\"highWeightSum\":" << blend.highWeightSum
                    << ",\"nextHighWeightSum\":" << blend.nextHighWeightSum
                    << ",\"highEaseSpinner\":" << blend.highEaseSpinner << ",\"items\":[";
                bool firstItem = true;
                const unsigned int itemCount = std::min<unsigned int>(blend.arraySize, 32);
                if (blend.items != nullptr)
                {
                    for (unsigned int itemIndex = 0; itemIndex < itemCount; ++itemIndex)
                    {
                        OracleBlendItem item = {};
                        if (!safeRead(blend.items + itemIndex, item))
                            continue;
                        if (item.interpolator == nullptr)
                            continue;
                        if (!firstItem)
                            out << ',';
                        firstItem = false;
                        out << "{\"index\":" << itemIndex << ",\"weight\":" << item.weight
                            << ",\"normalizedWeight\":" << item.normalizedWeight
                            << ",\"priority\":" << static_cast<unsigned int>(item.priority)
                            << ",\"easeSpinner\":" << item.easeSpinner
                            << ",\"updateTime\":" << item.updateTime << ",\"interpolator\":";
                        writeInterpolator(out, item.interpolator);
                        out << '}';
                    }
                }
                out << "]}}";
            }
        }
        out << ']';
    }

    const NiTransform& runtimeTransform(const NiAVObject& node, std::size_t offset)
    {
        return *reinterpret_cast<const NiTransform*>(reinterpret_cast<const UInt8*>(&node) + offset);
    }

    void writeTransform(std::ostream& out, const NiAVObject& node)
    {
        const NiTransform& local = runtimeTransform(node, sNiAVObjectLocalTransformOffset);
        const NiTransform& world = runtimeTransform(node, sNiAVObjectWorldTransformOffset);
        out << "{\"localRotation\":";
        writeMatrix(out, local.rotate);
        out << ",\"localTranslation\":";
        writeVector(out, local.translate);
        out << ",\"localScale\":" << local.scale;
        out << ",\"worldRotation\":";
        writeMatrix(out, world.rotate);
        out << ",\"worldTranslation\":";
        writeVector(out, world.translate);
        out << ",\"worldScale\":" << world.scale << '}';
    }

    void writeNodeRecursive(std::ostream& out, NiAVObject* object, bool& first, unsigned int depth)
    {
        if (object == nullptr || depth > 64)
            return;

        if (object->m_pcName != nullptr && object->m_pcName[0] != '\0')
        {
            if (!first)
                out << ',';
            first = false;
            out << "{\"name\":" << jsonString(object->m_pcName) << ",\"depth\":" << depth
                << ",\"parentName\":"
                << jsonString(object->m_parent != nullptr ? object->m_parent->m_pcName : nullptr)
                << ",\"runtimeFlags\":" << object->unk0030
                << ",\"transform\":";
            writeTransform(out, *object);
            out << '}';
        }

        NiNode* node = object->GetAsNiNode();
        if (node == nullptr || node->m_children.data == nullptr)
            return;
        const unsigned int count = std::min<unsigned int>(node->m_children.firstFreeEntry, 2048);
        for (unsigned int i = 0; i < count; ++i)
            writeNodeRecursive(out, node->m_children.data[i], first, depth + 1);
    }

    NiAVObject* findNodeRecursive(NiAVObject* object, const char* name, unsigned int depth = 0)
    {
        if (object == nullptr || name == nullptr || depth > 64)
            return nullptr;
        if (object->m_pcName != nullptr && _stricmp(object->m_pcName, name) == 0)
            return object;
        NiNode* node = object->GetAsNiNode();
        if (node == nullptr || node->m_children.data == nullptr)
            return nullptr;
        const unsigned int count = std::min<unsigned int>(node->m_children.firstFreeEntry, 2048);
        for (unsigned int i = 0; i < count; ++i)
        {
            if (NiAVObject* found = findNodeRecursive(node->m_children.data[i], name, depth + 1))
                return found;
        }
        return nullptr;
    }

    NiAVObject* findNodeRecursivePrefix(NiAVObject* object, const char* prefix, unsigned int depth = 0)
    {
        if (object == nullptr || prefix == nullptr || depth > 64)
            return nullptr;
        const std::size_t prefixLength = std::strlen(prefix);
        if (object->m_pcName != nullptr && _strnicmp(object->m_pcName, prefix, prefixLength) == 0)
            return object;
        NiNode* node = object->GetAsNiNode();
        if (node == nullptr || node->m_children.data == nullptr)
            return nullptr;
        const unsigned int count = std::min<unsigned int>(node->m_children.firstFreeEntry, 2048);
        for (unsigned int i = 0; i < count; ++i)
        {
            if (NiAVObject* found = findNodeRecursivePrefix(node->m_children.data[i], prefix, depth + 1))
                return found;
        }
        return nullptr;
    }

    // Runtime 1.4.0.525 layout documented by the game's NiGeometryData methods.
    // Keep the oracle copy private so a stale public xNVSE class declaration cannot
    // silently move the vertex pointer. The explicit size/offsets are part of the
    // evidence emitted below.
    struct OracleGeometryData
    {
        void* vtable;
        UInt32 refCount;
        UInt16 vertexCount;
        UInt16 id;
        UInt16 dataFlags;
        UInt16 dirtyFlags;
        OracleVector3 boundCenter;
        float boundRadius;
        OracleVector3* vertices;
        OracleVector3* normals;
        void* vertexColors;
        void* uvCoordinates;
        void* additionalData;
        void* bufferData;
        UInt8 keepFlags;
        UInt8 compressFlags;
        UInt8 byte3A;
        UInt8 byte3B;
        UInt8 canSave;
        UInt8 padding[3];
    };

    static_assert(sizeof(OracleGeometryData) == 0x40);
    static_assert(offsetof(OracleGeometryData, vertices) == 0x20);

    bool isOracleGeometryType(const std::string& type)
    {
        return type == "NiGeometry" || type == "NiLines"
            || type.find("TriShape") != std::string::npos
            || type.find("TriStrips") != std::string::npos;
    }

    struct ActorGeometryCaptureStatus
    {
        UInt32 visitedNodes = 0;
        UInt32 geometryCandidates = 0;
        UInt32 emittedShapes = 0;
        UInt32 pointerReadFailures = 0;
        UInt32 dataReadFailures = 0;
        UInt32 invalidDataLayouts = 0;
        UInt32 vertexReadFailures = 0;
        bool traversalFault = false;
    };

    void writeActorGeometryNodeStatus(Actor* actor, NiAVObject* object, unsigned int depth,
        const std::string& type, const char* status, OracleGeometryData* dataAddress,
        bool shaderPointerRead, bool dataPointerRead, bool skinPointerRead,
        const OracleGeometryData* data = nullptr)
    {
        const std::string name = object != nullptr ? safeRuntimeString(object->m_pcName) : std::string();
        gOutput << "{\"schema\":" << sSchemaJson << ",\"event\":\"actor-geometry-node-status\""
                << ",\"frame\":" << gFrame
                << ",\"refForm\":" << (actor != nullptr ? actor->refID : 0)
                << ",\"baseForm\":"
                << (actor != nullptr && actor->baseForm != nullptr ? actor->baseForm->refID : 0)
                << ",\"name\":" << jsonString(name.empty() ? nullptr : name.c_str())
                << ",\"runtimeType\":" << jsonString(type.empty() ? nullptr : type.c_str())
                << ",\"depth\":" << depth
                << ",\"status\":" << jsonString(status)
                << ",\"layout\":\"NiGeometryData@0xb8 vertices@data+0x20\""
                << ",\"shaderPointerRead\":" << (shaderPointerRead ? "true" : "false")
                << ",\"dataPointerRead\":" << (dataPointerRead ? "true" : "false")
                << ",\"skinPointerRead\":" << (skinPointerRead ? "true" : "false")
                << ",\"geometryDataAddress\":"
                << static_cast<unsigned long>(reinterpret_cast<std::uintptr_t>(dataAddress));
        if (data != nullptr)
        {
            gOutput << ",\"vertexCount\":" << data->vertexCount
                    << ",\"verticesAddress\":"
                    << static_cast<unsigned long>(reinterpret_cast<std::uintptr_t>(data->vertices));
        }
        else
            gOutput << ",\"vertexCount\":null,\"verticesAddress\":null";
        gOutput << "}\n";
    }

    void writeActorGeometryRecursive(
        Actor* actor, NiAVObject* object, unsigned int depth, ActorGeometryCaptureStatus& status)
    {
        if (actor == nullptr || object == nullptr || depth > 64)
            return;

        ++status.visitedNodes;

        const std::string type = safeRuntimeString(runtimeTypeName(reinterpret_cast<NiObject*>(object)));
        if (isOracleGeometryType(type))
        {
            ++status.geometryCandidates;
            // FNV NiAVObject is 0x9c bytes. NiGeometry's shader property, model
            // data, and skin instance live at 0xa8, 0xb8, and 0xbc respectively.
            NiObject* shaderProperty = nullptr;
            NiObject* skinInstance = nullptr;
            OracleGeometryData* dataAddress = nullptr;
            const bool shaderPointerRead
                = safeRead(reinterpret_cast<const UInt8*>(object) + 0xA8, shaderProperty);
            const bool dataPointerRead
                = safeRead(reinterpret_cast<const UInt8*>(object) + 0xB8, dataAddress);
            const bool skinPointerRead
                = safeRead(reinterpret_cast<const UInt8*>(object) + 0xBC, skinInstance);
            if (!shaderPointerRead || !dataPointerRead || !skinPointerRead)
            {
                ++status.pointerReadFailures;
                writeActorGeometryNodeStatus(actor, object, depth, type, "geometry-pointer-read-failed",
                    dataAddress, shaderPointerRead, dataPointerRead, skinPointerRead);
            }

            OracleGeometryData data = {};
            const bool dataRead = dataPointerRead && dataAddress != nullptr && safeRead(dataAddress, data);
            if (!dataRead)
            {
                ++status.dataReadFailures;
                writeActorGeometryNodeStatus(actor, object, depth, type, "geometry-data-read-failed",
                    dataAddress, shaderPointerRead, dataPointerRead, skinPointerRead);
            }
            else if (data.vertexCount == 0 || data.vertexCount > 32768 || data.vertices == nullptr)
            {
                ++status.invalidDataLayouts;
                writeActorGeometryNodeStatus(actor, object, depth, type, "geometry-data-invalid",
                    dataAddress, shaderPointerRead, dataPointerRead, skinPointerRead, &data);
            }
            else
            {
                std::vector<OracleVector3> vertices;
                vertices.reserve(data.vertexCount);
                OracleVector3 minimum = {};
                OracleVector3 maximum = {};
                bool complete = true;
                for (UInt32 index = 0; index < data.vertexCount; ++index)
                {
                    OracleVector3 vertex = {};
                    if (!safeRead(data.vertices + index, vertex)
                        || !std::isfinite(vertex.x) || !std::isfinite(vertex.y) || !std::isfinite(vertex.z))
                    {
                        complete = false;
                        ++status.vertexReadFailures;
                        break;
                    }
                    if (vertices.empty())
                        minimum = maximum = vertex;
                    else
                    {
                        minimum.x = (std::min)(minimum.x, vertex.x);
                        minimum.y = (std::min)(minimum.y, vertex.y);
                        minimum.z = (std::min)(minimum.z, vertex.z);
                        maximum.x = (std::max)(maximum.x, vertex.x);
                        maximum.y = (std::max)(maximum.y, vertex.y);
                        maximum.z = (std::max)(maximum.z, vertex.z);
                    }
                    vertices.push_back(vertex);
                }

                const std::string name = safeRuntimeString(object->m_pcName);
                const std::string parentName = object->m_parent != nullptr
                    ? safeRuntimeString(object->m_parent->m_pcName) : std::string();
                const std::string shaderType = safeRuntimeString(runtimeTypeName(shaderProperty));
                const std::string skinType = safeRuntimeString(runtimeTypeName(skinInstance));
                const UInt32 vertexHash = complete && !vertices.empty()
                    ? fnv1a32(reinterpret_cast<const UInt8*>(vertices.data()),
                        vertices.size() * sizeof(OracleVector3))
                    : 0;

                gOutput << std::setprecision(9)
                        << "{\"schema\":" << sSchemaJson << ",\"event\":\"actor-geometry\""
                        << ",\"frame\":" << gFrame
                        << ",\"refForm\":" << actor->refID
                        << ",\"baseForm\":" << (actor->baseForm != nullptr ? actor->baseForm->refID : 0)
                        << ",\"name\":" << jsonString(name.empty() ? nullptr : name.c_str())
                        << ",\"parentName\":" << jsonString(parentName.empty() ? nullptr : parentName.c_str())
                        << ",\"runtimeType\":" << jsonString(type.empty() ? nullptr : type.c_str())
                        << ",\"shaderPropertyType\":"
                        << jsonString(shaderType.empty() ? nullptr : shaderType.c_str())
                        << ",\"skinInstanceType\":" << jsonString(skinType.empty() ? nullptr : skinType.c_str())
                        << ",\"depth\":" << depth
                        << ",\"layout\":\"NiGeometryData@0xb8 vertices@data+0x20\""
                        << ",\"geometryDataAddress\":"
                        << static_cast<unsigned long>(reinterpret_cast<std::uintptr_t>(dataAddress))
                        << ",\"verticesAddress\":"
                        << static_cast<unsigned long>(reinterpret_cast<std::uintptr_t>(data.vertices))
                        << ",\"vertexCount\":" << data.vertexCount
                        << ",\"dataFlags\":" << data.dataFlags
                        << ",\"dirtyFlags\":" << data.dirtyFlags
                        << ",\"keepFlags\":" << static_cast<unsigned int>(data.keepFlags)
                        << ",\"compressFlags\":" << static_cast<unsigned int>(data.compressFlags)
                        << ",\"complete\":" << (complete ? "true" : "false")
                        << ",\"fnv1a32\":" << vertexHash
                        << ",\"dataBound\":{\"center\":[" << data.boundCenter.x << ',' << data.boundCenter.y
                        << ',' << data.boundCenter.z << "],\"radius\":" << data.boundRadius << '}'
                        << ",\"measuredBounds\":{\"min\":[" << minimum.x << ',' << minimum.y << ',' << minimum.z
                        << "],\"max\":[" << maximum.x << ',' << maximum.y << ',' << maximum.z << "]}"
                        << ",\"transform\":";
                writeTransform(gOutput, *object);
                gOutput << ",\"vertices\":[";
                for (std::size_t index = 0; index < vertices.size(); ++index)
                {
                    if (index != 0)
                        gOutput << ',';
                    gOutput << '[' << vertices[index].x << ',' << vertices[index].y << ',' << vertices[index].z << ']';
                }
                gOutput << "]}\n";
                ++status.emittedShapes;
                writeActorGeometryNodeStatus(actor, object, depth, type,
                    complete ? "captured" : "vertex-read-incomplete", dataAddress,
                    shaderPointerRead, dataPointerRead, skinPointerRead, &data);
            }
        }

        NiNode* node = object->GetAsNiNode();
        if (node == nullptr || node->m_children.data == nullptr)
            return;
        const unsigned int count
            = (std::min)(static_cast<unsigned int>(node->m_children.firstFreeEntry), 2048u);
        for (unsigned int index = 0; index < count; ++index)
            writeActorGeometryRecursive(actor, node->m_children.data[index], depth + 1, status);
    }

    bool writeActorGeometry(Actor* actor, NiNode* root)
    {
        if (actor == nullptr || root == nullptr)
            return false;
        ActorGeometryCaptureStatus status;
        __try
        {
            writeActorGeometryRecursive(actor, root, 0, status);
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            status.traversalFault = true;
            gOutput << "{\"schema\":" << sSchemaJson << ",\"event\":\"actor-geometry-fault\""
                    << ",\"frame\":" << gFrame
                    << ",\"refForm\":" << actor->refID
                    << ",\"baseForm\":" << (actor->baseForm != nullptr ? actor->baseForm->refID : 0)
                    << ",\"visitedNodes\":" << status.visitedNodes
                    << ",\"geometryCandidates\":" << status.geometryCandidates << "}\n";
        }
        gOutput << "{\"schema\":" << sSchemaJson << ",\"event\":\"actor-geometry-status\""
                << ",\"frame\":" << gFrame
                << ",\"refForm\":" << actor->refID
                << ",\"baseForm\":" << (actor->baseForm != nullptr ? actor->baseForm->refID : 0)
                << ",\"visitedNodes\":" << status.visitedNodes
                << ",\"geometryCandidates\":" << status.geometryCandidates
                << ",\"emittedShapes\":" << status.emittedShapes
                << ",\"pointerReadFailures\":" << status.pointerReadFailures
                << ",\"dataReadFailures\":" << status.dataReadFailures
                << ",\"invalidDataLayouts\":" << status.invalidDataLayouts
                << ",\"vertexReadFailures\":" << status.vertexReadFailures
                << ",\"traversalFault\":" << (status.traversalFault ? "true" : "false") << "}\n";
        gOutput.flush();
        return status.emittedShapes > 0 && !status.traversalFault;
    }

    void writeBoneLodProbe(std::ostream& out, NiBSBoneLODController* controllerAddress)
    {
        if (controllerAddress == nullptr)
        {
            out << "null";
            return;
        }

        NiObject* object = reinterpret_cast<NiObject*>(controllerAddress);
        const std::string type = safeRuntimeString(runtimeTypeName(object));
        OracleTimeController base = {};
        out << "{\"address\":"
            << static_cast<unsigned long>(reinterpret_cast<std::uintptr_t>(controllerAddress))
            << ",\"type\":" << jsonString(type.empty() ? nullptr : type.c_str());
        if (safeRead(controllerAddress, base))
        {
            out << ",\"flags\":" << base.flags
                << ",\"frequency\":" << base.frequency
                << ",\"phaseTime\":" << base.phaseTime
                << ",\"lowKeyTime\":" << base.lowKeyTime
                << ",\"highKeyTime\":" << base.highKeyTime
                << ",\"startTime\":" << base.startTime
                << ",\"lastTime\":" << base.lastTime
                << ",\"weightedLastTime\":" << base.weightedLastTime
                << ",\"scaledTime\":" << base.scaledTime
                << ",\"targetAddress\":"
                << static_cast<unsigned long>(reinterpret_cast<std::uintptr_t>(base.target));
        }

        UInt32 currentLod = 0;
        UInt32 declaredGroupCount = 0;
        safeRead(reinterpret_cast<const UInt8*>(controllerAddress) + 0x34, currentLod);
        safeRead(reinterpret_cast<const UInt8*>(controllerAddress) + 0x38, declaredGroupCount);
        out << ",\"currentLod\":" << currentLod
            << ",\"declaredGroupCount\":" << declaredGroupCount;

        out << ",\"rawWords34ToB0\":[";
        bool first = true;
        for (std::size_t offset = 0x34; offset <= 0xB0; offset += sizeof(UInt32))
        {
            UInt32 word = 0;
            if (!safeRead(reinterpret_cast<const UInt8*>(controllerAddress) + offset, word))
                break;
            if (!first)
                out << ',';
            first = false;
            out << word;
        }
        out << "]}";
    }

    void writeRuntimeVtableProbe(std::ostream& out, const void* objectAddress)
    {
        void** vtable = nullptr;
        if (!safeRead(objectAddress, vtable) || vtable == nullptr)
        {
            out << "null";
            return;
        }

        constexpr unsigned int entryCount = 46;
        out << "{\"address\":" << static_cast<unsigned long>(reinterpret_cast<std::uintptr_t>(vtable))
            << ",\"entries\":[";
        std::uintptr_t entries[entryCount] = {};
        for (unsigned int index = 0; index < entryCount; ++index)
        {
            safeRead(vtable + index, entries[index]);
            if (index != 0)
                out << ',';
            out << static_cast<unsigned long>(entries[index]);
        }
        out << "],\"methodCode\":[";
        bool firstMethod = true;
        for (unsigned int index = 35; index < entryCount; ++index)
        {
            if (entries[index] < 0x00400000 || entries[index] >= 0x01180000)
                continue;
            if (!firstMethod)
                out << ',';
            firstMethod = false;
            out << "{\"index\":" << index
                << ",\"address\":" << static_cast<unsigned long>(entries[index])
                << ",\"bytes\":[";
            for (unsigned int byteIndex = 0; byteIndex < 128; ++byteIndex)
            {
                UInt8 byte = 0;
                if (!safeRead(reinterpret_cast<const UInt8*>(entries[index]) + byteIndex, byte))
                    break;
                if (byteIndex != 0)
                    out << ',';
                out << static_cast<unsigned int>(byte);
            }
            out << "]}";
        }
        out << "]}";
    }

    void writeActorBoneLodGateProbe(std::ostream& out, const Actor* actor)
    {
        void** vtable = nullptr;
        constexpr unsigned int gateVtableIndex = 0xBA;
        std::uintptr_t methodAddress = 0;
        if (!safeRead(actor, vtable) || vtable == nullptr
            || !safeRead(vtable + gateVtableIndex, methodAddress))
        {
            out << "null";
            return;
        }

        out << "{\"vtableAddress\":"
            << static_cast<unsigned long>(reinterpret_cast<std::uintptr_t>(vtable))
            << ",\"index\":" << gateVtableIndex
            << ",\"methodAddress\":" << static_cast<unsigned long>(methodAddress)
            << ",\"bytes\":[";
        for (unsigned int byteIndex = 0; byteIndex < 512; ++byteIndex)
        {
            UInt8 byte = 0;
            if (!safeRead(reinterpret_cast<const UInt8*>(methodAddress) + byteIndex, byte))
                break;
            if (byteIndex != 0)
                out << ',';
            out << static_cast<unsigned int>(byte);
        }
        out << "]}";
    }

    void writeHighProcessVtableProbe(std::ostream& out)
    {
        constexpr std::uintptr_t vtableAddress = 0x01087864;
        constexpr unsigned int entryCount = 16;
        std::uintptr_t entries[entryCount] = {};
        out << "{\"address\":" << static_cast<unsigned long>(vtableAddress) << ",\"entries\":[";
        for (unsigned int index = 0; index < entryCount; ++index)
        {
            safeRead(reinterpret_cast<const std::uintptr_t*>(vtableAddress) + index, entries[index]);
            if (index != 0)
                out << ',';
            out << static_cast<unsigned long>(entries[index]);
        }
        out << "],\"runProcessAddress\":" << static_cast<unsigned long>(entries[3])
            << ",\"runProcessBytes\":[";
        for (unsigned int byteIndex = 0; byteIndex < 4096; ++byteIndex)
        {
            UInt8 byte = 0;
            if (!safeRead(reinterpret_cast<const UInt8*>(entries[3]) + byteIndex, byte))
                break;
            if (byteIndex != 0)
                out << ',';
            out << static_cast<unsigned int>(byte);
        }
        out << "]}";
    }

    void writeRuntimeReferenceProbe(std::ostream& out)
    {
        struct Target
        {
            const char* name;
            UInt32 value;
        };
        constexpr Target targets[] = {
            { "iBoneLODDistMult", 0x011CCF88 },
            { "fActorLODDefault", 0x011DAC38 },
            { "fActorLODMax", 0x011DAAF4 },
            { "fActorLODMin", 0x011DAB1C },
            { "fLODFadeOutMultActors", 0x011C3EC0 },
            { "NiBSBoneLODControllerVtable", 0x010C29CC },
            { "HighProcessBoneLodWriter", 0x008E5730 },
        };

        constexpr std::uintptr_t imageBegin = 0x00400000;
        constexpr std::uintptr_t imageEnd = 0x01180000;
        constexpr std::size_t chunkSize = 0x10000;
        std::vector<UInt8> bytes(chunkSize + sizeof(UInt32));
        std::vector<std::vector<std::uintptr_t>> matches(std::size(targets));
        for (std::uintptr_t chunkBegin = imageBegin; chunkBegin < imageEnd; chunkBegin += chunkSize)
        {
            const std::size_t requested
                = std::min<std::size_t>(bytes.size(), static_cast<std::size_t>(imageEnd - chunkBegin));
            SIZE_T bytesRead = 0;
            if (ReadProcessMemory(GetCurrentProcess(), reinterpret_cast<const void*>(chunkBegin), bytes.data(),
                    requested, &bytesRead)
                    == FALSE
                || bytesRead < sizeof(UInt32))
                continue;

            for (std::size_t offset = 0; offset + sizeof(UInt32) <= bytesRead; ++offset)
            {
                UInt32 value = 0;
                std::memcpy(&value, bytes.data() + offset, sizeof(value));
                for (std::size_t targetIndex = 0; targetIndex < std::size(targets); ++targetIndex)
                {
                    if (value == targets[targetIndex].value && matches[targetIndex].size() < 128)
                        matches[targetIndex].push_back(chunkBegin + offset);
                }
                if ((bytes[offset] == 0xE8 || bytes[offset] == 0xE9)
                    && offset + 5 <= bytesRead)
                {
                    SInt32 displacement = 0;
                    std::memcpy(&displacement, bytes.data() + offset + 1, sizeof(displacement));
                    const std::uintptr_t destination = chunkBegin + offset + 5 + displacement;
                    for (std::size_t targetIndex = 0; targetIndex < std::size(targets); ++targetIndex)
                    {
                        if (destination == targets[targetIndex].value && matches[targetIndex].size() < 128)
                            matches[targetIndex].push_back(chunkBegin + offset);
                    }
                }
            }
        }

        out << '[';
        for (std::size_t targetIndex = 0; targetIndex < std::size(targets); ++targetIndex)
        {
            if (targetIndex != 0)
                out << ',';
            out << "{\"name\":" << jsonString(targets[targetIndex].name)
                << ",\"value\":" << targets[targetIndex].value << ",\"matches\":[";
            for (std::size_t matchIndex = 0; matchIndex < matches[targetIndex].size(); ++matchIndex)
            {
                if (matchIndex != 0)
                    out << ',';
                const std::uintptr_t address = matches[targetIndex][matchIndex];
                const bool isBoneLodWriterReference = targets[targetIndex].value == 0x008E5730;
                const std::uintptr_t contextBefore = isBoneLodWriterReference ? 8192 : 256;
                const unsigned int contextSize = isBoneLodWriterReference ? 16384 : 1024;
                const std::uintptr_t codeBegin
                    = address >= imageBegin + contextBefore ? address - contextBefore : imageBegin;
                out << "{\"address\":" << static_cast<unsigned long>(address) << ",\"codeAddress\":"
                    << static_cast<unsigned long>(codeBegin) << ",\"bytes\":[";
                for (unsigned int byteIndex = 0; byteIndex < contextSize; ++byteIndex)
                {
                    UInt8 byte = 0;
                    if (!safeRead(reinterpret_cast<const UInt8*>(codeBegin) + byteIndex, byte))
                        break;
                    if (byteIndex != 0)
                        out << ',';
                    out << static_cast<unsigned int>(byte);
                }
                out << "]}";
            }
            out << "]}";
        }
        out << ']';
    }

    void writeKnownBoneLodFunctionProbe(std::ostream& out)
    {
        struct Function
        {
            const char* name;
            std::uintptr_t address;
        };
        constexpr Function functions[] = {
            { "HighProcessBoneLodWriter", 0x008E5730 },
            { "GetScale", 0x00567400 },
            { "ActorBoneLodGateState", 0x004F8960 },
            { "AnimDataBoneLodGate", 0x00493830 },
            { "AnimDataBoneLodGateState", 0x008256D0 },
            { "Call45C670", 0x0045C670 },
            { "Call558310", 0x00558310 },
            { "Call43C490", 0x0043C490 },
            { "Call439EF0", 0x00439EF0 },
            { "Call53D280", 0x0053D280 },
            { "VectorLength", 0x00457990 },
            { "Call408840", 0x00408840 },
            { "Call6629F0", 0x006629F0 },
            { "Call508070", 0x00508070 },
            { "GetLodFadeMultiplier", 0x007D1D00 },
            { "BoneLodGroupCount", 0x009E32D0 },
            { "SetBoneLod", 0x00C52960 },
        };
        out << '[';
        for (std::size_t functionIndex = 0; functionIndex < std::size(functions); ++functionIndex)
        {
            if (functionIndex != 0)
                out << ',';
            out << "{\"name\":" << jsonString(functions[functionIndex].name)
                << ",\"address\":" << static_cast<unsigned long>(functions[functionIndex].address)
                << ",\"bytes\":[";
            for (unsigned int byteIndex = 0; byteIndex < 1024; ++byteIndex)
            {
                UInt8 byte = 0;
                if (!safeRead(reinterpret_cast<const UInt8*>(functions[functionIndex].address) + byteIndex, byte))
                    break;
                if (byteIndex != 0)
                    out << ',';
                out << static_cast<unsigned int>(byte);
            }
            out << "]}";
        }
        double distanceConstant = 0.0;
        safeRead(reinterpret_cast<const void*>(0x01035710), distanceConstant);
        out << ",{\"name\":\"distanceConstant\",\"address\":16996112,\"doubleValue\":"
            << distanceConstant << "}]";
    }

    void writeSettingProbe(std::ostream& out, std::uintptr_t address)
    {
        OracleSetting setting = {};
        if (!safeRead(reinterpret_cast<const void*>(address), setting))
        {
            out << "null";
            return;
        }

        float floatValue = 0.f;
        std::memcpy(&floatValue, &setting.rawValue, sizeof(floatValue));
        const std::string name = safeRuntimeString(setting.name);
        out << "{\"address\":" << static_cast<unsigned long>(address)
            << ",\"name\":" << jsonString(name.empty() ? nullptr : name.c_str())
            << ",\"rawValue\":" << setting.rawValue
            << ",\"integerValue\":" << static_cast<SInt32>(setting.rawValue)
            << ",\"floatValue\":" << floatValue << '}';
    }

    // These two fixed addresses are the FalloutNV.exe 1.4.0.525 values in the
    // pinned xNVSE primary source: GameSettings.cpp::g_GameSettingCollection
    // and NiTypes.h::_NiTMap_Lookup, respectively.  The probe is enabled only
    // for that exact runtime version in NVSEPlugin_Load.
    constexpr std::uintptr_t sGameSettingCollectionSingletonAddress = 0x011C8048;
    constexpr std::uintptr_t sGameSettingMapLookupAddress = 0x00853130;

    bool lookupRetailGameSetting(
        GameSettingCollection* collection, const char* editorId, Setting*& setting)
    {
        setting = nullptr;
        if (collection == nullptr || editorId == nullptr || *editorId == '\0')
            return false;
        __try
        {
            using Lookup = bool(__thiscall*)(
                GameSettingCollection::SettingMap*, const char*, Setting**);
            return reinterpret_cast<Lookup>(sGameSettingMapLookupAddress)(
                &collection->settingMap, editorId, &setting) && setting != nullptr;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            setting = nullptr;
            return false;
        }
    }

    UInt32 gameSettingType(const std::string& name)
    {
        if (name.empty())
            return Setting::kSetting_Other;
        switch (name.front())
        {
            case 'b': return Setting::kSetting_Bool;
            case 'c': return Setting::kSetting_c;
            case 'i': return Setting::kSetting_Integer;
            case 'u': return Setting::kSetting_Unsigned;
            case 'f': return Setting::kSetting_Float;
            case 's':
            case 'S': return Setting::kSetting_String;
            case 'r': return Setting::kSetting_r;
            case 'a': return Setting::kSetting_a;
            default: return Setting::kSetting_Other;
        }
    }

    const char* gameSettingTypeName(UInt32 type)
    {
        switch (type)
        {
            case Setting::kSetting_Bool: return "bool";
            case Setting::kSetting_c: return "c";
            case Setting::kSetting_h: return "h";
            case Setting::kSetting_Integer: return "integer";
            case Setting::kSetting_Unsigned: return "unsigned";
            case Setting::kSetting_Float: return "float";
            case Setting::kSetting_String: return "string";
            case Setting::kSetting_r: return "r";
            case Setting::kSetting_a: return "a";
            default: return "other";
        }
    }

    void writeGameSettingRaw(std::ostream& out, UInt32 rawValue)
    {
        std::ostringstream rawHex;
        rawHex << "0x" << std::hex << std::uppercase << std::setw(8)
               << std::setfill('0') << rawValue;
        out << "{\"uint32\":" << rawValue
            << ",\"int32\":" << static_cast<SInt32>(rawValue)
            << ",\"hex\":" << jsonString(rawHex.str().c_str())
            << ",\"bytesLittleEndian\":["
            << (rawValue & 0xff) << ','
            << ((rawValue >> 8) & 0xff) << ','
            << ((rawValue >> 16) & 0xff) << ','
            << ((rawValue >> 24) & 0xff) << "]}";
    }

    void captureRequestedGameSettings()
    {
        if (gGameSettingsCaptured || gGameSettingEditorIds.empty() || !gWorldReady)
            return;
        gGameSettingsCaptured = true;
        openOutput();
        if (!gOutput)
            return;

        GameSettingCollection* collection = nullptr;
        const bool singletonReadable = safeRead(
            reinterpret_cast<const void*>(sGameSettingCollectionSingletonAddress), collection);
        gOutput << "{\"schema\":" << sSchemaJson
                << ",\"event\":\"game-setting-probe-start\""
                << ",\"frame\":" << gFrame
                << ",\"runtime\":\"FalloutNV-1.4.0.525\""
                << ",\"collectionSingletonAddress\":"
                << static_cast<unsigned long>(sGameSettingCollectionSingletonAddress)
                << ",\"mapLookupAddress\":"
                << static_cast<unsigned long>(sGameSettingMapLookupAddress)
                << ",\"singletonReadable\":" << (singletonReadable ? "true" : "false")
                << ",\"collectionResolved\":" << (collection != nullptr ? "true" : "false")
                << ",\"requested\":" << gGameSettingEditorIds.size() << "}\n";

        unsigned int foundCount = 0;
        for (const std::string& requestedEditorId : gGameSettingEditorIds)
        {
            Setting* setting = nullptr;
            const bool found = singletonReadable && collection != nullptr
                && lookupRetailGameSetting(collection, requestedEditorId.c_str(), setting);
            OracleSetting snapshot = {};
            const bool readable = found && safeRead(setting, snapshot);
            const std::string resolvedEditorId
                = readable ? safeRuntimeString(snapshot.name) : std::string();
            const UInt32 type = readable ? gameSettingType(resolvedEditorId)
                                         : Setting::kSetting_Other;
            if (readable)
                ++foundCount;

            gOutput << "{\"schema\":" << sSchemaJson
                    << ",\"event\":\"game-setting\""
                    << ",\"frame\":" << gFrame
                    << ",\"requestedEditorId\":" << jsonString(requestedEditorId.c_str())
                    << ",\"found\":" << (found ? "true" : "false")
                    << ",\"readable\":" << (readable ? "true" : "false");
            if (!readable)
            {
                gOutput << ",\"editorId\":null,\"type\":null,\"typeCode\":null,"
                           "\"raw\":null,\"value\":null}\n";
                continue;
            }

            gOutput << ",\"editorId\":" << jsonString(resolvedEditorId.c_str())
                    << ",\"type\":" << jsonString(gameSettingTypeName(type))
                    << ",\"typeCode\":" << type << ",\"raw\":";
            writeGameSettingRaw(gOutput, snapshot.rawValue);
            gOutput << ",\"value\":";
            switch (type)
            {
                case Setting::kSetting_Bool:
                    gOutput << (snapshot.rawValue != 0 ? "true" : "false");
                    break;
                case Setting::kSetting_Integer:
                    gOutput << static_cast<SInt32>(snapshot.rawValue);
                    break;
                case Setting::kSetting_Unsigned:
                    gOutput << snapshot.rawValue;
                    break;
                case Setting::kSetting_Float:
                {
                    float value = 0.f;
                    std::memcpy(&value, &snapshot.rawValue, sizeof(value));
                    gOutput << std::setprecision((std::numeric_limits<float>::max_digits10));
                    writeFiniteFloat(gOutput, value);
                    break;
                }
                case Setting::kSetting_String:
                {
                    const std::string value = safeRuntimeString(
                        reinterpret_cast<const char*>(snapshot.rawValue), 16384);
                    gOutput << jsonString(value.c_str());
                    break;
                }
                default:
                    gOutput << snapshot.rawValue;
                    break;
            }
            gOutput << "}\n";
        }
        gOutput << "{\"schema\":" << sSchemaJson
                << ",\"event\":\"game-setting-probe-complete\""
                << ",\"frame\":" << gFrame
                << ",\"requested\":" << gGameSettingEditorIds.size()
                << ",\"found\":" << foundCount
                << ",\"missing\":" << (gGameSettingEditorIds.size() - foundCount) << "}\n";
        gOutput.flush();
    }

    void writeSequence(std::ostream& out, const BSAnimGroupSequence* sequence)
    {
        if (sequence == nullptr)
        {
            out << "null";
            return;
        }

        out << "{\"file\":" << jsonString(sequence->filePath)
            << ",\"state\":" << sequence->state
            << ",\"cycle\":" << sequence->cycleType
            << ",\"weight\":" << sequence->weight
            << ",\"frequency\":" << sequence->freq
            << ",\"begin\":" << sequence->begin
            << ",\"end\":" << sequence->end
            << ",\"last\":" << sequence->last
            << ",\"lastScaled\":" << sequence->lastScaled
            << ",\"offset\":" << sequence->offset
            << ",\"start\":" << sequence->start
            << ",\"end2\":" << sequence->end2
            << ",\"accumRoot\":" << jsonString(sequence->accumRoot)
            << ",\"group\":"
            << (sequence->animGroup != nullptr ? static_cast<unsigned int>(sequence->animGroup->animGroup) : 0xffff)
            << ",\"controlledBlockCount\":" << sequence->arraySize << ",\"controlledBlocks\":";
        writeControlledBlockProbe(out, sequence);
        out << '}';
    }

    void observeFurnitureLifecycle(
        Actor* actor, UInt32 actorSitSleepState, UInt8 processSitSleepState, UInt32 usedFurnitureRefForm)
    {
        const bool furnitureSettled = usedFurnitureRefForm != 0
            && (actorSitSleepState == 4 || processSitSleepState == 4);
        if (furnitureSettled)
        {
            gFurnitureClaimObserved = true;
            gFurnitureReleaseStableSamples = 0;
            ++gFurnitureSettledStableSamples;
            if (!gFurnitureSettledCommandsRun && !gFurnitureSettledCommands.empty())
            {
                gFurnitureSettledCommandsRun = true;
                gOutput << "{\"schema\":" << sSchemaJson
                        << ",\"event\":\"furniture-settled-commands\""
                        << ",\"frame\":" << gFrame
                        << ",\"refForm\":" << actor->refID << ",\"commands\":[";
                for (std::size_t i = 0; i < gFurnitureSettledCommands.size(); ++i)
                {
                    if (i != 0)
                        gOutput << ',';
                    const bool accepted = gConsole != nullptr
                        && gConsole->RunScriptLine2(gFurnitureSettledCommands[i].c_str(), nullptr, true);
                    gOutput << "{\"text\":" << jsonString(gFurnitureSettledCommands[i].c_str())
                            << ",\"accepted\":" << (accepted ? "true" : "false") << '}';
                }
                gOutput << "]}\n";
            }
        }
        else if (gFurnitureClaimObserved && usedFurnitureRefForm == 0
            && actorSitSleepState == 0 && processSitSleepState == 0)
        {
            gFurnitureSettledStableSamples = 0;
            ++gFurnitureReleaseStableSamples;
            if (gFurnitureReleaseStableSamples >= gFurnitureReleaseSamples)
                gFurnitureLifecycleComplete = true;
        }
        else
        {
            gFurnitureSettledStableSamples = 0;
            gFurnitureReleaseStableSamples = 0;
        }
    }

    void writeFurnitureActor(Actor* actor)
    {
        __try
        {
            BaseProcess* process = actor->baseProcess;
            const bool middleHigh = process != nullptr && process->processLevel <= 1;
            UInt8 processSitSleepState = 0;
            UInt32 actorSitSleepState = 0;
            TESObjectREFR* usedFurniture = nullptr;
            UInt8 furnitureMarkerIndex = 0xff;
            OracleFurnitureMark furnitureMark = {};
            UInt32 usedFurnitureRefForm = 0;
            UInt32 usedFurnitureBaseForm = 0;
            bool hasFurnitureProcessState = false;
            bool hasFurnitureMark = false;
            safeRead(reinterpret_cast<const UInt8*>(actor) + 0x1AC, actorSitSleepState);
            if (middleHigh)
            {
                const UInt8* processBytes = reinterpret_cast<const UInt8*>(process);
                hasFurnitureProcessState = safeRead(processBytes + 0x13D, processSitSleepState)
                    && safeRead(processBytes + 0x140, usedFurniture)
                    && safeRead(processBytes + 0x144, furnitureMarkerIndex);
                hasFurnitureMark = safeRead(processBytes + 0x148, furnitureMark);
                if (usedFurniture != nullptr)
                {
                    safeRead(reinterpret_cast<const UInt8*>(usedFurniture) + 0x0C, usedFurnitureRefForm);
                    TESForm* usedFurnitureBase = nullptr;
                    if (safeRead(reinterpret_cast<const UInt8*>(usedFurniture) + 0x20, usedFurnitureBase)
                        && usedFurnitureBase != nullptr)
                        safeRead(reinterpret_cast<const UInt8*>(usedFurnitureBase) + 0x0C, usedFurnitureBaseForm);
                }
            }

            observeFurnitureLifecycle(actor, actorSitSleepState, processSitSleepState, usedFurnitureRefForm);
            gOutput << std::setprecision(9)
                    << "{\"schema\":" << sSchemaJson << ",\"event\":\"actor-frame\""
                    << ",\"frame\":" << gFrame
                    << ",\"refForm\":" << actor->refID
                    << ",\"baseForm\":" << (actor->baseForm != nullptr ? actor->baseForm->refID : 0)
                    << ",\"position\":[" << actor->posX << ',' << actor->posY << ',' << actor->posZ << ']'
                    << ",\"rotation\":[" << actor->rotX << ',' << actor->rotY << ',' << actor->rotZ << ']'
                    << ",\"processLevel\":" << (process != nullptr ? process->processLevel : 0xff)
                    << ",\"furnitureState\":{\"available\":"
                    << (hasFurnitureProcessState ? "true" : "false")
                    << ",\"actorSitSleepState\":" << actorSitSleepState
                    << ",\"processSitSleepState\":" << static_cast<unsigned int>(processSitSleepState)
                    << ",\"usedFurnitureRefForm\":" << usedFurnitureRefForm
                    << ",\"usedFurnitureBaseForm\":" << usedFurnitureBaseForm
                    << ",\"markerIndex\":" << static_cast<unsigned int>(furnitureMarkerIndex)
                    << ",\"marker\":";
            if (hasFurnitureMark)
            {
                gOutput << "{\"position\":[" << furnitureMark.position.x << ',' << furnitureMark.position.y << ','
                        << furnitureMark.position.z << ']'
                        << ",\"rotationRaw\":" << furnitureMark.rotation
                        << ",\"rotationRadians\":" << static_cast<float>(furnitureMark.rotation) / 1000.f
                        << ",\"type\":" << static_cast<unsigned int>(furnitureMark.type)
                        << ",\"unknown0F\":" << static_cast<unsigned int>(furnitureMark.unknown0F) << '}';
            }
            else
                gOutput << "null";
            gOutput << "}}\n";
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            gOutput << "{\"schema\":" << sSchemaJson << ",\"event\":\"furniture-capture-fault\""
                    << ",\"frame\":" << gFrame << ",\"refForm\":" << actor->refID << "}\n";
        }
    }

    void writeActor(Actor* actor)
    {
        if (actor == nullptr || actor->baseProcess == nullptr)
            return;
        if (gTargetForm != 0 && actor->refID != gTargetForm && (actor->baseForm == nullptr || actor->baseForm->refID != gTargetForm))
            return;
        if (gFurnitureOnly)
        {
            writeFurnitureActor(actor);
            return;
        }

        __try
        {
            BaseProcess* process = actor->baseProcess;
            const bool middleHigh = process->processLevel <= 1;
            MiddleHighProcess* mhp = middleHigh ? static_cast<MiddleHighProcess*>(process) : nullptr;
            HighProcess* hp = process->processLevel == 0 ? static_cast<HighProcess*>(process) : nullptr;
            TESObjectWEAP* weapon = mhp != nullptr && mhp->weaponInfo != nullptr ? mhp->weaponInfo->weapon : nullptr;
            NiNode* root = actor->GetNiNode();
            if (root != nullptr && gActorGeometryLogged.find(actor->refID) == gActorGeometryLogged.end()
                && writeActorGeometry(actor, root))
                gActorGeometryLogged.insert(actor->refID);
            PlayerCharacter* player = *reinterpret_cast<PlayerCharacter**>(0x011DEA3C);
            OracleVector3 cameraPos3rdPerson = {};
            OracleVector3 cameraPos = {};
            const bool hasCameraPos3rdPerson = player != nullptr
                && safeRead(reinterpret_cast<const UInt8*>(player) + 0xD58, cameraPos3rdPerson);
            const bool hasCameraPos = player != nullptr
                && safeRead(reinterpret_cast<const UInt8*>(player) + 0xDE0, cameraPos);
            float cameraDistance = 0.f;
            float actorScale = 1.f;
            float cameraLodAdjust = 1.f;
            float actorFadeMultiplier = 1.f;
            SInt32 boneLodDistanceMultiplier = 0;
            UInt8 processSitSleepState = 0;
            UInt32 actorSitSleepState = 0;
            TESObjectREFR* usedFurniture = nullptr;
            UInt8 furnitureMarkerIndex = 0xff;
            OracleFurnitureMark furnitureMark = {};
            UInt32 usedFurnitureRefForm = 0;
            UInt32 usedFurnitureBaseForm = 0;
            bool hasFurnitureProcessState = false;
            bool hasFurnitureMark = false;
            safeRead(reinterpret_cast<const UInt8*>(actor) + 0x1AC, actorSitSleepState);
            if (middleHigh)
            {
                const UInt8* processBytes = reinterpret_cast<const UInt8*>(process);
                hasFurnitureProcessState = safeRead(processBytes + 0x13D, processSitSleepState)
                    && safeRead(processBytes + 0x140, usedFurniture)
                    && safeRead(processBytes + 0x144, furnitureMarkerIndex);
                hasFurnitureMark = safeRead(processBytes + 0x148, furnitureMark);
                if (usedFurniture != nullptr)
                {
                    safeRead(reinterpret_cast<const UInt8*>(usedFurniture) + 0x0C, usedFurnitureRefForm);
                    TESForm* usedFurnitureBase = nullptr;
                    if (safeRead(reinterpret_cast<const UInt8*>(usedFurniture) + 0x20, usedFurnitureBase)
                        && usedFurnitureBase != nullptr)
                        safeRead(reinterpret_cast<const UInt8*>(usedFurnitureBase) + 0x0C, usedFurnitureBaseForm);
                }
            }
            observeFurnitureLifecycle(actor, actorSitSleepState, processSitSleepState, usedFurnitureRefForm);
            if (hasCameraPos)
            {
                const float dx = actor->posX - cameraPos.x;
                const float dy = actor->posY - cameraPos.y;
                const float dz = actor->posZ - cameraPos.z;
                cameraDistance = std::sqrt(dx * dx + dy * dy + dz * dz);
            }
            actorScale = reinterpret_cast<float(__thiscall*)(Actor*)>(0x00567400)(actor);
            void* sceneGraphOwner = reinterpret_cast<void*(__cdecl*)()>(0x0045C670)();
            void* sceneCamera = sceneGraphOwner != nullptr
                ? reinterpret_cast<void*(__thiscall*)(void*)>(0x006629F0)(sceneGraphOwner)
                : nullptr;
            NiFrustum sceneCameraFrustum = {};
            NiViewport sceneCameraViewport = {};
            float sceneCameraMinNearPlaneDistance = 0.f;
            float sceneCameraMaxFarNearRatio = 0.f;
            const bool hasSceneCameraProjection = sceneCamera != nullptr
                && safeRead(reinterpret_cast<const UInt8*>(sceneCamera) + 0xEC, sceneCameraFrustum)
                && safeRead(reinterpret_cast<const UInt8*>(sceneCamera) + 0x108, sceneCameraMinNearPlaneDistance)
                && safeRead(reinterpret_cast<const UInt8*>(sceneCamera) + 0x10C, sceneCameraMaxFarNearRatio)
                && safeRead(reinterpret_cast<const UInt8*>(sceneCamera) + 0x110, sceneCameraViewport);
            if (sceneCamera != nullptr)
                cameraLodAdjust = reinterpret_cast<float(__thiscall*)(void*)>(0x00508070)(sceneCamera);
            safeRead(reinterpret_cast<const void*>(0x011AD7C4), actorFadeMultiplier);
            OracleSetting boneLodDistanceSetting = {};
            if (safeRead(reinterpret_cast<const void*>(0x011CCF88), boneLodDistanceSetting))
                boneLodDistanceMultiplier = static_cast<SInt32>(boneLodDistanceSetting.rawValue);
            const double boneLodQuotient = actorScale > 0.f && boneLodDistanceMultiplier > 0
                && actorFadeMultiplier > 0.f
                ? (static_cast<double>(cameraDistance) / actorScale) * 12.0 * cameraLodAdjust
                    / (boneLodDistanceMultiplier * actorFadeMultiplier)
                : -1.0;

            gOutput << std::setprecision(9)
                << "{\"schema\":" << sSchemaJson << ",\"event\":\"actor-frame\""
                << ",\"frame\":" << gFrame
                << ",\"refForm\":" << actor->refID
                << ",\"baseForm\":" << (actor->baseForm != nullptr ? actor->baseForm->refID : 0)
                << ",\"position\":[" << actor->posX << ',' << actor->posY << ',' << actor->posZ << ']'
                << ",\"rotation\":[" << actor->rotX << ',' << actor->rotY << ',' << actor->rotZ << ']'
                << ",\"cameraPos3rdPerson\":";
            if (hasCameraPos3rdPerson)
                gOutput << '[' << cameraPos3rdPerson.x << ',' << cameraPos3rdPerson.y << ',' << cameraPos3rdPerson.z << ']';
            else
                gOutput << "null";
            gOutput << ",\"cameraPos\":";
            if (hasCameraPos)
            {
                gOutput << '[' << cameraPos.x << ',' << cameraPos.y << ',' << cameraPos.z << ']'
                    << ",\"cameraDistance\":" << cameraDistance;
            }
            else
                gOutput << "null,\"cameraDistance\":null";
            gOutput
                << ",\"sceneCameraProjection\":";
            if (hasSceneCameraProjection)
            {
                gOutput << "{\"frustum\":[" << sceneCameraFrustum.l << ',' << sceneCameraFrustum.r << ','
                        << sceneCameraFrustum.t << ',' << sceneCameraFrustum.b << ',' << sceneCameraFrustum.n << ','
                        << sceneCameraFrustum.f << ']'
                        << ",\"orthographic\":" << (sceneCameraFrustum.o != 0 ? "true" : "false")
                        << ",\"minNearPlaneDistance\":" << sceneCameraMinNearPlaneDistance
                        << ",\"maxFarNearRatio\":" << sceneCameraMaxFarNearRatio
                        << ",\"viewport\":[" << sceneCameraViewport.l << ',' << sceneCameraViewport.r << ','
                        << sceneCameraViewport.t << ',' << sceneCameraViewport.b << "]}";
            }
            else
                gOutput << "null";
            gOutput
                << ",\"boneLodInputs\":{\"actorScale\":" << actorScale
                << ",\"cameraLodAdjust\":" << cameraLodAdjust
                << ",\"distanceConstant\":12"
                << ",\"distanceMultiplier\":" << boneLodDistanceMultiplier
                << ",\"actorFadeMultiplier\":" << actorFadeMultiplier
                << ",\"quotient\":" << boneLodQuotient
                << ",\"predictedLod\":"
                << (boneLodQuotient >= 0.0 ? static_cast<SInt32>(std::floor(boneLodQuotient)) : -1) << '}'
                << ",\"actorBoneLodGate\":";
            writeActorBoneLodGateProbe(gOutput, actor);
            gOutput
                << ",\"actorLifeState\":" << actor->lifeState
                << ",\"processLevel\":" << process->processLevel
                << ",\"footIkAvailable\":"
                << (actor->ragDollController != nullptr && actor->ragDollController->bool021F ? "true" : "false")
                << ",\"footIkEnabled\":"
                << (actor->ragDollController != nullptr && actor->ragDollController->fikStatus ? "true" : "false")
                << ",\"weaponOut\":" << (mhp != nullptr && mhp->isWeaponOut ? "true" : "false")
                << ",\"aiming\":" << (mhp != nullptr && mhp->isAiming ? "true" : "false")
                << ",\"furnitureState\":{"
                << "\"available\":" << (hasFurnitureProcessState ? "true" : "false")
                << ",\"actorSitSleepState\":" << actorSitSleepState
                << ",\"processSitSleepState\":" << static_cast<unsigned int>(processSitSleepState)
                << ",\"usedFurnitureRefForm\":" << usedFurnitureRefForm
                << ",\"usedFurnitureBaseForm\":" << usedFurnitureBaseForm
                << ",\"markerIndex\":" << static_cast<unsigned int>(furnitureMarkerIndex)
                << ",\"marker\":";
            if (hasFurnitureMark)
            {
                gOutput << "{\"position\":[" << furnitureMark.position.x << ',' << furnitureMark.position.y << ','
                        << furnitureMark.position.z << ']'
                        << ",\"rotationRaw\":" << furnitureMark.rotation
                        << ",\"rotationRadians\":" << static_cast<float>(furnitureMark.rotation) / 1000.f
                        << ",\"type\":" << static_cast<unsigned int>(furnitureMark.type)
                        << ",\"unknown0F\":" << static_cast<unsigned int>(furnitureMark.unknown0F) << '}';
            }
            else
                gOutput << "null";
            gOutput << '}';
            gOutput << ",\"highProcessBoneLodState\":";
            if (hp != nullptr)
            {
                gOutput << "{\"cachedLod\":" << static_cast<SInt32>(hp->unk2E8)
                    << ",\"fadeType\":" << hp->fadeType
                    << ",\"delayTime\":" << hp->delayTime
                    << ",\"alpha\":" << hp->alpha << '}';
            }
            else
                gOutput << "null";
            gOutput << ",\"weapon\":";
            if (weapon != nullptr)
            {
                gOutput << "{\"form\":" << weapon->refID
                    << ",\"animationType\":" << static_cast<unsigned int>(weapon->eWeaponType)
                    << ",\"handGripRaw\":" << static_cast<unsigned int>(weapon->handGrip)
                    << ",\"handGripIndex\":" << handGripIndex(weapon->handGrip)
                    << ",\"reloadAnimation\":" << static_cast<unsigned int>(weapon->reloadAnim)
                    << ",\"attackAnimationRaw\":" << static_cast<unsigned int>(weapon->attackAnim)
                    << ",\"attackAnimationIndex\":" << attackAnimationIndex(weapon->attackAnim)
                    << '}';
            }
            else
                gOutput << "null";

            gOutput << ",\"boneLodController\":";
            writeBoneLodProbe(gOutput, hp != nullptr ? hp->ptr2E4 : nullptr);
            gOutput << ",\"boneLodVtable\":";
            writeRuntimeVtableProbe(gOutput, hp != nullptr ? hp->ptr2E4 : nullptr);
            gOutput << ",\"highProcessVtable\":";
            if (!gBoneLodCodeReferencesWritten)
                writeHighProcessVtableProbe(gOutput);
            else
                gOutput << "null";
            gOutput << ",\"boneLodCodeReferences\":";
            if (!gBoneLodCodeReferencesWritten)
            {
                writeRuntimeReferenceProbe(gOutput);
                gOutput << ",\"boneLodFunctionCode\":";
                writeKnownBoneLodFunctionProbe(gOutput);
                gBoneLodCodeReferencesWritten = true;
            }
            else
            {
                gOutput << "null";
                gOutput << ",\"boneLodFunctionCode\":null";
            }
            gOutput << ",\"lodSettings\":[";
            constexpr std::uintptr_t lodSettingAddresses[] = {
                0x011CCF88, // iBoneLODDistMult
                0x011DAC38, // fActorLODDefault:LOD
                0x011DAAF4, // fActorLODMax:LOD
                0x011DAB1C, // fActorLODMin:LOD
                0x011C3EC0, // fLODFadeOutMultActors:LOD
            };
            for (std::size_t settingIndex = 0; settingIndex < std::size(lodSettingAddresses); ++settingIndex)
            {
                if (settingIndex != 0)
                    gOutput << ',';
                writeSettingProbe(gOutput, lodSettingAddresses[settingIndex]);
            }
            gOutput << ']';

            gOutput << ",\"middleHighSequences\":[";
            for (unsigned int i = 0; i < 3; ++i)
            {
                if (i != 0)
                    gOutput << ',';
                writeSequence(gOutput, mhp != nullptr ? mhp->animSequence[i] : nullptr);
            }
            gOutput << "] ,\"animDataSequences\":[";
            for (unsigned int i = 0; i < 8; ++i)
            {
                if (i != 0)
                    gOutput << ',';
                writeSequence(gOutput, hp != nullptr && hp->animData != nullptr ? hp->animData->animSequence[i] : nullptr);
            }
            gOutput << "] ,\"weaponNode\":";
            NiNode* weaponNode = mhp != nullptr ? mhp->weaponNode : nullptr;
            if (weaponNode != nullptr)
                writeTransform(gOutput, *weaponNode);
            else
                gOutput << "null";

            gOutput << ",\"rootWorldActorDelta\":";
            if (root != nullptr)
            {
                const NiVector3& rootWorld
                    = runtimeTransform(*root, sNiAVObjectWorldTransformOffset).translate;
                const NiVector3 delta{ rootWorld.x - actor->posX, rootWorld.y - actor->posY,
                    rootWorld.z - actor->posZ };
                writeVector(gOutput, delta);
            }
            else
                gOutput << "null";

            gOutput << ",\"bones\":[";
            bool firstBone = true;
            writeNodeRecursive(gOutput, root, firstBone, 0);
            gOutput << "]}\n";
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            gOutput << "{\"schema\":" << sSchemaJson << ",\"event\":\"capture-fault\","
                       "\"frame\":" << gFrame << ",\"refForm\":" << actor->refID << "}\n";
        }
    }

    TESForm* lookupForm(UInt32 formId)
    {
        auto** formsMap = reinterpret_cast<NiTPointerMap<TESForm>**>(0x011C54C0);
        return formsMap != nullptr && *formsMap != nullptr ? (*formsMap)->Lookup(formId) : nullptr;
    }

    void writeImageSpaceInstance(const UInt8* instance)
    {
        if (instance == nullptr)
        {
            gOutput << "null";
            return;
        }
        const TESForm* imageSpace = *reinterpret_cast<TESForm* const*>(instance + 0x1C);
        const TESForm* previousImageSpace = *reinterpret_cast<TESForm* const*>(instance + 0x20);
        gOutput << "{\"form\":" << (imageSpace != nullptr ? imageSpace->refID : 0)
                << ",\"previousForm\":" << (previousImageSpace != nullptr ? previousImageSpace->refID : 0)
                << ",\"hidden\":" << (*reinterpret_cast<const UInt8*>(instance + 0x08) != 0 ? "true" : "false")
                << ",\"percent\":" << *reinterpret_cast<const float*>(instance + 0x0C)
                << ",\"age\":" << *reinterpret_cast<const float*>(instance + 0x14)
                << ",\"flags\":" << *reinterpret_cast<const UInt32*>(instance + 0x18)
                << ",\"lastStrength\":" << *reinterpret_cast<const float*>(instance + 0x24)
                << ",\"transitionTime\":" << *reinterpret_cast<const float*>(instance + 0x2C) << '}';
    }

    void captureRetailRenderEnvironment()
    {
        if (gRenderEnvironmentLogged)
            return;

        // JIP LN NVSE's public FalloutNV 1.4.0.525 Sky layout maps the singleton
        // at 0x11DEA20, weather pointers at 0x10..0x1C, runtime light colors at
        // 0x60/0x6C, and the time/transition fields at 0xEC..0xF8. Record the
        // resolved runtime values instead of inferring color from the save or ESM.
        __try
        {
            const UInt8* sky = *reinterpret_cast<const UInt8**>(0x011DEA20);
            if (sky == nullptr)
                return;
            const TESWeather* current = *reinterpret_cast<TESWeather* const*>(sky + 0x10);
            const TESWeather* previous = *reinterpret_cast<TESWeather* const*>(sky + 0x14);
            const TESWeather* fallback = *reinterpret_cast<TESWeather* const*>(sky + 0x18);
            const TESWeather* overrideWeather = *reinterpret_cast<TESWeather* const*>(sky + 0x1C);
            const float* ambient = reinterpret_cast<const float*>(sky + 0x60);
            const float* directional = reinterpret_cast<const float*>(sky + 0x6C);
            const float* fog = reinterpret_cast<const float*>(sky + 0xC0);
            const float gameHour = *reinterpret_cast<const float*>(sky + 0xEC);
            const float lastUpdateHour = *reinterpret_cast<const float*>(sky + 0xF0);
            const float transition = *reinterpret_cast<const float*>(sky + 0xF4);
            const UInt32 skyMode = *reinterpret_cast<const UInt32*>(sky + 0xF8);
            const UInt32 flags = *reinterpret_cast<const UInt32*>(sky + 0x118);
            const PlayerCharacter* player = *reinterpret_cast<PlayerCharacter* const*>(0x011DEA3C);
            const TESObjectCELL* cell = player != nullptr ? player->parentCell : nullptr;
            const TESWorldSpace* world = cell != nullptr ? cell->worldSpace : nullptr;
            const TESImageSpace* baseImageSpace = world != nullptr ? world->imageSpace : nullptr;
            gRenderEnvironmentLogged = true;
            gOutput << std::setprecision(9)
                    << "{\"schema\":" << sSchemaJson << ",\"event\":\"render-environment\""
                    << ",\"frame\":" << gFrame
                    << ",\"currentWeatherForm\":" << (current != nullptr ? current->refID : 0)
                    << ",\"previousWeatherForm\":" << (previous != nullptr ? previous->refID : 0)
                    << ",\"defaultWeatherForm\":" << (fallback != nullptr ? fallback->refID : 0)
                    << ",\"overrideWeatherForm\":" << (overrideWeather != nullptr ? overrideWeather->refID : 0)
                    << ",\"gameHour\":" << gameHour
                    << ",\"lastUpdateHour\":" << lastUpdateHour
                    << ",\"weatherPercent\":" << transition
                    << ",\"skyMode\":" << skyMode
                    << ",\"flags\":" << flags
                    << ",\"weatherImageSpace\":{\"currentFadeIn\":";
            writeImageSpaceInstance(*reinterpret_cast<const UInt8* const*>(sky + 0x11C));
            gOutput << ",\"currentFadeOut\":";
            writeImageSpaceInstance(*reinterpret_cast<const UInt8* const*>(sky + 0x120));
            gOutput << ",\"transitionFadeIn\":";
            writeImageSpaceInstance(*reinterpret_cast<const UInt8* const*>(sky + 0x124));
            gOutput << ",\"transitionFadeOut\":";
            writeImageSpaceInstance(*reinterpret_cast<const UInt8* const*>(sky + 0x128));
            gOutput << '}'
                    << ",\"baseImageSpace\":";
            if (baseImageSpace != nullptr)
            {
                gOutput << "{\"form\":" << baseImageSpace->refID << ",\"traits\":[";
                const float* traits = reinterpret_cast<const float*>(
                    reinterpret_cast<const UInt8*>(baseImageSpace) + 0x18);
                for (unsigned int trait = 0; trait < 33; ++trait)
                {
                    if (trait != 0)
                        gOutput << ',';
                    gOutput << traits[trait];
                }
                gOutput << "]}";
            }
            else
                gOutput << "null";
            gOutput
                    << ",\"sunAmbient\":[" << ambient[0] << ',' << ambient[1] << ',' << ambient[2] << ']'
                    << ",\"sunDirectional\":[" << directional[0] << ',' << directional[1] << ','
                    << directional[2] << ']'
                    << ",\"sunFog\":[" << fog[0] << ',' << fog[1] << ',' << fog[2] << "]}\n";
            gOutput.flush();
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            gOutput << "{\"schema\":" << sSchemaJson << ",\"event\":\"render-environment-fault\""
                    << ",\"frame\":" << gFrame << "}\n";
            gOutput.flush();
        }
    }

    void writeQuestState(UInt32 formId)
    {
        TESForm* form = lookupForm(formId);
        if (form == nullptr || form->typeID != kFormType_TESQuest)
        {
            gOutput << "{\"form\":" << formId << ",\"available\":false}";
            return;
        }

        TESQuest* quest = static_cast<TESQuest*>(form);
        gOutput << "{\"form\":" << formId
            << ",\"available\":true"
            << ",\"editorId\":" << jsonString(quest->editorName.m_data)
            << ",\"flags\":" << static_cast<unsigned int>(quest->flags)
            << ",\"running\":" << ((quest->flags & 0x01) != 0 ? "true" : "false")
            << ",\"completed\":" << ((quest->flags & 0x02) != 0 ? "true" : "false")
            << ",\"shownInPipBoy\":" << ((quest->flags & 0x20) != 0 ? "true" : "false")
            << ",\"failed\":" << ((quest->flags & 0x40) != 0 ? "true" : "false")
            << ",\"priority\":" << static_cast<unsigned int>(quest->priority)
            << ",\"delay\":" << quest->questDelayTime
            << ",\"currentStage\":" << static_cast<unsigned int>(quest->currentStage)
            << ",\"stages\":[";

        bool first = true;
        for (auto* node = quest->stages.Head(); node != nullptr; node = node->next)
        {
            if (node->data == nullptr)
                continue;
            if (!first)
                gOutput << ',';
            first = false;
            gOutput << "{\"index\":" << static_cast<unsigned int>(node->data->stage)
                << ",\"done\":" << (node->data->isDone != 0 ? "true" : "false") << '}';
        }
        gOutput << "]}";
    }

    void writeGlobalState(UInt32 formId)
    {
        TESForm* form = lookupForm(formId);
        if (form == nullptr || form->typeID != kFormType_TESGlobal)
        {
            gOutput << "{\"form\":" << formId << ",\"available\":false}";
            return;
        }

        TESGlobal* global = static_cast<TESGlobal*>(form);
        gOutput << "{\"form\":" << formId
            << ",\"available\":true"
            << ",\"editorId\":" << jsonString(global->name.m_data)
            << ",\"type\":" << static_cast<unsigned int>(global->type)
            << ",\"value\":" << global->data << '}';
    }

    void captureBehaviorSnapshot(const char* label)
    {
        if (gQuestForms.empty() && gGlobalForms.empty())
            return;

        __try
        {
            gOutput << std::setprecision(9)
                << "{\"schema\":" << sSchemaJson
                << ",\"event\":\"behavior-snapshot\""
                << ",\"label\":\"" << label << '"'
                << ",\"frame\":" << gFrame
                << ",\"quests\":[";
            for (std::size_t i = 0; i < gQuestForms.size(); ++i)
            {
                if (i != 0)
                    gOutput << ',';
                writeQuestState(gQuestForms[i]);
            }
            gOutput << "],\"globals\":[";
            for (std::size_t i = 0; i < gGlobalForms.size(); ++i)
            {
                if (i != 0)
                    gOutput << ',';
                writeGlobalState(gGlobalForms[i]);
            }
            gOutput << "]}\n";
            gOutput.flush();
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            gOutput << "{\"schema\":" << sSchemaJson
                << ",\"event\":\"behavior-capture-fault\""
                << ",\"label\":\"" << label << '"'
                << ",\"frame\":" << gFrame << "}\n";
            gOutput.flush();
        }
    }

    bool invokeRetailSetStage(TESQuest* quest, UInt8 stage)
    {
        __try
        {
            using SetStage = bool(__thiscall*)(TESQuest*, UInt8);
            return reinterpret_cast<SetStage>(0x0060D510)(quest, stage);
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            return false;
        }
    }

    void runBehaviorCommands()
    {
        if (gBehaviorCommandsRun || gConsole == nullptr)
            return;
        gBehaviorCommandsRun = true;
        gOutput << "{\"schema\":" << jsonString(sSchema)
            << ",\"event\":\"behavior-commands\""
            << ",\"frame\":" << gFrame << ",\"commands\":[";
        for (std::size_t i = 0; i < gBehaviorCommands.size(); ++i)
        {
            const std::string& command = gBehaviorCommands[i];
            const bool safe = command.find('\n') == std::string::npos && command.find('\r') == std::string::npos;
            const bool accepted = safe && gConsole->RunScriptLine2(command.c_str(), nullptr, true);
            if (i != 0)
                gOutput << ',';
            gOutput << "{\"text\":" << jsonString(command.c_str())
                << ",\"accepted\":" << (accepted ? "true" : "false") << '}';
        }
        gOutput << ']';

        bool setStageAvailable = false;
        bool setStageResult = false;
        if (gSetStageQuestForm != 0 && gSetStageIndex <= 0xff)
        {
            TESForm* form = lookupForm(gSetStageQuestForm);
            setStageAvailable = form != nullptr && form->typeID == kFormType_TESQuest;
            if (setStageAvailable)
                setStageResult = invokeRetailSetStage(
                    static_cast<TESQuest*>(form), static_cast<UInt8>(gSetStageIndex));
        }
        gOutput << ",\"setStage\":{"
            << "\"questForm\":" << gSetStageQuestForm
            << ",\"stage\":" << gSetStageIndex
            << ",\"available\":" << (setStageAvailable ? "true" : "false")
            << ",\"result\":" << (setStageResult ? "true" : "false") << "}}\n";
        gOutput.flush();
    }

    Actor* findDriveActor()
    {
        if (gTargetForm != 0)
        {
            TESForm* target = lookupForm(gTargetForm);
            Actor* targetActor
                = target != nullptr && target->IsActor_Runtime() ? static_cast<Actor*>(target) : nullptr;
            if (targetActor != nullptr && targetActor->baseProcess != nullptr
                && (gFurnitureOnly || targetActor->GetNiNode() != nullptr))
                return targetActor;
        }

        PlayerCharacter* player = *reinterpret_cast<PlayerCharacter**>(0x011DEA3C);
        Actor* fallback = nullptr;
        ActorProcessManager* manager = reinterpret_cast<ActorProcessManager*>(0x011E0E80);
        for (auto* node = manager->highActors.Head(); node != nullptr; node = node->next)
        {
            Actor* actor = node->data;
            if (actor == nullptr || actor == player || actor->baseProcess == nullptr
                || (!gFurnitureOnly && actor->GetNiNode() == nullptr))
                continue;
            if (gTargetForm != 0 && actor->refID != gTargetForm
                && (actor->baseForm == nullptr || actor->baseForm->refID != gTargetForm))
                continue;
            if (fallback == nullptr)
                fallback = actor;
            if (actor->baseProcess->processLevel <= 1)
            {
                MiddleHighProcess* process = static_cast<MiddleHighProcess*>(actor->baseProcess);
                if (process->weaponInfo != nullptr && process->weaponInfo->weapon != nullptr)
                    return actor;
            }
        }
        if (fallback != nullptr)
            return fallback;
        if (gTargetForm == 0 || (player != nullptr
            && (player->refID == gTargetForm || (player->baseForm != nullptr && player->baseForm->refID == gTargetForm))))
            return player;
        return nullptr;
    }

    struct NpcAppearanceSnapshot
    {
        bool npc;
        bool female;
        UInt8 baseType;
        UInt32 refForm;
        UInt32 baseForm;
        UInt32 raceForm;
        UInt32 raceFieldForm;
        UInt32 runtimeRaceForm;
        UInt32 hairForm;
        UInt32 eyesForm;
        UInt32 copyFromForm;
        float hairLength;
        UInt8 hairColor[4];
        const char* hairModel;
        const char* eyeTexture;
        struct HeadPart
        {
            UInt32 form;
            const char* model;
        } headParts[32];
        unsigned int headPartCount;
        struct FaceGenChannel
        {
            UInt32 count;
            UInt32 size;
            bool hasValues;
        } faceGenChannels[3];
        struct RaceFaceSlot
        {
            const char* model;
            const char* texture;
        } raceFaceSlots[8];
        unsigned int raceFaceSlotCount;
    };

    bool readNpcAppearanceUnsafe(Actor* actor, NpcAppearanceSnapshot& result)
    {
        __try
        {
            TESForm* base = actor->baseForm;
            result.refForm = actor->refID;
            result.baseForm = base->refID;
            result.baseType = base->typeID;
            result.npc = base->typeID == kFormType_TESNPC;
            if (!result.npc)
                return true;

            TESNPC* npc = static_cast<TESNPC*>(base);
            TESRace* race = npc->race.race != nullptr ? npc->race.race : npc->race1EC;
            result.female = npc->baseData.IsFemale();
            result.raceForm = race != nullptr ? race->refID : 0;
            result.raceFieldForm = npc->race.race != nullptr ? npc->race.race->refID : 0;
            result.runtimeRaceForm = npc->race1EC != nullptr ? npc->race1EC->refID : 0;
            result.hairForm = npc->hair != nullptr ? npc->hair->refID : 0;
            result.hairLength = npc->hairLength;
            result.eyesForm = npc->eyes != nullptr ? npc->eyes->refID : 0;
            result.hairColor[0] = static_cast<UInt8>(npc->hairColor & 0xff);
            result.hairColor[1] = static_cast<UInt8>((npc->hairColor >> 8) & 0xff);
            result.hairColor[2] = static_cast<UInt8>((npc->hairColor >> 16) & 0xff);
            result.hairColor[3] = static_cast<UInt8>((npc->hairColor >> 24) & 0xff);
            result.copyFromForm = npc->copyFrom != nullptr ? npc->copyFrom->refID : 0;
            result.hairModel = npc->hair != nullptr ? npc->hair->model.nifPath.m_data : "";
            result.eyeTexture = npc->eyes != nullptr ? npc->eyes->texture.ddsPath.m_data : "";

            for (tList<BGSHeadPart>::Iterator iter = npc->headPart.Begin();
                 !iter.End() && result.headPartCount < 32; ++iter)
            {
                BGSHeadPart* part = iter.Get();
                if (part == nullptr)
                    continue;
                NpcAppearanceSnapshot::HeadPart& item = result.headParts[result.headPartCount++];
                item.form = part->refID;
                item.model = part->texSwap.nifPath.m_data;
            }
            for (unsigned int i = 0; i < 3; ++i)
            {
                const TESNPC::FaceGenData& channel = npc->faceGenData[i];
                result.faceGenChannels[i].count = channel.count;
                result.faceGenChannels[i].size = channel.size;
                result.faceGenChannels[i].hasValues = channel.values != nullptr;
            }
            if (race != nullptr)
            {
                const unsigned int sex = result.female ? 1u : 0u;
                result.raceFaceSlotCount = 8;
                for (unsigned int i = 0; i < 8; ++i)
                {
                    result.raceFaceSlots[i].model = race->faceModels[sex][i].nifPath.m_data;
                    result.raceFaceSlots[i].texture = race->faceTextures[sex][i].ddsPath.m_data;
                }
            }
            return true;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            return false;
        }
    }

    void captureTargetAppearance()
    {
        if (gAppearanceLogged || gTargetForm == 0)
            return;
        Actor* actor = findDriveActor();
        if (actor == nullptr || actor->baseForm == nullptr)
            return;
        captureRetailRenderEnvironment();

        NpcAppearanceSnapshot snapshot = {};
        if (!readNpcAppearanceUnsafe(actor, snapshot))
        {
            gOutput << "{\"schema\":" << sSchemaJson << ",\"event\":\"npc-appearance-fault\""
                    << ",\"frame\":" << gFrame << "}\n";
            gOutput.flush();
            return;
        }
        gAppearanceLogged = true;
        if (!snapshot.npc)
        {
            gOutput << "{\"schema\":" << sSchemaJson << ",\"event\":\"target-appearance\""
                    << ",\"frame\":" << gFrame
                    << ",\"refForm\":" << snapshot.refForm
                    << ",\"baseForm\":" << snapshot.baseForm
                    << ",\"baseType\":" << static_cast<UInt32>(snapshot.baseType)
                    << ",\"npc\":false}\n";
            gOutput.flush();
            return;
        }

        gOutput << std::setprecision(9)
                << "{\"schema\":" << sSchemaJson << ",\"event\":\"npc-appearance\""
                << ",\"frame\":" << gFrame
                << ",\"refForm\":" << snapshot.refForm
                << ",\"baseForm\":" << snapshot.baseForm
                << ",\"female\":" << (snapshot.female ? "true" : "false")
                << ",\"raceForm\":" << snapshot.raceForm
                << ",\"raceFieldForm\":" << snapshot.raceFieldForm
                << ",\"runtimeRaceForm\":" << snapshot.runtimeRaceForm
                << ",\"hairForm\":" << snapshot.hairForm
                << ",\"hairLength\":" << snapshot.hairLength
                << ",\"eyesForm\":" << snapshot.eyesForm
                << ",\"hairColorRgba\":[" << static_cast<UInt32>(snapshot.hairColor[0]) << ','
                << static_cast<UInt32>(snapshot.hairColor[1]) << ','
                << static_cast<UInt32>(snapshot.hairColor[2]) << ','
                << static_cast<UInt32>(snapshot.hairColor[3]) << ']'
                << ",\"copyFromForm\":" << snapshot.copyFromForm
                << ",\"hairModel\":" << jsonString(snapshot.hairModel)
                << ",\"eyeTexture\":" << jsonString(snapshot.eyeTexture)
                << ",\"headParts\":[";
        for (unsigned int i = 0; i < snapshot.headPartCount; ++i)
        {
            if (i != 0)
                gOutput << ',';
            gOutput << "{\"form\":" << snapshot.headParts[i].form
                    << ",\"model\":" << jsonString(snapshot.headParts[i].model) << '}';
        }
        gOutput << "],\"faceGenChannels\":[";
        for (unsigned int i = 0; i < 3; ++i)
        {
            if (i != 0)
                gOutput << ',';
            const NpcAppearanceSnapshot::FaceGenChannel& channel = snapshot.faceGenChannels[i];
            gOutput << "{\"index\":" << i
                    << ",\"count\":" << channel.count
                    << ",\"size\":" << channel.size
                    << ",\"hasValues\":" << (channel.hasValues ? "true" : "false") << '}';
        }
        gOutput << "],\"raceFaceSlots\":[";
        for (unsigned int i = 0; i < snapshot.raceFaceSlotCount; ++i)
        {
            if (i != 0)
                gOutput << ',';
            gOutput << "{\"index\":" << i
                    << ",\"model\":" << jsonString(snapshot.raceFaceSlots[i].model)
                    << ",\"texture\":" << jsonString(snapshot.raceFaceSlots[i].texture) << '}';
        }
        gOutput << "]}\n";
        gOutput.flush();
    }

    void driveObserverApproach()
    {
        if (gObserverApproachForm == 0 || gObserverApproachComplete || gConsole == nullptr)
            return;
        PlayerCharacter* player = *reinterpret_cast<PlayerCharacter**>(0x011DEA3C);
        TESForm* targetForm = lookupForm(gObserverApproachForm);
        TESObjectREFR* target = targetForm != nullptr && targetForm->GetIsReference()
            ? static_cast<TESObjectREFR*>(targetForm)
            : nullptr;
        if (player == nullptr || target == nullptr)
        {
            if (!gObserverApproachWaitingLogged)
            {
                gObserverApproachWaitingLogged = true;
                gOutput << "{\"schema\":" << sSchemaJson
                        << ",\"event\":\"observer-approach-waiting\""
                        << ",\"frame\":" << gFrame
                        << ",\"targetForm\":" << gObserverApproachForm << "}\n";
                gOutput.flush();
            }
            return;
        }

        const float finalDx = target->posX - player->posX;
        const float finalDy = target->posY - player->posY;
        const float distance = std::sqrt(finalDx * finalDx + finalDy * finalDy);
        if (distance <= gObserverApproachStopDistance)
        {
            gObserverApproachComplete = true;
            gOutput << "{\"schema\":" << sSchemaJson
                    << ",\"event\":\"observer-approach-complete\""
                    << ",\"frame\":" << gFrame
                    << ",\"targetForm\":" << gObserverApproachForm
                    << ",\"distance\":" << distance
                    << ",\"playerPosition\":[" << player->posX << ',' << player->posY << ',' << player->posZ
                    << "]}\n";
            gOutput.flush();
            return;
        }

        while (gObserverWaypointIndex < gObserverWaypoints.size())
        {
            const ObserverWaypoint& waypoint = gObserverWaypoints[gObserverWaypointIndex];
            const float waypointDx = waypoint.x - player->posX;
            const float waypointDy = waypoint.y - player->posY;
            if (std::sqrt(waypointDx * waypointDx + waypointDy * waypointDy) > 180.f)
                break;
            gOutput << "{\"schema\":" << sSchemaJson
                    << ",\"event\":\"observer-waypoint-complete\""
                    << ",\"frame\":" << gFrame
                    << ",\"waypointIndex\":" << gObserverWaypointIndex
                    << ",\"playerPosition\":[" << player->posX << ',' << player->posY << ',' << player->posZ
                    << "]}\n";
            ++gObserverWaypointIndex;
        }

        float steeringX = target->posX;
        float steeringY = target->posY;
        if (gObserverWaypointIndex < gObserverWaypoints.size())
        {
            steeringX = gObserverWaypoints[gObserverWaypointIndex].x;
            steeringY = gObserverWaypoints[gObserverWaypointIndex].y;
        }
        const float dx = steeringX - player->posX;
        const float dy = steeringY - player->posY;

        if (!gObserverApproachStarted)
        {
            gObserverApproachStarted = true;
            gOutput << "{\"schema\":" << sSchemaJson
                    << ",\"event\":\"observer-approach-start\""
                    << ",\"frame\":" << gFrame
                    << ",\"targetForm\":" << gObserverApproachForm
                    << ",\"distance\":" << distance << "}\n";
        }
        const float steeringDistance = std::sqrt(dx * dx + dy * dy);
        if (steeringDistance > 0.001f)
        {
            const float step = (std::min)(gObserverApproachStepDistance, steeringDistance);
            const float nextX = player->posX + dx * step / steeringDistance;
            const float nextY = player->posY + dy * step / steeringDistance;
            char commandX[96] = {};
            char commandY[96] = {};
            char commandYaw[96] = {};
            const float yawDegrees = std::atan2(dx, dy) * 180.f / 3.14159265358979323846f;
            sprintf_s(commandX, "SetPos X %.6f", nextX);
            sprintf_s(commandY, "SetPos Y %.6f", nextY);
            sprintf_s(commandYaw, "SetAngle Z %.6f", yawDegrees);
            const bool acceptedX = gConsole->RunScriptLine2(commandX, player, true);
            const bool acceptedY = gConsole->RunScriptLine2(commandY, player, true);
            const bool acceptedYaw = gConsole->RunScriptLine2(commandYaw, player, true);
            if ((!acceptedX || !acceptedY || !acceptedYaw) && gWorldLoopFrame % 60 == 0)
            {
                gOutput << "{\"schema\":" << sSchemaJson
                        << ",\"event\":\"observer-approach-command-rejected\""
                        << ",\"frame\":" << gFrame
                        << ",\"setX\":" << (acceptedX ? "true" : "false")
                        << ",\"setY\":" << (acceptedY ? "true" : "false")
                        << ",\"setYaw\":" << (acceptedYaw ? "true" : "false") << "}\n";
            }
        }
        if (gWorldLoopFrame % 60 == 0)
        {
            gOutput << "{\"schema\":" << sSchemaJson
                    << ",\"event\":\"observer-approach-progress\""
                    << ",\"frame\":" << gFrame
                    << ",\"targetForm\":" << gObserverApproachForm
                    << ",\"distance\":" << distance
                    << ",\"waypointIndex\":" << gObserverWaypointIndex
                    << ",\"steeringTarget\":[" << steeringX << ',' << steeringY << ']'
                    << ",\"playerPosition\":[" << player->posX << ',' << player->posY << ',' << player->posZ
                    << "]}\n";
            gOutput.flush();
        }
    }

    void drivePortraitCameraUnsafe()
    {
        if (!gPortraitCamera || gConsole == nullptr || gTargetForm == 0)
            return;
        PlayerCharacter* player = *reinterpret_cast<PlayerCharacter**>(0x011DEA3C);
        Actor* actor = findDriveActor();
        if (player == nullptr || actor == nullptr)
            return;
        if (!gPortraitCameraRequested)
        {
            gPortraitCameraRequested = true;
            const bool tfcAccepted = gConsole->RunScriptLine2("TFC", nullptr, true);
            const bool menusAccepted = gConsole->RunScriptLine2("ToggleMenus", nullptr, true);
            gOutput << "{\"schema\":" << sSchemaJson
                    << ",\"event\":\"portrait-camera-request\""
                    << ",\"frame\":" << gFrame
                    << ",\"refForm\":" << actor->refID
                    << ",\"shotKind\":" << jsonString(gCameraShotKind.c_str())
                    << ",\"tfcAccepted\":" << (tfcAccepted ? "true" : "false")
                    << ",\"toggleMenusAccepted\":" << (menusAccepted ? "true" : "false") << "}\n";
            gOutput.flush();
            return;
        }

        if (!gBatchTargetForms.empty() && !gBatchTargetLoadRequested)
            return;
        if (gBatchProofStaging)
        {
            if (!gBatchTargetStaged)
                return;
            // AI packages are still live after an authored reference is moved.
            // Keep the proof root at the canonical transform through the render
            // frame so pathing cannot yaw or walk it away between stage and shot.
            const float yawDegrees = gBatchProofTargetYaw * 180.f / 3.14159265358979323846f;
            const bool transformLocked
                = runReferenceFloatCommand(actor, "SetPos X", gBatchProofTargetX)
                && runReferenceFloatCommand(actor, "SetPos Y", gBatchProofTargetY)
                && runReferenceFloatCommand(actor, "SetPos Z", gBatchProofTargetZ)
                && runReferenceFloatCommand(actor, "SetAngle X", 0.f)
                && runReferenceFloatCommand(actor, "SetAngle Y", 0.f)
                && runReferenceFloatCommand(actor, "SetAngle Z", yawDegrees);
            if (!transformLocked)
            {
                if (!gBatchTargetStageWaitingLogged)
                {
                    gBatchTargetStageWaitingLogged = true;
                    gOutput << "{\"schema\":" << sSchemaJson
                            << ",\"event\":\"batch-target-transform-lock-rejected\""
                            << ",\"frame\":" << gFrame
                            << ",\"targetIndex\":" << gBatchTargetIndex
                            << ",\"refForm\":" << actor->refID << "}\n";
                    gOutput.flush();
                }
                return;
            }
            if (gFrame < gBatchTargetStageFrame + gBatchProofTargetSettleFrames)
                return;
            // Quest enable parents can materialize additional authored or leveled
            // actors around the road. A target-only bound cannot detect one that
            // overlaps it, so the proof volume must first be exclusive.
            ActorProcessManager* manager = reinterpret_cast<ActorProcessManager*>(0x011E0E80);
            UInt32 intruders = 0;
            if (manager != nullptr)
            {
                std::set<Actor*> proofActors;
                const auto collectActors = [&proofActors](tList<Actor>& actors)
                {
                    auto* node = actors.Head();
                    for (UInt32 visited = 0; node != nullptr && visited < 4096; ++visited)
                    {
                        ListNode<Actor> snapshot = {};
                        if (!safeRead(node, snapshot))
                            break;
                        UInt32 reference = 0;
                        if (snapshot.data != nullptr && safeRead(&snapshot.data->refID, reference)
                            && reference != 0)
                            proofActors.insert(snapshot.data);
                        node = snapshot.next;
                    }
                };
                collectActors(manager->middleHighActors.head);
                collectActors(manager->lowActors0C.head);
                collectActors(manager->lowActors18.head);
                collectActors(manager->highActors);
                if (manager->actor64 != nullptr)
                    proofActors.insert(manager->actor64);
                for (Actor* candidate : proofActors)
                {
                    if (candidate != nullptr && candidate != actor && candidate != player)
                    {
                        UInt32 reference = 0;
                        TESForm* baseForm = nullptr;
                        UInt32 baseReference = 0;
                        float originalX = 0.f;
                        float originalY = 0.f;
                        float originalZ = 0.f;
                        if (!safeRead(&candidate->refID, reference)
                            || !safeRead(&candidate->baseForm, baseForm)
                            || !safeRead(&candidate->posX, originalX)
                            || !safeRead(&candidate->posY, originalY)
                            || !safeRead(&candidate->posZ, originalZ)
                            || reference == 0)
                            continue;
                        if (baseForm != nullptr)
                            safeRead(&baseForm->refID, baseReference);
                        const float intruderDx = originalX - gBatchProofTargetX;
                        const float intruderDy = originalY - gBatchProofTargetY;
                        const float intruderDz = originalZ - gBatchProofTargetZ;
                        if (intruderDx * intruderDx + intruderDy * intruderDy <= 1024.f * 1024.f
                            && std::fabs(intruderDz) <= 512.f)
                        {
                            ++intruders;
                            ++gBatchProofEvictionCount;
                            const bool moveAccepted = gConsole != nullptr
                                && gConsole->RunScriptLine2("MoveTo 00000014", candidate, true);
                            const bool disableAccepted = gConsole != nullptr
                                && gConsole->RunScriptLine2("Disable", candidate, true);
                            gOutput << "{\"schema\":" << sSchemaJson
                                    << ",\"event\":\"batch-proof-intruder-eviction\""
                                    << ",\"frame\":" << gFrame
                                    << ",\"targetIndex\":" << gBatchTargetIndex
                                    << ",\"targetForm\":" << gTargetForm
                                    << ",\"intruderRef\":" << reference
                                    << ",\"intruderBase\":" << baseReference
                                    << ",\"position\":[" << originalX << ',' << originalY
                                    << ',' << originalZ << ']'
                                    << ",\"moveAccepted\":" << (moveAccepted ? "true" : "false")
                                    << ",\"disableAccepted\":"
                                    << (disableAccepted ? "true" : "false") << "}\n";
                        }
                    }
                }
            }
            if (intruders != 0)
            {
                gOutput.flush();
                return;
            }
            if (!gBatchProofCensusLogged)
            {
                gBatchProofCensusLogged = true;
                gOutput << "{\"schema\":" << sSchemaJson
                        << ",\"event\":\"batch-proof-volume-census\""
                        << ",\"frame\":" << gFrame
                        << ",\"targetIndex\":" << gBatchTargetIndex
                        << ",\"targetForm\":" << gTargetForm
                        << ",\"passed\":true,\"intruders\":0"
                        << ",\"evictionCount\":" << gBatchProofEvictionCount
                        << ",\"playerPosition\":[" << player->posX << ',' << player->posY
                        << ',' << player->posZ << "]}\n";
                gOutput.flush();
            }
            const float dx = actor->posX - gBatchProofTargetX;
            const float dy = actor->posY - gBatchProofTargetY;
            const float dz = actor->posZ - gBatchProofTargetZ;
            float yawError = std::fmod(std::fabs(actor->rotZ - gBatchProofTargetYaw),
                2.f * 3.14159265358979323846f);
            if (yawError > 3.14159265358979323846f)
                yawError = 2.f * 3.14159265358979323846f - yawError;
            const float positionError = std::sqrt(dx * dx + dy * dy + dz * dz);
            if (positionError > 24.f || yawError > 0.08f)
            {
                if (!gBatchTargetStageWaitingLogged)
                {
                    gBatchTargetStageWaitingLogged = true;
                    gOutput << "{\"schema\":" << sSchemaJson
                            << ",\"event\":\"batch-target-stage-waiting\""
                            << ",\"frame\":" << gFrame
                            << ",\"targetIndex\":" << gBatchTargetIndex
                            << ",\"refForm\":" << actor->refID
                            << ",\"position\":[" << actor->posX << ',' << actor->posY << ','
                            << actor->posZ << ']'
                            << ",\"positionError\":" << positionError
                            << ",\"yaw\":" << actor->rotZ
                            << ",\"yawError\":" << yawError << "}\n";
                    gOutput.flush();
                }
                return;
            }
        }

        NiNode* root = actor->GetNiNode();
        if (root == nullptr)
        {
            bool bootstrapApplied = false;
            float bootstrapX = 0.f;
            float bootstrapY = 0.f;
            float bootstrapZ = 0.f;
            if (gFullBodyCamera)
            {
                // In a one-process TFC batch, player.moveto can cross a streaming
                // boundary while the free camera remains at the prior target. That
                // creates a deadlock: the authored actor exists at high process but
                // cannot acquire its scene root until the camera reaches its cell.
                // Move only the free camera near the authored reference to activate
                // retail 3D. This is a bootstrap, never an accepted proof frame;
                // gPortraitCameraLogged remains false until live bounds are read.
                const float forwardX = std::sin(actor->rotZ);
                const float forwardY = std::cos(actor->rotZ);
                const float aimX = actor->posX;
                const float aimY = actor->posY;
                const float aimZ = actor->posZ + 64.f;
                const float distance = (std::max)(gPortraitDistance, 256.f);
                bootstrapX = aimX + forwardX * distance;
                bootstrapY = aimY + forwardY * distance;
                bootstrapZ = aimZ;
                const float yaw = std::atan2(aimX - bootstrapX, aimY - bootstrapY);
                *reinterpret_cast<float*>(reinterpret_cast<UInt8*>(player) + 0x7E0) = yaw;
                *reinterpret_cast<float*>(reinterpret_cast<UInt8*>(player) + 0x7E4) = 0.f;
                *reinterpret_cast<float*>(reinterpret_cast<UInt8*>(player) + 0x7E8) = bootstrapX;
                *reinterpret_cast<float*>(reinterpret_cast<UInt8*>(player) + 0x7EC) = bootstrapY;
                *reinterpret_cast<float*>(reinterpret_cast<UInt8*>(player) + 0x7F0) = bootstrapZ;
                bootstrapApplied = true;
            }
            if (!gPortraitCameraWaitingLogged)
            {
                gPortraitCameraWaitingLogged = true;
                gOutput << "{\"schema\":" << sSchemaJson
                        << ",\"event\":\"portrait-camera-waiting\""
                        << ",\"frame\":" << gFrame
                        << ",\"refForm\":" << actor->refID
                        << ",\"reason\":\"actor-root-missing\""
                        << ",\"bootstrapApplied\":" << (bootstrapApplied ? "true" : "false")
                        << ",\"bootstrapCamera\":[" << bootstrapX << ',' << bootstrapY << ','
                        << bootstrapZ << "]}\n";
                gOutput.flush();
            }
            return;
        }

        // Robots can retain a humanoid-named Bip01 Head whose +Y axis points out
        // the back of the chassis. Prefer a rendered screen surface when one is
        // present. Its local +Y is the authored outward normal in retail assets.
        NiAVObject* focus = findNodeRecursivePrefix(root, "Screen01");
        bool screenFocus = focus != nullptr;
        if (focus == nullptr)
            focus = findNodeRecursivePrefix(root, "Screenreflection01");
        screenFocus = screenFocus || focus != nullptr;
        if (focus == nullptr)
            focus = findNodeRecursive(root, "Bip01 Head");

        bool rootFallback = focus == nullptr;
        const char* focusFallbackReason = rootFallback ? "semantic-focus-missing" : nullptr;
        if (rootFallback)
            focus = root;
        // Keep this as a pointer. NiTransform has C++ lifetime semantics in the
        // xNVSE headers, and copying one inside an SEH-protected function makes
        // MSVC require C++ unwinding (C2712). The retail object owns the transform.
        const NiTransform* focusTransform = &runtimeTransform(*focus, sNiAVObjectWorldTransformOffset);
        NiVector3 focusWorld = focusTransform->translate;
        if (rootFallback)
        {
            focusWorld.x = actor->posX;
            focusWorld.y = actor->posY;
            focusWorld.z = actor->posZ + 100.f;
        }
        else
        {
            const float focusDx = focusWorld.x - actor->posX;
            const float focusDy = focusWorld.y - actor->posY;
            const float focusDz = focusWorld.z - actor->posZ;
            if (focusDx * focusDx + focusDy * focusDy + focusDz * focusDz < 400.f)
            {
                // The old fixed 20-unit threshold rejects legitimate small rigs
                // forever. Full-body aim comes from the live world bound, so use
                // root yaw for the semantic front instead of stalling the batch.
                if (gFullBodyCamera)
                {
                    rootFallback = true;
                    screenFocus = false;
                    focus = root;
                    focusTransform = &runtimeTransform(*root, sNiAVObjectWorldTransformOffset);
                    focusWorld.x = actor->posX;
                    focusWorld.y = actor->posY;
                    focusWorld.z = actor->posZ + 100.f;
                    focusFallbackReason = "semantic-focus-near-actor";
                }
                else
                {
                    if (!gPortraitCameraWaitingLogged)
                    {
                        gPortraitCameraWaitingLogged = true;
                        gOutput << "{\"schema\":" << sSchemaJson
                                << ",\"event\":\"portrait-camera-waiting\""
                                << ",\"frame\":" << gFrame
                                << ",\"refForm\":" << actor->refID
                                << ",\"reason\":\"semantic-focus-near-actor\"}\n";
                        gOutput.flush();
                    }
                    return;
                }
            }
        }
        const char* focusNodeLabel
            = screenFocus ? "Screen01" : (rootFallback ? "<actor-root>" : "Bip01 Head");
        const char* focusKindLabel = screenFocus ? "screen" : (rootFallback ? "root" : "head");

        OracleBound* rootWorldBoundAddress = nullptr;
        bool rootWorldBoundPointerReadable = false;
        OracleBound rootWorldBound = {};
        const bool rootWorldBoundReadable = readObjectWorldBound(
            root, rootWorldBoundAddress, rootWorldBoundPointerReadable, rootWorldBound);
        const OracleBoundValidation rootWorldBoundValidation = rootWorldBoundReadable
            ? validateActorWorldBound(rootWorldBound, actor)
            : OracleBoundValidation::NonFinite;
        OracleAssembledBound assembledWorldBound = {};
        collectActorWorldBounds(actor, root, 0, assembledWorldBound);
        OracleBound assembledBound = {};
        const bool assembledWorldBoundValid = finalizeAssembledBound(assembledWorldBound, assembledBound);
        OracleBound worldBound = {};
        const char* worldBoundSource = "none";
        bool worldBoundValid = false;
        if (assembledWorldBoundValid)
        {
            worldBound = assembledBound;
            worldBoundSource = "assembled";
            worldBoundValid = true;
        }
        else if (rootWorldBoundReadable
            && rootWorldBoundValidation == OracleBoundValidation::Accepted)
        {
            // Tiny creature trees may not meet the strict assembled-span gate.
            // The engine's validated live root sphere remains authoritative.
            worldBound = rootWorldBound;
            worldBoundSource = "root-fallback";
            worldBoundValid = true;
        }
        if (gFullBodyCamera && !worldBoundValid)
        {
            if (!gFullBodyBoundsWaitingLogged)
            {
                gFullBodyBoundsWaitingLogged = true;
                gOutput << "{\"schema\":" << sSchemaJson
                        << ",\"event\":\"full-body-bounds-waiting\""
                        << ",\"frame\":" << gFrame
                        << ",\"refForm\":" << actor->refID
                        << ",\"rootWorldBound\":";
                writeRawBoundDiagnostics(
                    gOutput, rootWorldBoundPointerReadable, rootWorldBoundAddress,
                    rootWorldBoundReadable, rootWorldBoundValidation, rootWorldBound);
                gOutput << ",\"assembledWorldBound\":";
                writeAssembledBoundDiagnostics(
                    gOutput, assembledWorldBoundValid, assembledWorldBound, assembledBound);
                gOutput << "}\n";
                gOutput.flush();
            }
            return;
        }
        const float aimX = gFullBodyCamera ? worldBound.center.x : focusWorld.x;
        const float aimY = gFullBodyCamera ? worldBound.center.y : focusWorld.y;
        const float rawAimZ = gFullBodyCamera
            ? worldBound.center.z
            : focusWorld.z + (screenFocus || rootFallback ? 0.f : 20.f);
        // The proof surface is an explicit part of the shared-volume contract.
        // Live ragdolls and low creature rigs can author their bound center below
        // that surface; never put the optical axis back inside the road mesh.
        const float minimumAimZ = gBatchProofTargetZ + gBatchProofMinimumAimHeight;
        const float aimZ = gBatchProofStaging && gFullBodyCamera
            ? (std::max)(rawAimZ, minimumAimZ)
            : rawAimZ;
        // Bethesda bipeds and the Securitron screen surface both author local +Y
        // as face-forward. Follow the rendered semantic surface when it is valid.
        float forwardX = gBatchProofStaging
            ? std::sin(gBatchProofTargetYaw)
            : (rootFallback ? std::sin(actor->rotZ) : focusTransform->rotate.data[1]);
        float forwardY = gBatchProofStaging
            ? std::cos(gBatchProofTargetYaw)
            : (rootFallback ? std::cos(actor->rotZ) : focusTransform->rotate.data[4]);
        if (gBatchProofStaging)
            focusFallbackReason = "proof-volume-canonical-yaw";
        float forwardLength = std::sqrt(forwardX * forwardX + forwardY * forwardY);
        if (forwardLength < 0.25f)
        {
            if (gFullBodyCamera)
            {
                forwardX = std::sin(actor->rotZ);
                forwardY = std::cos(actor->rotZ);
                forwardLength = 1.f;
                focusFallbackReason = "semantic-forward-degenerate";
            }
            else
            {
                if (!gPortraitCameraWaitingLogged)
                {
                    gPortraitCameraWaitingLogged = true;
                    gOutput << "{\"schema\":" << sSchemaJson
                            << ",\"event\":\"portrait-camera-waiting\""
                            << ",\"frame\":" << gFrame
                            << ",\"refForm\":" << actor->refID
                            << ",\"reason\":\"semantic-forward-degenerate\"}\n";
                    gOutput.flush();
                }
                return;
            }
        }
        forwardX /= forwardLength;
        forwardY /= forwardLength;
        const float framingRadius = gFullBodyCamera
            ? worldBound.radius + (gBatchProofStaging
                ? std::fabs(aimZ - worldBound.center.z)
                : 0.f)
            : 0.f;
        const float cameraDistance = gFullBodyCamera
            ? (std::max)(gPortraitDistance, framingRadius * gFullBodyDistanceScale)
            : gPortraitDistance;
        const float cameraX = aimX + forwardX * cameraDistance;
        const float cameraY = aimY + forwardY * cameraDistance;
        const float minimumCameraZ = gBatchProofTargetZ + gBatchProofMinimumCameraHeight;
        const float cameraZ = gBatchProofStaging && gFullBodyCamera
            ? (std::max)(aimZ, minimumCameraZ)
            : aimZ;
        const float cameraAimDz = aimZ - cameraZ;
        const float cameraLineDistance = std::sqrt(
            cameraDistance * cameraDistance + cameraAimDz * cameraAimDz);
        const float cameraYaw = std::atan2(aimX - cameraX, aimY - cameraY);
        // PlayerCharacter::flycamXRot uses positive rotation to look downward,
        // opposite the signed elevation of the camera-to-aim vector.
        const float cameraPitch = -std::atan2(cameraAimDz, cameraDistance);
        *reinterpret_cast<float*>(reinterpret_cast<UInt8*>(player) + 0x7E0) = cameraYaw;
        *reinterpret_cast<float*>(reinterpret_cast<UInt8*>(player) + 0x7E4) = cameraPitch;
        *reinterpret_cast<float*>(reinterpret_cast<UInt8*>(player) + 0x7E8) = cameraX;
        *reinterpret_cast<float*>(reinterpret_cast<UInt8*>(player) + 0x7EC) = cameraY;
        *reinterpret_cast<float*>(reinterpret_cast<UInt8*>(player) + 0x7F0) = cameraZ;
        if (gBatchProofStaging && !gBatchVisualStageGateLogged)
        {
            const float corridorStopDistance = (std::min)(
                cameraLineDistance - 2.f, worldBound.radius + 8.f);
            const float inverseLineDistance = 1.f / cameraLineDistance;
            const float corridorEndX = aimX
                + (cameraX - aimX) * inverseLineDistance * corridorStopDistance;
            const float corridorEndY = aimY
                + (cameraY - aimY) * inverseLineDistance * corridorStopDistance;
            const float corridorEndZ = aimZ
                + (cameraZ - aimZ) * inverseLineDistance * corridorStopDistance;
            const OracleRayCastResult corridor = castProofCorridor(player,
                cameraX, cameraY, cameraZ, corridorEndX, corridorEndY, corridorEndZ);
            const std::string hitName = safeRuntimeString(
                corridor.hitObject != nullptr ? corridor.hitObject->m_pcName : nullptr);
            const std::string hitType = safeRuntimeString(
                corridor.hitObject != nullptr
                    ? runtimeTypeName(reinterpret_cast<NiObject*>(corridor.hitObject))
                    : nullptr);
            gOutput << std::setprecision(9)
                    << "{\"schema\":" << sSchemaJson
                    << ",\"event\":\"batch-camera-occlusion-gate\""
                    << ",\"frame\":" << gFrame
                    << ",\"targetIndex\":" << gBatchTargetIndex
                    << ",\"targetForm\":" << gTargetForm
                    << ",\"passed\":" << (corridor.passed ? "true" : "false")
                    << ",\"filterAvailable\":"
                    << (corridor.filterAvailable ? "true" : "false")
                    << ",\"tesAvailable\":" << (corridor.tesAvailable ? "true" : "false")
                    << ",\"invoked\":" << (corridor.invoked ? "true" : "false")
                    << ",\"faulted\":" << (corridor.faulted ? "true" : "false")
                    << ",\"fractionValid\":" << (corridor.fractionValid ? "true" : "false")
                    << ",\"hit\":" << (corridor.hit ? "true" : "false")
                    << ",\"hitFraction\":";
            writeFiniteFloat(gOutput, corridor.hitFraction);
            gOutput << ",\"collisionFilter\":" << corridor.collisionFilter
                    << ",\"start\":[" << cameraX << ',' << cameraY << ',' << cameraZ << ']'
                    << ",\"end\":[" << corridorEndX << ',' << corridorEndY << ','
                    << corridorEndZ << ']'
                    << ",\"cameraLineDistance\":" << cameraLineDistance
                    << ",\"cameraPitch\":" << cameraPitch
                    << ",\"hitObjectAddress\":"
                    << static_cast<unsigned long>(
                        reinterpret_cast<std::uintptr_t>(corridor.hitObject))
                    << ",\"hitObjectName\":"
                    << jsonString(hitName.empty() ? nullptr : hitName.c_str())
                    << ",\"hitObjectType\":"
                    << jsonString(hitType.empty() ? nullptr : hitType.c_str()) << "}\n";
            const float positionDx = actor->posX - gBatchProofTargetX;
            const float positionDy = actor->posY - gBatchProofTargetY;
            const float positionDz = actor->posZ - gBatchProofTargetZ;
            const float positionError = std::sqrt(
                positionDx * positionDx + positionDy * positionDy + positionDz * positionDz);
            float yawError = std::fmod(std::fabs(actor->rotZ - gBatchProofTargetYaw),
                2.f * 3.14159265358979323846f);
            if (yawError > 3.14159265358979323846f)
                yawError = 2.f * 3.14159265358979323846f - yawError;
            const bool passed = gBatchTargetStaged && root != nullptr && worldBoundValid
                && corridor.passed
                && positionError <= 24.f && yawError <= 0.08f
                && std::isfinite(cameraX) && std::isfinite(cameraY) && std::isfinite(cameraZ)
                && std::isfinite(cameraPitch) && cameraLineDistance >= 32.f
                && cameraZ + 0.01f >= minimumCameraZ
                && aimZ + 0.01f >= minimumAimZ;
            gBatchVisualStageGateLogged = true;
            gBatchVisualStageGatePassed = passed;
            gOutput << std::setprecision(9)
                    << "{\"schema\":" << sSchemaJson
                    << ",\"event\":\"batch-visual-stage-gate\""
                    << ",\"frame\":" << gFrame
                    << ",\"targetIndex\":" << gBatchTargetIndex
                    << ",\"targetForm\":" << gTargetForm
                    << ",\"passed\":" << (passed ? "true" : "false")
                    << ",\"rootAvailable\":" << (root != nullptr ? "true" : "false")
                    << ",\"worldBoundValid\":" << (worldBoundValid ? "true" : "false")
                    << ",\"proofVolumeExclusive\":"
                    << (gBatchProofCensusLogged ? "true" : "false")
                    << ",\"occlusionGatePassed\":" << (corridor.passed ? "true" : "false")
                    << ",\"worldBoundSource\":\"" << worldBoundSource << '"'
                    << ",\"position\":[" << actor->posX << ',' << actor->posY << ',' << actor->posZ << ']'
                    << ",\"expectedPosition\":[" << gBatchProofTargetX << ','
                    << gBatchProofTargetY << ',' << gBatchProofTargetZ << ']'
                    << ",\"positionError\":" << positionError
                    << ",\"yaw\":" << actor->rotZ
                    << ",\"expectedYaw\":" << gBatchProofTargetYaw
                    << ",\"yawError\":" << yawError
                    << ",\"rawAimZ\":" << rawAimZ
                    << ",\"minimumAimZ\":" << minimumAimZ
                    << ",\"minimumCameraZ\":" << minimumCameraZ
                    << ",\"framingRadius\":" << framingRadius
                    << ",\"aim\":[" << aimX << ',' << aimY << ',' << aimZ << ']'
                    << ",\"camera\":[" << cameraX << ',' << cameraY << ',' << cameraZ << ']'
                    << ",\"cameraDistance\":" << cameraDistance
                    << ",\"cameraLineDistance\":" << cameraLineDistance
                    << ",\"cameraPitch\":" << cameraPitch << "}\n";
            gOutput.flush();
            if (!passed)
                return;
        }
        if (gBatchProofStaging && !gBatchVisualStageGatePassed)
            return;
        if (!gPortraitCameraLogged)
        {
            gPortraitCameraLogged = true;
            gOutput << std::setprecision(9)
                    << "{\"schema\":" << sSchemaJson
                    << ",\"event\":\"portrait-camera-set\""
                    << ",\"frame\":" << gFrame
                    << ",\"refForm\":" << actor->refID
                    << ",\"shotKind\":\"" << gCameraShotKind << '\"'
                    << ",\"focusNode\":\"" << focusNodeLabel << '\"'
                    << ",\"focusKind\":\"" << focusKindLabel << '\"'
                    << ",\"focusFallbackReason\":"
                    << (focusFallbackReason != nullptr ? jsonString(focusFallbackReason) : "null")
                    << ",\"headWorld\":[" << focusWorld.x << ',' << focusWorld.y << ',' << focusWorld.z << ']'
                    << ",\"headForwardXY\":[" << forwardX << ',' << forwardY << ']'
                    << ",\"rootWorldBound\":";
            writeRawBoundDiagnostics(
                gOutput, rootWorldBoundPointerReadable, rootWorldBoundAddress,
                rootWorldBoundReadable, rootWorldBoundValidation, rootWorldBound);
            gOutput << ",\"assembledWorldBound\":";
            writeAssembledBoundDiagnostics(
                gOutput, assembledWorldBoundValid, assembledWorldBound, assembledBound);
            gOutput << ",\"worldBound\":{\"valid\":" << (worldBoundValid ? "true" : "false")
                    << ",\"source\":\"" << worldBoundSource << '\"'
                    << ",\"center\":[" << worldBound.center.x << ',' << worldBound.center.y << ','
                    << worldBound.center.z << "]"
                    << ",\"radius\":" << worldBound.radius << '}'
                    << ",\"cameraDistance\":" << cameraDistance
                    << ",\"cameraLineDistance\":" << cameraLineDistance
                    << ",\"framingRadius\":" << framingRadius
                    << ",\"rawAimZ\":" << rawAimZ
                    << ",\"minimumAimZ\":" << minimumAimZ
                    << ",\"minimumCameraZ\":" << minimumCameraZ
                    << ",\"aim\":[" << aimX << ',' << aimY << ',' << aimZ << ']'
                    << ",\"camera\":[" << cameraX << ',' << cameraY << ',' << cameraZ << ']'
                    << ",\"rotation\":[" << cameraPitch << ',' << cameraYaw << "]}\n";
            gOutput.flush();
        }
    }

    void drivePortraitCamera()
    {
        // Keep SEH in a trivial wrapper. The camera implementation uses xNVSE
        // math types with C++ lifetime semantics, which cannot coexist with
        // __try in the same MSVC function (C2712).
        __try
        {
            drivePortraitCameraUnsafe();
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            gOutput << "{\"schema\":" << sSchemaJson
                    << ",\"event\":\"portrait-camera-fault\""
                    << ",\"frame\":" << gFrame << "}\n";
            gOutput.flush();
        }
    }

    void requestLoad()
    {
        if (gLoadRequested || gSaveName.empty() || gConsole == nullptr)
            return;
        gLoadRequested = true;
        if (gSaveName.find('"') != std::string::npos || gSaveName.find('\n') != std::string::npos
            || gSaveName.find('\r') != std::string::npos)
        {
            gOutput << "{\"schema\":" << jsonString(sSchema) << ",\"event\":\"load-rejected\","
                       "\"reason\":\"invalid-save-name\"}\n";
            gOutput.flush();
            return;
        }
        const std::string command = "LoadGame \"" + gSaveName + "\"";
        const bool accepted = gConsole->RunScriptLine2(command.c_str(), nullptr, true);
        gOutput << "{\"schema\":" << jsonString(sSchema) << ",\"event\":\"load-request\","
                   "\"save\":" << jsonString(gSaveName.c_str())
                << ",\"accepted\":" << (accepted ? "true" : "false") << "}\n";
        gOutput.flush();
    }

    bool setWeaponOutUnsafe(Actor* actor)
    {
        bool succeeded = false;
        __try
        {
            actor->baseProcess->SetWeaponOut(actor, true);
            succeeded = true;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            succeeded = false;
        }
        return succeeded;
    }

    void driveBatchWeaponState()
    {
        if (gBatchTargetForms.empty() || !gBatchForceWeaponOut || gBatchWeaponStateLogged)
            return;
        if (!gBatchTargetLoadRequested || (gBatchProofStaging
            && (!gBatchTargetStaged
                || gFrame < gBatchTargetStageFrame + gBatchProofTargetSettleFrames)))
            return;
        Actor* actor = findDriveActor();
        if (actor == nullptr || actor->baseProcess == nullptr || actor->baseProcess->processLevel > 1)
            return;
        if (gBatchWeaponProbeStartFrame == 0)
            gBatchWeaponProbeStartFrame = gFrame;

        MiddleHighProcess* process = static_cast<MiddleHighProcess*>(actor->baseProcess);
        TESObjectWEAP* weapon
            = process->weaponInfo != nullptr ? process->weaponInfo->weapon : nullptr;
        if (weapon == nullptr)
        {
            if (gFrame < gBatchWeaponProbeStartFrame + gBatchWeaponProbeFrames)
                return;
            gBatchWeaponStateLogged = true;
            gOutput << "{\"schema\":" << sSchemaJson
                    << ",\"event\":\"batch-weapon-state\""
                    << ",\"frame\":" << gFrame
                    << ",\"targetIndex\":" << gBatchTargetIndex
                    << ",\"refForm\":" << actor->refID
                    << ",\"status\":\"not-applicable\""
                    << ",\"weaponRequired\":false"
                    << ",\"weaponForm\":0"
                    << ",\"weaponOut\":false}\n";
            gOutput.flush();
            return;
        }

        const bool before = process->isWeaponOut;
        const bool accepted = before || setWeaponOutUnsafe(actor);
        const bool after = process->isWeaponOut;
        if (!after)
        {
            if (!gBatchWeaponWaitingLogged)
            {
                gBatchWeaponWaitingLogged = true;
                gOutput << "{\"schema\":" << sSchemaJson
                        << ",\"event\":\"batch-weapon-state-waiting\""
                        << ",\"frame\":" << gFrame
                        << ",\"targetIndex\":" << gBatchTargetIndex
                        << ",\"refForm\":" << actor->refID
                        << ",\"weaponForm\":" << weapon->refID
                        << ",\"setWeaponOutAccepted\":" << (accepted ? "true" : "false")
                        << "}\n";
                gOutput.flush();
            }
            return;
        }

        gBatchWeaponStateLogged = true;
        gOutput << "{\"schema\":" << sSchemaJson
                << ",\"event\":\"batch-weapon-state\""
                << ",\"frame\":" << gFrame
                << ",\"targetIndex\":" << gBatchTargetIndex
                << ",\"refForm\":" << actor->refID
                << ",\"status\":\"passed\""
                << ",\"weaponRequired\":true"
                << ",\"weaponForm\":" << weapon->refID
                << ",\"weaponOutBefore\":" << (before ? "true" : "false")
                << ",\"weaponOut\":true}\n";
        gOutput.flush();
    }

    bool equipItemUnsafe(Actor* actor, UInt32 formId)
    {
        bool succeeded = false;
        __try
        {
            TESForm* item = lookupForm(formId);
            if (actor != nullptr && item != nullptr)
            {
                using ItemAction = void(__thiscall*)(
                    Actor*, TESForm*, UInt32, ExtraDataList*, UInt32, bool, UInt32);
                TESForm* currentWeapon = nullptr;
                if (actor->baseProcess != nullptr && actor->baseProcess->processLevel <= 1)
                {
                    MiddleHighProcess* process = static_cast<MiddleHighProcess*>(actor->baseProcess);
                    if (process->weaponInfo != nullptr)
                        currentWeapon = process->weaponInfo->weapon;
                }
                if (currentWeapon != nullptr && currentWeapon != item)
                {
                    reinterpret_cast<ItemAction>(0x0088C790)(
                        actor, currentWeapon, 1, nullptr, 1, false, 1);
                }
                actor->AddItem(item, nullptr, 1);
                reinterpret_cast<ItemAction>(0x0088C650)(actor, item, 1, nullptr, 1, false, 1);
                succeeded = true;
            }
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            succeeded = false;
        }
        return succeeded;
    }

    void prepareActor()
    {
        if (gPrepareRequested || gConsole == nullptr)
            return;
        gPrepareRequested = true;
        gDrivenActor = findDriveActor();
        if (gDrivenActor != nullptr && !gActorCommands.empty())
        {
            gOutput << "{\"schema\":" << sSchemaJson << ",\"event\":\"actor-commands\""
                << ",\"frame\":" << gFrame << ",\"refForm\":" << gDrivenActor->refID
                << ",\"commands\":[";
            for (std::size_t i = 0; i < gActorCommands.size(); ++i)
            {
                if (i != 0)
                    gOutput << ',';
                const bool accepted = gConsole->RunScriptLine2(gActorCommands[i].c_str(), gDrivenActor, true);
                gOutput << "{\"text\":" << jsonString(gActorCommands[i].c_str())
                    << ",\"accepted\":" << (accepted ? "true" : "false") << '}';
            }
            gOutput << "]}\n";
        }
        gOutput << "{\"schema\":" << jsonString(sSchema) << ",\"event\":\"prepare-actor\","
                   "\"frame\":" << gFrame
                << ",\"refForm\":" << (gDrivenActor != nullptr ? gDrivenActor->refID : 0) << "}\n";
        gOutput.flush();
    }

    void equipActor()
    {
        if (gEquipRequested || gConsole == nullptr)
            return;
        gEquipRequested = true;
        if (gDrivenActor == nullptr)
            gDrivenActor = findDriveActor();
        bool addAccepted = gEquipForm == 0;
        bool equipAccepted = gEquipForm == 0;
        bool directEquipApplied = gEquipForm == 0;
        bool priorWeaponRemoveAccepted = gEquipForm == 0;
        UInt32 priorWeaponForm = 0;
        bool weaponOutAccepted = false;
        if (gDrivenActor != nullptr)
        {
            if (gEquipForm != 0)
            {
                char command[128] = {};
                if (gDrivenActor->baseProcess != nullptr && gDrivenActor->baseProcess->processLevel <= 1)
                {
                    MiddleHighProcess* process = static_cast<MiddleHighProcess*>(gDrivenActor->baseProcess);
                    if (process->weaponInfo != nullptr && process->weaponInfo->weapon != nullptr)
                        priorWeaponForm = process->weaponInfo->weapon->refID;
                }
                if (priorWeaponForm != 0 && priorWeaponForm != gEquipForm)
                {
                    sprintf_s(command, "RemoveItem %08X 99", priorWeaponForm);
                    priorWeaponRemoveAccepted = gConsole->RunScriptLine2(command, gDrivenActor, true);
                }
                sprintf_s(command, "AddItem %08X 1", gEquipForm);
                addAccepted = gConsole->RunScriptLine2(command, gDrivenActor, true);
                sprintf_s(command, "EquipItem %08X 1", gEquipForm);
                equipAccepted = gConsole->RunScriptLine2(command, gDrivenActor, true);
                directEquipApplied = equipItemUnsafe(gDrivenActor, gEquipForm);
            }
            weaponOutAccepted = setWeaponOutUnsafe(gDrivenActor);
        }
        gOutput << "{\"schema\":" << jsonString(sSchema) << ",\"event\":\"equip-actor\","
                   "\"frame\":" << gFrame
                << ",\"refForm\":" << (gDrivenActor != nullptr ? gDrivenActor->refID : 0)
                << ",\"equipForm\":" << gEquipForm
                << ",\"priorWeaponForm\":" << priorWeaponForm
                << ",\"priorWeaponRemoveAccepted\":" << (priorWeaponRemoveAccepted ? "true" : "false")
                << ",\"addAccepted\":" << (addAccepted ? "true" : "false")
                << ",\"equipAccepted\":" << (equipAccepted ? "true" : "false")
                << ",\"directEquipApplied\":" << (directEquipApplied ? "true" : "false")
                << ",\"weaponOutAccepted\":" << (weaponOutAccepted ? "true" : "false") << "}\n";
        gOutput.flush();
    }

    void driveActor()
    {
        if (gDriveRequested || (gPlayGroup.empty() && gDriveCommand.empty()) || gConsole == nullptr)
            return;
        gDriveRequested = true;
        Actor* actor = gDrivenActor != nullptr ? gDrivenActor : findDriveActor();
        bool accepted = false;
        char command[512] = {};
        if (!gDriveCommand.empty())
            strcpy_s(command, gDriveCommand.c_str());
        else
            sprintf_s(command, "PlayGroup %s 1", gPlayGroup.c_str());
        if (actor != nullptr)
        {
            setWeaponOutUnsafe(actor);
            accepted = gConsole->RunScriptLine2(command, actor, true);
        }
        gOutput << "{\"schema\":" << jsonString(sSchema) << ",\"event\":\"drive-actor\","
                   "\"frame\":" << gFrame
                << ",\"refForm\":" << (actor != nullptr ? actor->refID : 0)
                << ",\"group\":" << jsonString(gPlayGroup.c_str())
                << ",\"command\":" << jsonString(command)
                << ",\"accepted\":" << (accepted ? "true" : "false") << "}\n";
        gOutput.flush();
    }

    void toggleActorFootIk()
    {
        if (gFootIkToggleRequested || gFootIkToggleFrame == 0)
            return;
        gFootIkToggleRequested = true;
        Actor* actor = gDrivenActor != nullptr ? gDrivenActor : findDriveActor();
        const bool available
            = actor != nullptr && actor->ragDollController != nullptr && actor->ragDollController->bool021F;
        const bool before = available && actor->ragDollController->fikStatus;
        if (available)
            actor->ragDollController->fikStatus = gFootIkToggleEnabled;
        gOutput << "{\"schema\":" << sSchemaJson << ",\"event\":\"foot-ik-toggle\""
                << ",\"frame\":" << gFrame
                << ",\"refForm\":" << (actor != nullptr ? actor->refID : 0)
                << ",\"available\":" << (available ? "true" : "false")
                << ",\"before\":" << (before ? "true" : "false")
                << ",\"after\":" << (available && actor->ragDollController->fikStatus ? "true" : "false")
                << "}\n";
        gOutput.flush();
    }

    void finishCapture()
    {
        if (gFinishRequested)
            return;
        gFinishRequested = true;
        const bool incompleteBatch
            = !gBatchTargetForms.empty() && gBatchTargetIndex < gBatchTargetForms.size();
        if (incompleteBatch)
        {
            gOutput << "{\"schema\":" << jsonString(sSchema)
                    << ",\"event\":\"capture-incomplete\""
                    << ",\"reason\":\"max-frames\""
                    << ",\"frames\":" << gFrame
                    << ",\"completedTargets\":" << gBatchTargetIndex
                    << ",\"expectedTargets\":" << gBatchTargetForms.size()
                    << ",\"targetIndex\":" << gBatchTargetIndex
                    << ",\"targetForm\":" << gTargetForm << "}\n";
        }
        else
        {
            gOutput << "{\"schema\":" << jsonString(sSchema) << ",\"event\":\"capture-complete\","
                       "\"frames\":" << gFrame << "}\n";
        }
        gOutput.flush();
        if (gExitWhenDone && gConsole != nullptr)
            gConsole->RunScriptLine2("QuitGame", nullptr, true);
    }

    bool runReferenceFloatCommand(TESObjectREFR* reference, const char* commandName, float value)
    {
        if (reference == nullptr || commandName == nullptr || gConsole == nullptr)
            return false;
        char command[96] = {};
        sprintf_s(command, "%s %.6f", commandName, value);
        return gConsole->RunScriptLine2(command, reference, true);
    }

    struct SidecarInventoryItem
    {
        TESForm* form = nullptr;
        SInt64 count = 0;
        bool worn = false;
    };

    struct SidecarExtraDataHeader
    {
        void* vtable = nullptr;
        UInt8 type = 0;
        UInt8 padding[3] = {};
        BSExtraData* next = nullptr;
    };

    static_assert(sizeof(SidecarExtraDataHeader) == 0x0C);

    void sidecarFail(NikamiFNVSidecar::ErrorCode code, const std::string& message)
    {
        if (gSidecarPhase == SidecarPhase::Error)
            return;
        gSidecarPhase = SidecarPhase::Error;
        setSidecarSharedError(code, message);
        openOutput();
        if (gOutput)
        {
            gOutput << "{\"schema\":\"nikami-fnv-sidecar-retail/v1\""
                    << ",\"event\":\"sidecar-error\""
                    << ",\"sequenceId\":" << jsonString(gSidecarPlan.sequenceId.c_str())
                    << ",\"actorIndex\":" << gSidecarActorIndex
                    << ",\"actionIndex\":" << gSidecarActionIndex
                    << ",\"generation\":" << gSidecarGeneration
                    << ",\"frame\":" << gFrame
                    << ",\"code\":" << static_cast<UInt32>(code)
                    << ",\"message\":" << jsonString(message.c_str()) << "}\n";
            gOutput.flush();
        }
    }

    void sidecarCollectActorList(tList<Actor>& list, std::set<Actor*>& actors)
    {
        ListNode<Actor>* address = list.Head();
        for (UInt32 visited = 0; address != nullptr && visited < 4096; ++visited)
        {
            ListNode<Actor> node;
            if (!safeRead(address, node))
                break;
            UInt32 reference = 0;
            if (node.data != nullptr && safeRead(&node.data->refID, reference) && reference != 0)
                actors.insert(node.data);
            address = node.next;
        }
    }

    void sidecarCollectActors(std::set<Actor*>& actors)
    {
        ActorProcessManager* manager = reinterpret_cast<ActorProcessManager*>(0x011E0E80);
        if (manager == nullptr)
            return;
        sidecarCollectActorList(manager->middleHighActors.head, actors);
        sidecarCollectActorList(manager->lowActors0C.head, actors);
        sidecarCollectActorList(manager->lowActors18.head, actors);
        sidecarCollectActorList(manager->highActors, actors);
        Actor* actor64 = nullptr;
        if (safeRead(&manager->actor64, actor64) && actor64 != nullptr)
            actors.insert(actor64);
    }

    bool sidecarReadActorIdentity(Actor* actor, UInt32& reference, UInt32& base)
    {
        reference = 0;
        base = 0;
        TESForm* baseForm = nullptr;
        if (actor == nullptr || !safeRead(&actor->refID, reference)
            || !safeRead(&actor->baseForm, baseForm) || baseForm == nullptr)
            return false;
        return safeRead(&baseForm->refID, base) && reference != 0 && base != 0;
    }

    std::vector<Actor*> sidecarFindSpawnedActors(UInt32 baseForm)
    {
        std::set<Actor*> actors;
        sidecarCollectActors(actors);
        std::vector<std::pair<UInt32, Actor*>> matches;
        for (Actor* actor : actors)
        {
            UInt32 reference = 0;
            UInt32 base = 0;
            if (sidecarReadActorIdentity(actor, reference, base) && base == baseForm
                && gSidecarSpawnBaselineRefs.find(reference) == gSidecarSpawnBaselineRefs.end())
                matches.emplace_back(reference, actor);
        }
        std::sort(matches.begin(), matches.end(), [](const auto& left, const auto& right) {
            return left.first < right.first;
        });
        std::vector<Actor*> result;
        result.reserve(matches.size());
        for (const auto& match : matches)
            result.push_back(match.second);
        return result;
    }

    bool sidecarWriteExact(HANDLE file, const void* data, DWORD size)
    {
        DWORD written = 0;
        return WriteFile(file, data, size, &written, nullptr) != FALSE && written == size;
    }

    bool sidecarCaptureBackBuffer(std::string& outputPath, long& captureResult)
    {
        outputPath.clear();
        captureResult = E_FAIL;
        IDirect3DSurface9* backBuffer = nullptr;
        IDirect3DSurface9* resolved = nullptr;
        IDirect3DSurface9* systemSurface = nullptr;
        HANDLE file = INVALID_HANDLE_VALUE;
        bool surfaceLocked = false;
        bool complete = false;
        std::string temporaryPath;
        D3DSURFACE_DESC description = {};
        D3DLOCKED_RECT locked = {};
        unsigned long ordinal = 0;
        char name[64] = {};
        DWORD rowBytes = 0;
        unsigned long long imageBytes64 = 0;
        BITMAPFILEHEADER fileHeader = {};
        BITMAPINFOHEADER infoHeader = {};

        UInt8* renderer = nullptr;
        IDirect3DDevice9* device = nullptr;
        if (!safeRead(reinterpret_cast<const void*>(0x011F4748), renderer)
            || renderer == nullptr || !safeRead(renderer + 0x288, device) || device == nullptr)
        {
            captureResult = E_POINTER;
            return false;
        }

        HRESULT result = device->GetBackBuffer(0, 0, D3DBACKBUFFER_TYPE_MONO, &backBuffer);
        if (FAILED(result) || backBuffer == nullptr)
        {
            captureResult = result;
            goto cleanup;
        }
        result = backBuffer->GetDesc(&description);
        if (FAILED(result) || description.Width == 0 || description.Height == 0
            || description.Width > static_cast<UINT>(LONG_MAX)
            || description.Height > static_cast<UINT>(LONG_MAX)
            || (description.Format != D3DFMT_X8R8G8B8
                && description.Format != D3DFMT_A8R8G8B8))
        {
            captureResult = FAILED(result) ? result : D3DERR_INVALIDCALL;
            goto cleanup;
        }

        if (description.MultiSampleType != D3DMULTISAMPLE_NONE)
        {
            result = device->CreateRenderTarget(description.Width, description.Height,
                description.Format, D3DMULTISAMPLE_NONE, 0, FALSE, &resolved, nullptr);
            if (FAILED(result) || resolved == nullptr)
            {
                captureResult = result;
                goto cleanup;
            }
            result = device->StretchRect(backBuffer, nullptr, resolved, nullptr, D3DTEXF_NONE);
            if (FAILED(result))
            {
                captureResult = result;
                goto cleanup;
            }
        }

        result = device->CreateOffscreenPlainSurface(description.Width, description.Height,
            description.Format, D3DPOOL_SYSTEMMEM, &systemSurface, nullptr);
        if (FAILED(result) || systemSurface == nullptr)
        {
            captureResult = result;
            goto cleanup;
        }
        result = device->GetRenderTargetData(resolved != nullptr ? resolved : backBuffer, systemSurface);
        if (FAILED(result))
        {
            captureResult = result;
            goto cleanup;
        }
        result = systemSurface->LockRect(&locked, nullptr, D3DLOCK_READONLY);
        if (FAILED(result) || locked.pBits == nullptr
            || locked.Pitch < static_cast<INT>(description.Width * 4u))
        {
            captureResult = FAILED(result) ? result : D3DERR_INVALIDCALL;
            goto cleanup;
        }
        surfaceLocked = true;

        ordinal = gSidecarScreenshotBaseline.valid
            ? gSidecarScreenshotBaseline.ordinal + 1 : 0;
        for (unsigned int attempt = 0; attempt < 100000; ++attempt, ++ordinal)
        {
            sprintf_s(name, "ScreenShot%lu.bmp", ordinal);
            if (GetFileAttributesA(name) == INVALID_FILE_ATTRIBUTES
                && GetLastError() == ERROR_FILE_NOT_FOUND)
                break;
            name[0] = '\0';
        }
        if (name[0] == '\0')
        {
            captureResult = HRESULT_FROM_WIN32(ERROR_FILE_EXISTS);
            goto cleanup;
        }
        outputPath = name;
        temporaryPath = outputPath + ".tmp";
        DeleteFileA(temporaryPath.c_str());
        file = CreateFileA(temporaryPath.c_str(), GENERIC_WRITE, 0, nullptr,
            CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE)
        {
            captureResult = HRESULT_FROM_WIN32(GetLastError());
            goto cleanup;
        }

        rowBytes = description.Width * 4u;
        imageBytes64 = static_cast<unsigned long long>(rowBytes) * description.Height;
        if (imageBytes64 > MAXDWORD)
        {
            captureResult = HRESULT_FROM_WIN32(ERROR_FILE_TOO_LARGE);
            goto cleanup;
        }
        fileHeader.bfType = 0x4D42;
        fileHeader.bfOffBits = sizeof(fileHeader) + sizeof(infoHeader);
        fileHeader.bfSize = fileHeader.bfOffBits + static_cast<DWORD>(imageBytes64);
        infoHeader.biSize = sizeof(infoHeader);
        infoHeader.biWidth = static_cast<LONG>(description.Width);
        infoHeader.biHeight = -static_cast<LONG>(description.Height);
        infoHeader.biPlanes = 1;
        infoHeader.biBitCount = 32;
        infoHeader.biCompression = BI_RGB;
        infoHeader.biSizeImage = static_cast<DWORD>(imageBytes64);
        if (!sidecarWriteExact(file, &fileHeader, sizeof(fileHeader))
            || !sidecarWriteExact(file, &infoHeader, sizeof(infoHeader)))
        {
            captureResult = HRESULT_FROM_WIN32(GetLastError());
            goto cleanup;
        }
        for (UINT row = 0; row < description.Height; ++row)
        {
            const UInt8* source = static_cast<const UInt8*>(locked.pBits)
                + static_cast<std::size_t>(row) * locked.Pitch;
            if (!sidecarWriteExact(file, source, rowBytes))
            {
                captureResult = HRESULT_FROM_WIN32(GetLastError());
                goto cleanup;
            }
        }

        systemSurface->UnlockRect();
        surfaceLocked = false;
        if (FlushFileBuffers(file) == FALSE)
        {
            captureResult = HRESULT_FROM_WIN32(GetLastError());
            goto cleanup;
        }
        CloseHandle(file);
        file = INVALID_HANDLE_VALUE;
        if (MoveFileExA(temporaryPath.c_str(), outputPath.c_str(), MOVEFILE_WRITE_THROUGH) == FALSE)
        {
            captureResult = HRESULT_FROM_WIN32(GetLastError());
            goto cleanup;
        }
        complete = true;
        captureResult = S_OK;

    cleanup:
        if (surfaceLocked && systemSurface != nullptr)
            systemSurface->UnlockRect();
        if (file != INVALID_HANDLE_VALUE)
            CloseHandle(file);
        if (!complete && !temporaryPath.empty())
            DeleteFileA(temporaryPath.c_str());
        if (systemSurface != nullptr)
            systemSurface->Release();
        if (resolved != nullptr)
            resolved->Release();
        if (backBuffer != nullptr)
            backBuffer->Release();
        if (!complete)
            outputPath.clear();
        return complete;
    }

    SidecarScreenshotFile sidecarNewestScreenshot()
    {
        SidecarScreenshotFile newest;
        WIN32_FIND_DATAA data = {};
        HANDLE search = FindFirstFileA("ScreenShot*.bmp", &data);
        if (search == INVALID_HANDLE_VALUE)
            return newest;
        do
        {
            if ((data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0)
                continue;
            const char* name = data.cFileName;
            if (_strnicmp(name, "ScreenShot", 10) != 0)
                continue;
            const char* digits = name + 10;
            char* end = nullptr;
            const unsigned long ordinal = std::strtoul(digits, &end, 10);
            if (end == digits || _stricmp(end, ".bmp") != 0)
                continue;
            ULARGE_INTEGER writeTime = {};
            writeTime.LowPart = data.ftLastWriteTime.dwLowDateTime;
            writeTime.HighPart = data.ftLastWriteTime.dwHighDateTime;
            ULARGE_INTEGER size = {};
            size.LowPart = data.nFileSizeLow;
            size.HighPart = data.nFileSizeHigh;
            if (size.QuadPart < 54)
                continue;
            if (!newest.valid || writeTime.QuadPart > newest.writeTime
                || (writeTime.QuadPart == newest.writeTime && ordinal > newest.ordinal))
            {
                newest.valid = true;
                newest.ordinal = ordinal;
                newest.writeTime = writeTime.QuadPart;
                newest.size = size.QuadPart;
                newest.path = name;
            }
        } while (FindNextFileA(search, &data));
        FindClose(search);
        return newest;
    }

    bool sidecarScreenshotIsNew(
        const SidecarScreenshotFile& baseline, const SidecarScreenshotFile& candidate)
    {
        if (!candidate.valid)
            return false;
        if (!baseline.valid)
            return true;
        return candidate.writeTime > baseline.writeTime
            || (candidate.writeTime == baseline.writeTime && candidate.ordinal > baseline.ordinal);
    }

    UInt16 sidecarReadLe16(const UInt8* bytes)
    {
        return static_cast<UInt16>(bytes[0] | (static_cast<UInt16>(bytes[1]) << 8));
    }

    UInt32 sidecarReadLe32(const UInt8* bytes)
    {
        return static_cast<UInt32>(bytes[0]) | (static_cast<UInt32>(bytes[1]) << 8)
            | (static_cast<UInt32>(bytes[2]) << 16) | (static_cast<UInt32>(bytes[3]) << 24);
    }

    bool sidecarValidateClosedScreenshot(
        const SidecarScreenshotFile& candidate, SidecarScreenshotFile& validated)
    {
        validated = {};
        if (!candidate.valid || candidate.path.empty())
            return false;
        HANDLE file = CreateFileA(candidate.path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
        if (file == INVALID_HANDLE_VALUE)
            return false;

        BY_HANDLE_FILE_INFORMATION info = {};
        std::array<UInt8, 54> header = {};
        DWORD bytesRead = 0;
        const bool read = GetFileInformationByHandle(file, &info)
            && ReadFile(file, header.data(), static_cast<DWORD>(header.size()), &bytesRead, nullptr)
            && bytesRead == header.size();
        CloseHandle(file);
        if (!read)
            return false;

        ULARGE_INTEGER actualSize = {};
        actualSize.LowPart = info.nFileSizeLow;
        actualSize.HighPart = info.nFileSizeHigh;
        ULARGE_INTEGER actualWriteTime = {};
        actualWriteTime.LowPart = info.ftLastWriteTime.dwLowDateTime;
        actualWriteTime.HighPart = info.ftLastWriteTime.dwHighDateTime;
        if (actualSize.QuadPart != candidate.size || actualWriteTime.QuadPart != candidate.writeTime
            || header[0] != 'B' || header[1] != 'M')
            return false;

        const UInt32 declaredSize = sidecarReadLe32(header.data() + 2);
        const UInt32 pixelOffset = sidecarReadLe32(header.data() + 10);
        const UInt32 dibBytes = sidecarReadLe32(header.data() + 14);
        const SInt32 signedWidth = static_cast<SInt32>(sidecarReadLe32(header.data() + 18));
        const SInt32 signedHeight = static_cast<SInt32>(sidecarReadLe32(header.data() + 22));
        const UInt16 planes = sidecarReadLe16(header.data() + 26);
        const UInt16 bitsPerPixel = sidecarReadLe16(header.data() + 28);
        const UInt32 compression = sidecarReadLe32(header.data() + 30);
        if (declaredSize != actualSize.QuadPart || pixelOffset < header.size()
            || pixelOffset >= actualSize.QuadPart || dibBytes < 40 || signedWidth <= 0
            || signedWidth > 32768 || signedHeight == 0 || signedHeight == (std::numeric_limits<SInt32>::min)()
            || std::abs(signedHeight) > 32768 || planes != 1
            || (bitsPerPixel != 16 && bitsPerPixel != 24 && bitsPerPixel != 32)
            || (compression != BI_RGB && compression != BI_BITFIELDS))
            return false;

        validated = candidate;
        validated.width = static_cast<UInt32>(signedWidth);
        validated.height = static_cast<UInt32>(std::abs(signedHeight));
        validated.bitsPerPixel = bitsPerPixel;
        return true;
    }

    bool sidecarScreenshotStableAndComplete(
        const SidecarScreenshotFile& candidate, SidecarScreenshotFile& validated)
    {
        SidecarScreenshotFile complete;
        if (!sidecarValidateClosedScreenshot(candidate, complete))
        {
            gSidecarScreenshotCandidate = {};
            gSidecarScreenshotStableFrames = 0;
            return false;
        }
        const bool sameCandidate = gSidecarScreenshotCandidate.valid
            && gSidecarScreenshotCandidate.ordinal == complete.ordinal
            && gSidecarScreenshotCandidate.writeTime == complete.writeTime
            && gSidecarScreenshotCandidate.size == complete.size
            && gSidecarScreenshotCandidate.path == complete.path;
        gSidecarScreenshotCandidate = complete;
        gSidecarScreenshotStableFrames = sameCandidate ? gSidecarScreenshotStableFrames + 1 : 1;
        if (gSidecarScreenshotStableFrames < 2)
            return false;
        validated = complete;
        return true;
    }

    bool sidecarExtraListHasType(const ExtraDataList* list, UInt8 type)
    {
        ExtraDataList snapshot;
        if (!safeRead(list, snapshot))
            return false;
        const UInt32 byteIndex = type >> 3;
        return byteIndex < std::size(snapshot.m_presenceBitfield)
            && (snapshot.m_presenceBitfield[byteIndex] & (1u << (type & 7))) != 0;
    }

    bool sidecarEntryIsWorn(const ExtraContainerChanges::ExtendDataList* extendData)
    {
        if (extendData == nullptr)
            return false;
        auto* address = const_cast<ListNode<ExtraDataList>*>(&extendData->m_listHead);
        for (UInt32 visited = 0; address != nullptr && visited < 256; ++visited)
        {
            ListNode<ExtraDataList> node;
            if (!safeRead(address, node))
                break;
            if (node.data != nullptr
                && (sidecarExtraListHasType(node.data, kExtraData_Worn)
                    || sidecarExtraListHasType(node.data, kExtraData_WornLeft)))
                return true;
            address = node.next;
        }
        return false;
    }

    ExtraContainerChanges* sidecarFindContainerChanges(Actor* actor)
    {
        BSExtraData* address = nullptr;
        if (actor == nullptr || !safeRead(&actor->extraDataList.m_data, address))
            return nullptr;
        for (UInt32 visited = 0; address != nullptr && visited < 256; ++visited)
        {
            SidecarExtraDataHeader snapshot;
            if (!safeRead(address, snapshot))
                break;
            if (snapshot.type == kExtraData_ContainerChanges)
                return reinterpret_cast<ExtraContainerChanges*>(address);
            address = snapshot.next;
        }
        return nullptr;
    }

    bool sidecarReadInventory(Actor* actor, std::map<UInt32, SidecarInventoryItem>& result)
    {
        result.clear();
        TESForm* baseForm = nullptr;
        if (actor == nullptr || !safeRead(&actor->baseForm, baseForm) || baseForm == nullptr)
            return false;
        UInt8 baseType = 0;
        if (!safeRead(&baseForm->typeID, baseType)
            || (baseType != kFormType_TESNPC && baseType != kFormType_TESCreature))
            return false;

        TESActorBase* actorBase = static_cast<TESActorBase*>(baseForm);
        auto* baseAddress = actorBase->container.formCountList.Head();
        for (UInt32 visited = 0; baseAddress != nullptr && visited < 4096; ++visited)
        {
            ListNode<TESContainer::FormCount> node;
            if (!safeRead(baseAddress, node))
                break;
            TESContainer::FormCount entry = {};
            if (node.data != nullptr && safeRead(node.data, entry) && entry.form != nullptr)
            {
                UInt32 form = 0;
                if (safeRead(&entry.form->refID, form) && form != 0)
                {
                    SidecarInventoryItem& item = result[form];
                    item.form = entry.form;
                    item.count += entry.count;
                }
            }
            baseAddress = node.next;
        }

        ExtraContainerChanges* changes = sidecarFindContainerChanges(actor);
        ExtraContainerChanges::Data* changesData = nullptr;
        if (changes == nullptr
            || !safeRead(reinterpret_cast<const UInt8*>(changes) + 0x0C, changesData)
            || changesData == nullptr)
            return true;
        ExtraContainerChanges::Data data = {};
        if (!safeRead(changesData, data) || data.objList == nullptr)
            return true;
        auto* changeAddress = &data.objList->m_listHead;
        for (UInt32 visited = 0; changeAddress != nullptr && visited < 4096; ++visited)
        {
            ListNode<ExtraContainerChanges::EntryData> node;
            if (!safeRead(changeAddress, node))
                break;
            ExtraContainerChanges::EntryData entry = {};
            if (node.data != nullptr && safeRead(node.data, entry) && entry.type != nullptr)
            {
                UInt32 form = 0;
                if (safeRead(&entry.type->refID, form) && form != 0)
                {
                    SidecarInventoryItem& item = result[form];
                    item.form = entry.type;
                    item.count += entry.countDelta;
                    item.worn = item.worn || sidecarEntryIsWorn(entry.extendData);
                }
            }
            changeAddress = node.next;
        }
        return true;
    }

    UInt32 sidecarEquippedWeaponForm(Actor* actor)
    {
        if (actor == nullptr)
            return 0;
        BaseProcess* process = nullptr;
        if (!safeRead(&actor->baseProcess, process) || process == nullptr)
            return 0;
        UInt8 processLevel = 0xff;
        if (!safeRead(&process->processLevel, processLevel) || processLevel > 1)
            return 0;
        MiddleHighProcess* middleHigh = static_cast<MiddleHighProcess*>(process);
        MiddleHighProcess::WeaponInfo* weaponInfo = nullptr;
        if (!safeRead(&middleHigh->weaponInfo, weaponInfo) || weaponInfo == nullptr)
            return 0;
        TESObjectWEAP* weapon = nullptr;
        if (!safeRead(&weaponInfo->weapon, weapon) || weapon == nullptr)
            return 0;
        UInt32 result = 0;
        safeRead(&weapon->refID, result);
        return result;
    }

    struct SidecarVatsSnapshot
    {
        bool available = false;
        UInt32 mode = VATSCameraData::kVATSMode_None;
        UInt32 targetCount = 0;
        bool targetListTruncated = false;
        float actionPoints = 0.f;
        float health = 0.f;
        UInt32 equippedWeapon = 0;
        UInt32 linkedAmmo = 0;
        SInt32 linkedAmmoCount = 0;
        std::string firstTargetRecordHex;
    };

    bool sidecarReadActorValueUnsafe(PlayerCharacter* player, UInt32 actorValue, float& result)
    {
        bool accepted = false;
        __try
        {
            result = player->avOwner.Fn_03(actorValue);
            accepted = std::isfinite(result);
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            accepted = false;
        }
        return accepted;
    }

    SidecarVatsSnapshot sidecarReadVatsSnapshot()
    {
        SidecarVatsSnapshot result;
        PlayerCharacter* player = nullptr;
        if (!safeRead(reinterpret_cast<PlayerCharacter**>(0x011DEA3C), player) || player == nullptr)
            return result;

        VATSCameraData camera = {};
        VATSCameraData* cameraAddress = VATSCameraData::GetSingleton();
        if (cameraAddress == nullptr || !safeRead(cameraAddress, camera))
            return result;

        result.available = true;
        result.mode = camera.mode;
        if (!sidecarReadActorValueUnsafe(player, eActorVal_ActionPoints, result.actionPoints)
            || !sidecarReadActorValueUnsafe(player, eActorVal_Health, result.health))
        {
            result.available = false;
            return result;
        }

        if (camera.targets != nullptr)
        {
            auto* nodeAddress = camera.targets->Head();
            constexpr UInt32 maximumTargets = 256;
            for (; nodeAddress != nullptr && result.targetCount < maximumTargets;)
            {
                ListNode<void*> node = {};
                if (!safeRead(nodeAddress, node))
                    break;
                if (node.data != nullptr)
                {
                    ++result.targetCount;
                    if (result.firstTargetRecordHex.empty())
                    {
                        std::array<UInt8, 256> targetBytes = {};
                        if (safeRead(node.data, targetBytes))
                        {
                            static constexpr char hexDigits[] = "0123456789abcdef";
                            result.firstTargetRecordHex.reserve(targetBytes.size() * 2);
                            for (UInt8 value : targetBytes)
                            {
                                result.firstTargetRecordHex.push_back(hexDigits[value >> 4]);
                                result.firstTargetRecordHex.push_back(hexDigits[value & 0x0f]);
                            }
                        }
                    }
                }
                nodeAddress = node.next;
            }
            result.targetListTruncated = nodeAddress != nullptr;
        }

        result.equippedWeapon = sidecarEquippedWeaponForm(player);
        if (result.equippedWeapon != 0)
        {
            TESForm* form = lookupForm(result.equippedWeapon);
            UInt8 type = 0;
            if (form != nullptr && safeRead(&form->typeID, type) && type == kFormType_TESObjectWEAP)
            {
                TESForm* ammo = nullptr;
                if (safeRead(&static_cast<TESObjectWEAP*>(form)->ammo.ammo, ammo) && ammo != nullptr)
                {
                    safeRead(&ammo->refID, result.linkedAmmo);
                    std::map<UInt32, SidecarInventoryItem> inventory;
                    if (sidecarReadInventory(player, inventory))
                    {
                        const auto found = inventory.find(result.linkedAmmo);
                        if (found != inventory.end())
                            result.linkedAmmoCount = found->second.count;
                    }
                }
            }
        }
        return result;
    }

    void sidecarWriteVatsTelemetry(std::ostringstream& out)
    {
        const SidecarVatsSnapshot vats = sidecarReadVatsSnapshot();
        out << ",\"vats\":{\"available\":" << (vats.available ? "true" : "false");
        if (vats.available)
        {
            out << ",\"mode\":" << vats.mode
                << ",\"targetCount\":" << vats.targetCount
                << ",\"targetListTruncated\":" << (vats.targetListTruncated ? "true" : "false")
                << ",\"actionPoints\":" << vats.actionPoints
                << ",\"health\":" << vats.health
                << ",\"equippedWeapon\":" << vats.equippedWeapon
                << ",\"linkedAmmo\":" << vats.linkedAmmo
                << ",\"linkedAmmoCount\":" << vats.linkedAmmoCount
                << ",\"firstTargetRecordBytes\":256"
                << ",\"firstTargetRecordHex\":" << jsonString(vats.firstTargetRecordHex.c_str());
        }
        out << '}';
    }

    bool sidecarAddAndEquipUnsafe(Actor* actor, TESForm* requested)
    {
        bool applied = false;
        __try
        {
            actor->AddItem(requested, nullptr, 1);
            using ItemAction = void(__thiscall*)(
                Actor*, TESForm*, UInt32, ExtraDataList*, UInt32, bool, UInt32);
            reinterpret_cast<ItemAction>(0x0088C650)(actor, requested, 1, nullptr, 1, false, 1);
            applied = true;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            applied = false;
        }
        return applied;
    }

    bool sidecarApplyExactWeapon(Actor* actor, UInt32 requestedForm)
    {
        std::map<UInt32, SidecarInventoryItem> inventory;
        if (actor == nullptr || gConsole == nullptr || !sidecarReadInventory(actor, inventory))
            return false;
        bool accepted = true;
        for (const auto& pair : inventory)
        {
            UInt8 type = 0;
            if (pair.second.form != nullptr && safeRead(&pair.second.form->typeID, type)
                && type == kFormType_TESObjectWEAP)
            {
                char command[96] = {};
                sprintf_s(command, "RemoveItem %08X 2147483647", pair.first);
                accepted = gConsole->RunScriptLine2(command, actor, true) && accepted;
            }
        }
        if (requestedForm == 0)
            return accepted;
        TESForm* requested = lookupForm(requestedForm);
        UInt8 requestedType = 0;
        if (requested == nullptr || !safeRead(&requested->typeID, requestedType)
            || requestedType != kFormType_TESObjectWEAP)
            return false;
        return accepted && sidecarAddAndEquipUnsafe(actor, requested);
    }

    bool sidecarVerifyExactWeapon(Actor* actor, UInt32 requestedForm,
        std::map<UInt32, SidecarInventoryItem>* inventoryOut = nullptr)
    {
        std::map<UInt32, SidecarInventoryItem> inventory;
        if (!sidecarReadInventory(actor, inventory))
            return false;
        UInt32 positiveWeapons = 0;
        bool requestedExactlyOne = requestedForm == 0;
        for (const auto& pair : inventory)
        {
            UInt8 type = 0;
            if (pair.second.form == nullptr || !safeRead(&pair.second.form->typeID, type)
                || type != kFormType_TESObjectWEAP || pair.second.count <= 0)
                continue;
            ++positiveWeapons;
            if (pair.first == requestedForm && pair.second.count == 1)
                requestedExactlyOne = true;
        }
        const UInt32 equipped = sidecarEquippedWeaponForm(actor);
        if (inventoryOut != nullptr)
            *inventoryOut = inventory;
        return requestedForm == 0
            ? positiveWeapons == 0 && equipped == 0
            : positiveWeapons == 1 && requestedExactlyOne && equipped == requestedForm;
    }

    UInt32 sidecarHashAppend(UInt32 hash, const void* bytes, std::size_t size)
    {
        const UInt8* data = static_cast<const UInt8*>(bytes);
        for (std::size_t index = 0; index < size; ++index)
        {
            hash ^= data[index];
            hash *= 16777619u;
        }
        return hash;
    }

    bool sidecarReadFaceGenChannel(const TESNPC::FaceGenData* address,
        UInt32& count, UInt32& size, UInt32& usedBytes, UInt32& capacityBytes,
        UInt32& hash, std::vector<float>& values, bool& truncated)
    {
        TESNPC::FaceGenData channel = {};
        count = 0;
        size = 0;
        usedBytes = 0;
        capacityBytes = 0;
        hash = 2166136261u;
        values.clear();
        truncated = false;
        if (!safeRead(address, channel) || channel.count > 256 || channel.size > 64
            || static_cast<UInt64>(channel.count) * channel.size > 4096)
            return false;
        count = channel.count;
        size = channel.size;
        if (count == 0 || size == 0)
            return true;
        const UInt64 valueCount = static_cast<UInt64>(count) * size;
        const UInt64 requiredBytes = valueCount * sizeof(float);
        if (channel.values == nullptr || requiredBytes > 16384)
            return false;
        const std::uintptr_t usedEndAddress = static_cast<std::uintptr_t>(channel.useOffset);
        const std::uintptr_t capacityEndAddress = static_cast<std::uintptr_t>(channel.maxOffset);
        const std::uintptr_t valuesBaseAddress = reinterpret_cast<std::uintptr_t>(channel.values);
        if (usedEndAddress < valuesBaseAddress || capacityEndAddress < usedEndAddress)
            return false;
        const std::uintptr_t usedByteCount = usedEndAddress - valuesBaseAddress;
        const std::uintptr_t capacityByteCount = capacityEndAddress - valuesBaseAddress;
        if (usedByteCount < requiredBytes || capacityByteCount > 16384)
            return false;
        usedBytes = static_cast<UInt32>(usedByteCount);
        capacityBytes = static_cast<UInt32>(capacityByteCount);
        // Retail FGGS/FGGA/FGTS are contiguous float buffers. xNVSE's historical
        // reverse-engineered declaration calls this field float**, while useOffset/maxOffset
        // are absolute end pointers. Subtract the buffer base to recover Sunny's
        // 200/120/200 used bytes for 50/30/50 floats. Hash every authored value and
        // bound only the JSON enumeration.
        const float* contiguousValues = reinterpret_cast<const float*>(channel.values);
        constexpr std::size_t maximumReportedValues = 256;
        for (UInt32 rowIndex = 0; rowIndex < count; ++rowIndex)
        {
            for (UInt32 column = 0; column < size; ++column)
            {
                float value = 0.f;
                const UInt64 valueIndex = static_cast<UInt64>(rowIndex) * size + column;
                if (!safeRead(contiguousValues + valueIndex, value) || !std::isfinite(value))
                    return false;
                hash = sidecarHashAppend(hash, &value, sizeof(value));
                if (values.size() < maximumReportedValues)
                    values.push_back(value);
                else
                    truncated = true;
            }
        }
        return true;
    }

    void* sidecarGetSceneCameraUnsafe()
    {
        void* result = nullptr;
        __try
        {
            void* owner = reinterpret_cast<void*(__cdecl*)()>(0x0045C670)();
            result = owner != nullptr
                ? reinterpret_cast<void*(__thiscall*)(void*)>(0x006629F0)(owner) : nullptr;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            result = nullptr;
        }
        return result;
    }

    void sidecarWriteFinite(std::ostringstream& out, float value)
    {
        if (std::isfinite(value))
            out << value;
        else
            out << "null";
    }

    void sidecarWriteAnimationSequence(
        std::ostringstream& out, const BSAnimGroupSequence* address)
    {
        if (address == nullptr)
        {
            out << "null";
            return;
        }
        const UInt8* sequenceBytes = reinterpret_cast<const UInt8*>(address);
        char* fileAddress = nullptr;
        UInt32 state = 0;
        UInt32 cycle = 0;
        float weight = 0.f;
        float frequency = 0.f;
        float begin = 0.f;
        float end = 0.f;
        float last = 0.f;
        float lastScaled = 0.f;
        TESAnimGroup* animationGroup = nullptr;
        if (!safeRead(sequenceBytes + 0x08, fileAddress)
            || !safeRead(sequenceBytes + 0x1C, weight)
            || !safeRead(sequenceBytes + 0x24, cycle)
            || !safeRead(sequenceBytes + 0x28, frequency)
            || !safeRead(sequenceBytes + 0x2C, begin)
            || !safeRead(sequenceBytes + 0x30, end)
            || !safeRead(sequenceBytes + 0x34, last)
            || !safeRead(sequenceBytes + 0x3C, lastScaled)
            || !safeRead(sequenceBytes + 0x44, state)
            || !safeRead(sequenceBytes + 0x68, animationGroup))
        {
            out << "{\"readable\":false}";
            return;
        }
        UInt8 group = 0xff;
        if (animationGroup != nullptr)
            safeRead(&animationGroup->animGroup, group);
        const std::string file = safeRuntimeString(fileAddress);
        out << "{\"readable\":true,\"address\":"
            << reinterpret_cast<std::uintptr_t>(address)
            << ",\"file\":" << jsonString(file.c_str())
            << ",\"fileHash\":"
            << sidecarHashAppend(2166136261u, file.data(), file.size())
            << ",\"group\":" << static_cast<UInt32>(group)
            << ",\"state\":" << state
            << ",\"cycle\":" << cycle
            << ",\"weight\":";
        sidecarWriteFinite(out, weight);
        out << ",\"frequency\":";
        sidecarWriteFinite(out, frequency);
        out << ",\"begin\":";
        sidecarWriteFinite(out, begin);
        out << ",\"end\":";
        sidecarWriteFinite(out, end);
        out << ",\"last\":";
        sidecarWriteFinite(out, last);
        out << ",\"lastScaled\":";
        sidecarWriteFinite(out, lastScaled);
        out << '}';
    }

    void sidecarWriteAnimationTelemetry(std::ostringstream& out, Actor* actor)
    {
        BaseProcess* process = nullptr;
        UInt8 processLevel = 0xff;
        UInt8 lifeState = 0xff;
        UInt32 actorSitSleepState = 0;
        if (actor != nullptr)
        {
            safeRead(&actor->baseProcess, process);
            safeRead(&actor->lifeState, lifeState);
            safeRead(reinterpret_cast<const UInt8*>(actor) + 0x1AC, actorSitSleepState);
        }
        if (process != nullptr)
            safeRead(&process->processLevel, processLevel);
        const bool middleHigh = process != nullptr && processLevel <= 1;
        MiddleHighProcess* middle = middleHigh ? static_cast<MiddleHighProcess*>(process) : nullptr;
        HighProcess* high = processLevel == 0 ? static_cast<HighProcess*>(process) : nullptr;
        bool weaponOut = false;
        bool aiming = false;
        UInt8 processSitSleepState = 0xff;
        BSFaceGenAnimationData* faceAnimation = nullptr;
        BSFaceGenNiNode* faceNodeA = nullptr;
        BSFaceGenNiNode* faceNodeB = nullptr;
        NiTriShape* faceShape = nullptr;
        AnimData* animationData = nullptr;
        if (middle != nullptr)
        {
            safeRead(&middle->isWeaponOut, weaponOut);
            safeRead(&middle->isAiming, aiming);
            safeRead(reinterpret_cast<const UInt8*>(middle) + 0x13D, processSitSleepState);
            safeRead(&middle->unk178, faceAnimation);
            safeRead(&middle->unk248, faceNodeA);
            safeRead(&middle->unk24C, faceNodeB);
            safeRead(&middle->unk250, faceShape);
            safeRead(&middle->animData, animationData);
        }
        out << ",\"animation\":{";
        out << "\"processAvailable\":" << (process != nullptr ? "true" : "false")
            << ",\"processLevel\":" << static_cast<UInt32>(processLevel)
            << ",\"lifeState\":" << static_cast<UInt32>(lifeState)
            << ",\"actorSitSleepState\":" << actorSitSleepState
            << ",\"processSitSleepState\":" << static_cast<UInt32>(processSitSleepState)
            << ",\"weaponOut\":" << (weaponOut ? "true" : "false")
            << ",\"aiming\":" << (aiming ? "true" : "false")
            << ",\"facialRuntime\":{";
        out << "\"animationDataAvailable\":" << (faceAnimation != nullptr ? "true" : "false")
            << ",\"animationDataAddress\":" << reinterpret_cast<std::uintptr_t>(faceAnimation)
            << ",\"faceNodeAAddress\":" << reinterpret_cast<std::uintptr_t>(faceNodeA)
            << ",\"faceNodeBAddress\":" << reinterpret_cast<std::uintptr_t>(faceNodeB)
            << ",\"faceShapeAddress\":" << reinterpret_cast<std::uintptr_t>(faceShape) << '}';
        out << ",\"middleHighSequences\":[";
        for (UInt32 index = 0; index < 3; ++index)
        {
            if (index != 0)
                out << ',';
            BSAnimGroupSequence* sequence = nullptr;
            if (middle != nullptr)
                safeRead(&middle->animSequence[index], sequence);
            sidecarWriteAnimationSequence(out, sequence);
        }
        out << "],\"animDataSequences\":[";
        for (UInt32 index = 0; index < 8; ++index)
        {
            if (index != 0)
                out << ',';
            BSAnimGroupSequence* sequence = nullptr;
            if (high != nullptr && animationData != nullptr)
                safeRead(&animationData->animSequence[index], sequence);
            sidecarWriteAnimationSequence(out, sequence);
        }
        out << "]}";
    }

    bool sidecarHasEvaluatedAnimation(Actor* actor)
    {
        BaseProcess* process = nullptr;
        UInt8 processLevel = 0xff;
        if (actor == nullptr || !safeRead(&actor->baseProcess, process) || process == nullptr
            || !safeRead(&process->processLevel, processLevel) || processLevel > 1)
            return false;
        MiddleHighProcess* middle = static_cast<MiddleHighProcess*>(process);
        for (UInt32 index = 0; index < 3; ++index)
        {
            BSAnimGroupSequence* sequence = nullptr;
            if (safeRead(&middle->animSequence[index], sequence) && sequence != nullptr)
                return true;
        }
        AnimData* animationData = nullptr;
        if (!safeRead(&middle->animData, animationData) || animationData == nullptr)
            return false;
        for (UInt32 index = 0; index < 8; ++index)
        {
            BSAnimGroupSequence* sequence = nullptr;
            if (safeRead(&animationData->animSequence[index], sequence) && sequence != nullptr)
                return true;
        }
        return false;
    }

    bool sidecarReadFiniteTransform(
        const NiAVObject* object, std::size_t offset, NiTransform& transform)
    {
        if (object == nullptr
            || !safeRead(reinterpret_cast<const UInt8*>(object) + offset, transform))
            return false;

        for (float component : transform.rotate.data)
        {
            if (!std::isfinite(component))
                return false;
        }
        return std::isfinite(transform.translate.x) && std::isfinite(transform.translate.y)
            && std::isfinite(transform.translate.z) && std::isfinite(transform.scale)
            && transform.scale > 0.f && transform.scale < 1000.f;
    }

    UInt32 sidecarFloatBits(float value)
    {
        UInt32 bits = 0;
        static_assert(sizeof(bits) == sizeof(value));
        std::memcpy(&bits, &value, sizeof(bits));
        return bits;
    }

    constexpr UInt32 sSidecarNoSourceSlot = 0xFFFFFFFFu;
    constexpr UInt32 sSidecarAppearanceMaximumNodes = 8192;
    constexpr UInt32 sSidecarAppearanceMaximumCandidates = 128;
    constexpr UInt32 sSidecarAppearanceMaximumParts = 48;
    constexpr std::size_t sSidecarAppearanceMaximumJsonBytes = 23000;
    constexpr UInt64 sSidecarTextureMaximumCanonicalBytes = 64ull * 1024ull * 1024ull;
    const std::string sSidecarEmptyNodePath;

    struct SidecarTextureResource
    {
        bool valid = false;
        UInt32 width = 0;
        UInt32 height = 0;
        D3DFORMAT format = D3DFMT_UNKNOWN;
        UInt32 contentHash = 2166136261u;
    };

    struct SidecarTextureBinding
    {
        std::string semantic;
        std::string path;
        std::string contentHash;
        UInt32 width = 0;
        UInt32 height = 0;
        std::string format;
        std::string sourceKind;
        UInt32 stage = 0;
    };

    struct SidecarAppearanceAttachment
    {
        NiAVObject* root = nullptr;
        UInt32 sourceForm = 0;
        UInt8 sourceType = kFormType_None;
        UInt32 sourceSlot = sSidecarNoSourceSlot;
        std::string role;
        std::string modelPath;
        bool required = false;
        bool reached = false;
        bool emitted = false;
    };

    struct SidecarAppearanceSources
    {
        UInt32 actorBaseForm = 0;
        UInt32 raceForm = 0;
        UInt32 hairForm = 0;
        UInt32 eyesForm = 0;
    };

    struct SidecarRenderPart
    {
        std::string role;
        UInt32 sourceForm = 0;
        UInt32 sourceSlot = sSidecarNoSourceSlot;
        UInt32 ordinal = 0;
        bool required = false;
        bool attached = false;
        bool drawable = false;
        bool visible = false;
        bool skinSurface = false;
        UInt32 alphaBits = 0x3F800000u;
        std::string modelHash;
        std::string nodeHash;
        std::string geometryHash;
        std::vector<SidecarTextureBinding> textureBindings;
        std::string stableKey;
        std::string deterministicKey;
    };

    struct SidecarAppearanceCapture
    {
        SidecarAppearanceSources sources;
        std::vector<SidecarAppearanceAttachment> attachments;
        std::vector<SidecarRenderPart> parts;
        std::map<const NiTexture*, SidecarTextureResource> textureCache;
        std::set<const NiAVObject*> visitedObjects;
        UInt32 visitedNodes = 0;
        UInt32 geometryCandidates = 0;
        bool traversalTruncated = false;
        bool evidenceComplete = true;
    };

    NiNode* sidecarActorRootUnsafe(Actor* actor);

    std::string sidecarLowerAscii(std::string value)
    {
        std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
            return static_cast<char>(std::tolower(character));
        });
        return value;
    }

    std::string sidecarNormalizeAssetPath(std::string value)
    {
        while (!value.empty() && std::isspace(static_cast<unsigned char>(value.front())))
            value.erase(value.begin());
        while (!value.empty() && std::isspace(static_cast<unsigned char>(value.back())))
            value.pop_back();
        for (char& character : value)
        {
            if (character == '\\')
                character = '/';
            else
                character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
        }
        std::string normalized;
        normalized.reserve(value.size());
        bool previousSlash = false;
        for (char character : value)
        {
            const bool slash = character == '/';
            if (!slash || !previousSlash)
                normalized.push_back(character);
            previousSlash = slash;
        }
        while (normalized.rfind("./", 0) == 0)
            normalized.erase(0, 2);
        while (!normalized.empty() && normalized.front() == '/')
            normalized.erase(normalized.begin());
        if (normalized.rfind("data/", 0) == 0)
            normalized.erase(0, 5);
        return normalized;
    }

    std::string sidecarNormalizeNodeToken(std::string value)
    {
        value = sidecarLowerAscii(value);
        std::string normalized;
        normalized.reserve(value.size());
        bool previousSpace = false;
        for (const unsigned char character : value)
        {
            const bool space = std::isspace(character) != 0;
            if (!space || !previousSpace)
                normalized.push_back(space ? ' ' : static_cast<char>(character));
            previousSpace = space;
        }
        while (!normalized.empty() && normalized.front() == ' ')
            normalized.erase(normalized.begin());
        while (!normalized.empty() && normalized.back() == ' ')
            normalized.pop_back();
        return normalized;
    }

    std::string sidecarHashLabel(const char* prefix, UInt32 hash)
    {
        std::ostringstream out;
        out << prefix << std::hex << std::nouppercase << std::setw(8) << std::setfill('0') << hash;
        return out.str();
    }

    std::string sidecarHashText(const std::string& value)
    {
        return sidecarHashLabel("fnv1a32:",
            sidecarHashAppend(2166136261u, value.data(), value.size()));
    }

    std::string sidecarFormatFormId(UInt32 form)
    {
        std::ostringstream out;
        out << "0x" << std::hex << std::uppercase << std::setw(8) << std::setfill('0') << form;
        return out.str();
    }

    bool sidecarHashReadableBytes(
        UInt32& hash, const UInt8* address, std::size_t byteCount, UInt64& canonicalBytes)
    {
        if (address == nullptr || canonicalBytes + byteCount > sSidecarTextureMaximumCanonicalBytes)
            return false;
        std::array<UInt8, 4096> buffer = {};
        std::size_t offset = 0;
        while (offset < byteCount)
        {
            const std::size_t chunk = (std::min)(buffer.size(), byteCount - offset);
            SIZE_T bytesRead = 0;
            if (ReadProcessMemory(GetCurrentProcess(), address + offset, buffer.data(), chunk,
                    &bytesRead) == FALSE || bytesRead != chunk)
                return false;
            hash = sidecarHashAppend(hash, buffer.data(), chunk);
            offset += chunk;
        }
        canonicalBytes += byteCount;
        return true;
    }

    bool sidecarTextureRowLayout(
        D3DFORMAT format, UInt32 width, UInt32 height, UInt32& rowBytes, UInt32& rowCount)
    {
        if (width == 0 || height == 0 || width > 32768 || height > 32768)
            return false;
        switch (format)
        {
            case D3DFMT_DXT1:
            case static_cast<D3DFORMAT>(MAKEFOURCC('A', 'T', 'I', '1')):
            case static_cast<D3DFORMAT>(MAKEFOURCC('B', 'C', '4', 'U')):
                rowBytes = (std::max)(static_cast<UInt32>(1),
                    (width + static_cast<UInt32>(3)) / static_cast<UInt32>(4))
                    * static_cast<UInt32>(8);
                rowCount = (std::max)(static_cast<UInt32>(1),
                    (height + static_cast<UInt32>(3)) / static_cast<UInt32>(4));
                return true;
            case D3DFMT_DXT2:
            case D3DFMT_DXT3:
            case D3DFMT_DXT4:
            case D3DFMT_DXT5:
            case static_cast<D3DFORMAT>(MAKEFOURCC('A', 'T', 'I', '2')):
            case static_cast<D3DFORMAT>(MAKEFOURCC('B', 'C', '5', 'U')):
                rowBytes = (std::max)(static_cast<UInt32>(1),
                    (width + static_cast<UInt32>(3)) / static_cast<UInt32>(4))
                    * static_cast<UInt32>(16);
                rowCount = (std::max)(static_cast<UInt32>(1),
                    (height + static_cast<UInt32>(3)) / static_cast<UInt32>(4));
                return true;
            case D3DFMT_R8G8B8:
                rowBytes = width * 3u;
                rowCount = height;
                return true;
            case D3DFMT_A8R8G8B8:
            case D3DFMT_X8R8G8B8:
            case D3DFMT_A8B8G8R8:
            case D3DFMT_X8B8G8R8:
            case D3DFMT_G16R16:
            case D3DFMT_R32F:
            case D3DFMT_G16R16F:
                rowBytes = width * 4u;
                rowCount = height;
                return true;
            case D3DFMT_R5G6B5:
            case D3DFMT_X1R5G5B5:
            case D3DFMT_A1R5G5B5:
            case D3DFMT_A4R4G4B4:
            case D3DFMT_A8L8:
            case D3DFMT_V8U8:
            case D3DFMT_L6V5U5:
            case D3DFMT_R16F:
                rowBytes = width * 2u;
                rowCount = height;
                return true;
            case D3DFMT_A8:
            case D3DFMT_L8:
            case D3DFMT_P8:
            case D3DFMT_A4L4:
                rowBytes = width;
                rowCount = height;
                return true;
            case D3DFMT_A16B16G16R16:
            case D3DFMT_Q16W16V16U16:
            case D3DFMT_A16B16G16R16F:
            case D3DFMT_G32R32F:
                rowBytes = width * 8u;
                rowCount = height;
                return true;
            case D3DFMT_A32B32G32R32F:
                rowBytes = width * 16u;
                rowCount = height;
                return true;
            default:
                return false;
        }
    }

    bool sidecarHashLockedRows(UInt32& hash, const void* bits, SInt32 pitch,
        UInt32 rowBytes, UInt32 rowCount, UInt64& canonicalBytes)
    {
        if (bits == nullptr || pitch <= 0 || static_cast<UInt32>(pitch) < rowBytes)
            return false;
        for (UInt32 row = 0; row < rowCount; ++row)
        {
            const UInt8* address = static_cast<const UInt8*>(bits)
                + static_cast<std::size_t>(row) * static_cast<UInt32>(pitch);
            if (!sidecarHashReadableBytes(hash, address, rowBytes, canonicalBytes))
                return false;
        }
        return true;
    }

    bool sidecarObserveTexture2D(IDirect3DTexture9* texture, SidecarTextureResource& observed)
    {
        if (texture == nullptr)
            return false;
        const UINT levels = texture->GetLevelCount();
        if (levels == 0 || levels > 32)
            return false;
        UInt32 hash = 2166136261u;
        UInt64 canonicalBytes = 0;
        for (UINT level = 0; level < levels; ++level)
        {
            D3DSURFACE_DESC description = {};
            if (FAILED(texture->GetLevelDesc(level, &description)))
                return false;
            UInt32 rowBytes = 0;
            UInt32 rowCount = 0;
            if (!sidecarTextureRowLayout(description.Format, description.Width,
                    description.Height, rowBytes, rowCount))
                return false;
            if (level == 0)
            {
                observed.width = description.Width;
                observed.height = description.Height;
                observed.format = description.Format;
            }
            else if (description.Format != observed.format)
                return false;
            D3DLOCKED_RECT locked = {};
            if (FAILED(texture->LockRect(level, &locked, nullptr, D3DLOCK_READONLY)))
                return false;
            const bool hashed = sidecarHashLockedRows(hash, locked.pBits, locked.Pitch,
                rowBytes, rowCount, canonicalBytes);
            const HRESULT unlocked = texture->UnlockRect(level);
            if (!hashed || FAILED(unlocked))
                return false;
        }
        observed.contentHash = hash;
        observed.valid = true;
        return true;
    }

    bool sidecarObserveTextureCube(
        IDirect3DCubeTexture9* texture, SidecarTextureResource& observed)
    {
        if (texture == nullptr)
            return false;
        const UINT levels = texture->GetLevelCount();
        if (levels == 0 || levels > 32)
            return false;
        UInt32 hash = 2166136261u;
        UInt64 canonicalBytes = 0;
        for (UINT level = 0; level < levels; ++level)
        {
            D3DSURFACE_DESC description = {};
            if (FAILED(texture->GetLevelDesc(level, &description)))
                return false;
            UInt32 rowBytes = 0;
            UInt32 rowCount = 0;
            if (!sidecarTextureRowLayout(description.Format, description.Width,
                    description.Height, rowBytes, rowCount))
                return false;
            if (level == 0)
            {
                observed.width = description.Width;
                observed.height = description.Height;
                observed.format = description.Format;
            }
            else if (description.Format != observed.format)
                return false;
            for (UInt32 face = 0; face < 6; ++face)
            {
                D3DLOCKED_RECT locked = {};
                if (FAILED(texture->LockRect(static_cast<D3DCUBEMAP_FACES>(face), level,
                        &locked, nullptr, D3DLOCK_READONLY)))
                    return false;
                const bool hashed = sidecarHashLockedRows(hash, locked.pBits, locked.Pitch,
                    rowBytes, rowCount, canonicalBytes);
                const HRESULT unlocked = texture->UnlockRect(
                    static_cast<D3DCUBEMAP_FACES>(face), level);
                if (!hashed || FAILED(unlocked))
                    return false;
            }
        }
        observed.contentHash = hash;
        observed.valid = true;
        return true;
    }

    bool sidecarObserveTextureVolume(
        IDirect3DVolumeTexture9* texture, SidecarTextureResource& observed)
    {
        if (texture == nullptr)
            return false;
        const UINT levels = texture->GetLevelCount();
        if (levels == 0 || levels > 32)
            return false;
        UInt32 hash = 2166136261u;
        UInt64 canonicalBytes = 0;
        for (UINT level = 0; level < levels; ++level)
        {
            D3DVOLUME_DESC description = {};
            if (FAILED(texture->GetLevelDesc(level, &description)))
                return false;
            UInt32 rowBytes = 0;
            UInt32 rowCount = 0;
            if (!sidecarTextureRowLayout(description.Format, description.Width,
                    description.Height, rowBytes, rowCount)
                || description.Depth == 0 || description.Depth > 2048)
                return false;
            if (level == 0)
            {
                observed.width = description.Width;
                observed.height = description.Height;
                observed.format = description.Format;
            }
            else if (description.Format != observed.format)
                return false;
            D3DLOCKED_BOX locked = {};
            if (FAILED(texture->LockBox(level, &locked, nullptr, D3DLOCK_READONLY)))
                return false;
            bool hashed = locked.pBits != nullptr && locked.RowPitch > 0 && locked.SlicePitch > 0
                && static_cast<UInt32>(locked.RowPitch) >= rowBytes;
            if (hashed)
            {
                for (UInt32 slice = 0; slice < description.Depth && hashed; ++slice)
                {
                    const UInt8* sliceAddress = static_cast<const UInt8*>(locked.pBits)
                        + static_cast<std::size_t>(slice) * static_cast<UInt32>(locked.SlicePitch);
                    hashed = sidecarHashLockedRows(hash, sliceAddress, locked.RowPitch,
                        rowBytes, rowCount, canonicalBytes);
                }
            }
            const HRESULT unlocked = texture->UnlockBox(level);
            if (!hashed || FAILED(unlocked))
                return false;
        }
        observed.contentHash = hash;
        observed.valid = true;
        return true;
    }

    bool sidecarObserveTextureResourceUnsafe(
        NiTexture* texture, SidecarTextureResource& observed)
    {
        observed = {};
        UInt8* textureData = nullptr;
        IDirect3DBaseTexture9* resource = nullptr;
        if (texture == nullptr
            || !safeRead(reinterpret_cast<const UInt8*>(texture) + 0x24, textureData)
            || textureData == nullptr
            || !safeRead(textureData + 0x64, resource) || resource == nullptr)
            return false;
        switch (resource->GetType())
        {
            case D3DRTYPE_TEXTURE:
                return sidecarObserveTexture2D(
                    static_cast<IDirect3DTexture9*>(resource), observed);
            case D3DRTYPE_CUBETEXTURE:
                return sidecarObserveTextureCube(
                    static_cast<IDirect3DCubeTexture9*>(resource), observed);
            case D3DRTYPE_VOLUMETEXTURE:
                return sidecarObserveTextureVolume(
                    static_cast<IDirect3DVolumeTexture9*>(resource), observed);
            default:
                return false;
        }
    }

    bool sidecarObserveTextureResource(
        NiTexture* texture, SidecarTextureResource& observed)
    {
        bool result = false;
        __try
        {
            result = sidecarObserveTextureResourceUnsafe(texture, observed);
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            observed = {};
            result = false;
        }
        return result;
    }

    std::string sidecarTextureFormat(D3DFORMAT format)
    {
        return "d3d9:" + std::to_string(static_cast<UInt32>(format));
    }

    bool sidecarLooksLikeAssetPath(const std::string& path)
    {
        if (path.empty() || path.size() > 512 || path.back() == '/'
            || (path.find('.') == std::string::npos && path.find('/') == std::string::npos))
            return false;
        for (const unsigned char character : path)
        {
            if (character < 0x20 || character >= 0x7F)
                return false;
        }
        return true;
    }

    std::string sidecarNormalizeTexturePath(std::string value)
    {
        value = sidecarNormalizeAssetPath(std::move(value));
        const std::size_t embedded = value.find("/textures/");
        if (embedded != std::string::npos)
            value.erase(0, embedded + 1);
        else if (value.rfind("textures/", 0) != 0 && value.rfind("runtime/", 0) != 0
            && value.find('.') != std::string::npos && sidecarLooksLikeAssetPath(value))
            value.insert(0, "textures/");
        return value;
    }

    std::string sidecarRuntimeTexturePath(NiTexture* texture)
    {
        if (texture == nullptr)
            return {};
        for (const std::size_t offset : { std::size_t(0x30), std::size_t(0x34),
                 std::size_t(0x38) })
        {
            char* address = nullptr;
            if (!safeRead(reinterpret_cast<const UInt8*>(texture) + offset, address))
                continue;
            const std::string path = sidecarNormalizeTexturePath(safeRuntimeString(address));
            if (sidecarLooksLikeAssetPath(path))
                return path;
        }
        return {};
    }

    std::string sidecarTextureSemantic(
        const std::string& role, bool skinSurface, UInt32 stage)
    {
        if (skinSurface)
        {
            constexpr const char* semantics[6]
                = { "baseColor", "normal", "faceGenDetail", "bodyColor",
                    "skinScatter", "environmentMask" };
            return semantics[stage < 6 ? stage : 5];
        }
        const char* prefix = "actor";
        if (role == "equipment") prefix = "gear";
        else if (role == "weapon") prefix = "weapon";
        else if (role == "hair") prefix = "hair";
        else if (role == "eyes") prefix = "eye";
        else if (role == "headPart") prefix = "headPart";
        constexpr const char* suffixes[6]
            = { "Color", "Normal", "Glow", "Parallax", "Environment", "EnvironmentMask" };
        return std::string(prefix) + suffixes[stage < 6 ? stage : 5];
    }

    void sidecarAppendTextureBinding(SidecarAppearanceCapture& capture,
        SidecarRenderPart& part, UInt32 stage, std::string path, NiTexture* texture,
        const char* pathSourceKind)
    {
        path = sidecarNormalizeTexturePath(std::move(path));
        if (path.empty())
            path = sidecarRuntimeTexturePath(texture);
        if (!sidecarLooksLikeAssetPath(path) || texture == nullptr)
        {
            if (!path.empty() || texture != nullptr)
                capture.evidenceComplete = false;
            return;
        }

        auto found = capture.textureCache.find(texture);
        if (found == capture.textureCache.end())
        {
            SidecarTextureResource observed;
            sidecarObserveTextureResource(texture, observed);
            found = capture.textureCache.emplace(texture, observed).first;
        }
        const SidecarTextureResource& observed = found->second;
        if (!observed.valid)
        {
            capture.evidenceComplete = false;
            return;
        }

        SidecarTextureBinding binding;
        binding.semantic = sidecarTextureSemantic(part.role, part.skinSurface, stage);
        binding.path = std::move(path);
        binding.contentHash = sidecarHashLabel("d3d9-fnv1a32:", observed.contentHash);
        binding.width = observed.width;
        binding.height = observed.height;
        binding.format = sidecarTextureFormat(observed.format);
        const bool generated = binding.path.find("/facemods/") != std::string::npos
            || binding.path.find("/bodymods/") != std::string::npos
            || binding.path.find("facegen") != std::string::npos
            || binding.path.rfind("runtime/falloutnv/", 0) == 0;
        binding.sourceKind = generated ? "generated" : pathSourceKind;
        binding.stage = stage;
        part.textureBindings.push_back(std::move(binding));
    }

    void sidecarCollectShaderTextures(SidecarAppearanceCapture& capture,
        SidecarRenderPart& part, NiObject* shaderProperty, const std::string& shaderRuntimeType)
    {
        if (shaderProperty == nullptr)
            return;
        UInt32 shaderType = 0;
        safeRead(reinterpret_cast<const UInt8*>(shaderProperty) + 0x1C, shaderType);
        const bool textureSetShader
            = shaderRuntimeType.find("PPLighting") != std::string::npos
            || shaderRuntimeType.find("Lighting30") != std::string::npos
            || shaderType == 8 || shaderType == 9 || shaderType == 12;
        if (textureSetShader)
        {
            UInt8* textureSet = nullptr;
            safeRead(reinterpret_cast<const UInt8*>(shaderProperty) + 0xA4, textureSet);
            for (UInt32 stage = 0; stage < 6; ++stage)
            {
                char* pathAddress = nullptr;
                NiTexture** textureAddress = nullptr;
                NiTexture* texture = nullptr;
                if (textureSet != nullptr)
                    safeRead(textureSet + 0x08 + stage * sizeof(String), pathAddress);
                safeRead(reinterpret_cast<const UInt8*>(shaderProperty) + 0xAC
                        + stage * sizeof(NiTexture**), textureAddress);
                if (textureAddress != nullptr)
                    safeRead(textureAddress, texture);
                const std::string path = sidecarNormalizeAssetPath(safeRuntimeString(pathAddress));
                if (!path.empty() || texture != nullptr)
                    sidecarAppendTextureBinding(capture, part, stage, path, texture,
                        path.empty() ? "runtime" : "authored");
            }
            return;
        }

        if (shaderRuntimeType.find("NoLighting") != std::string::npos || shaderType == 0x15)
        {
            NiTexture* texture = nullptr;
            char* pathAddress = nullptr;
            safeRead(reinterpret_cast<const UInt8*>(shaderProperty) + 0x60, texture);
            safeRead(reinterpret_cast<const UInt8*>(shaderProperty) + 0x64, pathAddress);
            const std::string path = sidecarNormalizeAssetPath(safeRuntimeString(pathAddress));
            if (!path.empty() || texture != nullptr)
                sidecarAppendTextureBinding(capture, part, 0, path, texture,
                    path.empty() ? "runtime" : "authored");
        }
    }

    UInt32 sidecarAppearanceRoleRank(const std::string& role)
    {
        if (role == "face") return 0;
        if (role == "leftHand") return 1;
        if (role == "rightHand") return 2;
        if (role == "exposedBody") return 3;
        if (role == "hair") return 4;
        if (role == "eyes") return 5;
        if (role == "weapon") return 6;
        if (role == "equipment") return 7;
        if (role == "headPart") return 8;
        return 9;
    }

    std::string sidecarClassifyAppearanceRole(
        const std::string& inheritedRole, const std::string& nodePath)
    {
        if (inheritedRole == "equipment" || inheritedRole == "weapon")
            return inheritedRole;
        const std::string value = sidecarLowerAscii(nodePath);
        if (value.find("facegeneye") != std::string::npos
            || value.find("/eye") != std::string::npos
            || value.find("eyes") != std::string::npos)
            return "eyes";
        if (value.find("hair") != std::string::npos)
            return "hair";
        if (value.find("lefthand") != std::string::npos
            || value.find("left hand") != std::string::npos)
            return "leftHand";
        if (value.find("righthand") != std::string::npos
            || value.find("right hand") != std::string::npos)
            return "rightHand";
        if (value.find("facegenaccessory") != std::string::npos
            || value.find("headpart") != std::string::npos)
            return "headPart";
        if (value.find("facegenface") != std::string::npos)
            return "face";
        if (value.find("facegen") != std::string::npos
            || value.find("headanims") != std::string::npos
            || value.find("teeth") != std::string::npos
            || value.find("tongue") != std::string::npos
            || value.find("mouth") != std::string::npos)
            return "headPart";
        if (value.find("upperbody") != std::string::npos
            || value.find("meatcapbody") != std::string::npos
            || value.find("/arms") != std::string::npos
            || value.find("body") != std::string::npos)
            return "exposedBody";
        return inheritedRole.empty() ? "actor" : inheritedRole;
    }

    UInt32 sidecarAppearanceRoleSource(const SidecarAppearanceCapture& capture,
        const SidecarAppearanceAttachment* attachment, const std::string& role)
    {
        if (attachment != nullptr && attachment->sourceForm != 0
            && attachment->sourceType != kFormType_TESRace
            && attachment->sourceType != kFormType_TESNPC)
            return attachment->sourceForm;
        if (role == "hair" && capture.sources.hairForm != 0)
            return capture.sources.hairForm;
        if (role == "eyes" && capture.sources.eyesForm != 0)
            return capture.sources.eyesForm;
        if ((role == "leftHand" || role == "rightHand" || role == "exposedBody")
            && capture.sources.raceForm != 0)
            return capture.sources.raceForm;
        if (attachment != nullptr && attachment->sourceForm != 0)
            return attachment->sourceForm;
        return capture.sources.actorBaseForm;
    }

    std::string sidecarAttachmentRole(UInt8 formType, UInt32 slot)
    {
        if (formType == kFormType_TESObjectWEAP || slot == 5)
            return "weapon";
        if (formType == kFormType_TESObjectARMO || formType == kFormType_TESObjectCLOT)
            return "equipment";
        if (formType == kFormType_BGSHeadPart)
            return "headPart";
        if (formType == kFormType_TESHair)
            return "hair";
        if (formType == kFormType_TESEyes)
            return "eyes";
        switch (slot)
        {
            case 0: return "face";
            case 1: return "hair";
            case 2: return "exposedBody";
            case 3: return "leftHand";
            case 4: return "rightHand";
            default: return "actor";
        }
    }

    void sidecarCollectAppearanceSourcesAndAttachments(
        Actor* actor, SidecarAppearanceCapture& capture)
    {
        TESForm* actorBase = nullptr;
        UInt8 actorBaseType = kFormType_None;
        if (actor == nullptr || !safeRead(&actor->baseForm, actorBase) || actorBase == nullptr
            || !safeRead(&actorBase->typeID, actorBaseType))
            return;
        safeRead(&actorBase->refID, capture.sources.actorBaseForm);
        if (actorBaseType != kFormType_TESNPC)
            return;

        TESNPC* npc = static_cast<TESNPC*>(actorBase);
        TESRace* race = nullptr;
        TESHair* hair = nullptr;
        TESEyes* eyes = nullptr;
        safeRead(&npc->race.race, race);
        safeRead(&npc->hair, hair);
        safeRead(&npc->eyes, eyes);
        if (race != nullptr)
            safeRead(&race->refID, capture.sources.raceForm);
        if (hair != nullptr)
            safeRead(&hair->refID, capture.sources.hairForm);
        if (eyes != nullptr)
            safeRead(&eyes->refID, capture.sources.eyesForm);

        ValidBip01Names* slots = nullptr;
        if (!safeRead(&static_cast<Character*>(actor)->validBip01Names, slots) || slots == nullptr)
            return;
        for (UInt32 slot = 0; slot < 20; ++slot)
        {
            ValidBip01Names::Data data = {};
            if (!safeRead(&slots->unk002C[slot], data)
                || (data.model == nullptr && data.texture == nullptr && data.bones == nullptr))
                continue;
            SidecarAppearanceAttachment attachment;
            attachment.root = data.bones;
            attachment.sourceSlot = slot;
            attachment.required = data.model != nullptr || data.texture != nullptr;
            if (data.model != nullptr)
            {
                safeRead(&data.model->refID, attachment.sourceForm);
                safeRead(&data.model->typeID, attachment.sourceType);
            }
            if (attachment.sourceForm == 0)
            {
                attachment.sourceForm = slot >= 2 && slot <= 4
                    ? capture.sources.raceForm : capture.sources.actorBaseForm;
            }
            attachment.role = sidecarAttachmentRole(attachment.sourceType, slot);
            if (data.texture != nullptr)
            {
                char* modelAddress = nullptr;
                if (safeRead(&data.texture->nifPath.m_data, modelAddress))
                    attachment.modelPath
                        = sidecarNormalizeAssetPath(safeRuntimeString(modelAddress));
            }
            capture.attachments.push_back(std::move(attachment));
        }
        std::sort(capture.attachments.begin(), capture.attachments.end(),
            [](const SidecarAppearanceAttachment& left,
                const SidecarAppearanceAttachment& right) {
                if (left.role != right.role) return left.role < right.role;
                if (left.sourceForm != right.sourceForm) return left.sourceForm < right.sourceForm;
                if (left.sourceSlot != right.sourceSlot) return left.sourceSlot < right.sourceSlot;
                return left.modelPath < right.modelPath;
            });
    }

    SidecarAppearanceAttachment* sidecarFindAttachmentAt(
        SidecarAppearanceCapture& capture, NiAVObject* object)
    {
        for (SidecarAppearanceAttachment& attachment : capture.attachments)
        {
            if (attachment.root == object)
                return &attachment;
        }
        return nullptr;
    }

    std::string sidecarRenderPartStableKey(const SidecarRenderPart& part)
    {
        std::ostringstream key;
        key << sidecarAppearanceRoleRank(part.role) << '|' << part.role << '|'
            << std::setw(8) << std::setfill('0') << std::hex << part.sourceForm << '|'
            << std::setw(8) << part.sourceSlot << '|' << part.nodeHash << '|'
            << part.modelHash << '|' << part.geometryHash;
        for (const SidecarTextureBinding& binding : part.textureBindings)
        {
            key << '|' << binding.stage << ':' << binding.semantic << ':' << binding.path
                << ':' << binding.sourceKind;
        }
        return key.str();
    }

    std::string sidecarRenderPartDeterministicKey(const SidecarRenderPart& part)
    {
        std::ostringstream key;
        key << part.alphaBits << '|' << (part.required ? '1' : '0')
            << (part.attached ? '1' : '0') << (part.drawable ? '1' : '0')
            << (part.visible ? '1' : '0');
        for (const SidecarTextureBinding& binding : part.textureBindings)
        {
            key << '|' << binding.stage << ':' << binding.semantic << ':' << binding.path
                << ':' << binding.contentHash << ':' << binding.width << 'x' << binding.height
                << ':' << binding.format << ':' << binding.sourceKind;
        }
        return key.str();
    }

    void sidecarCollectAppearanceRecursive(SidecarAppearanceCapture& capture,
        NiAVObject* object, SidecarAppearanceAttachment* inheritedAttachment,
        const std::string& parentPath, bool ancestorHidden, UInt32 depth)
    {
        if (object == nullptr)
            return;
        if (depth > 64 || capture.visitedNodes >= sSidecarAppearanceMaximumNodes)
        {
            capture.traversalTruncated = true;
            return;
        }
        if (!capture.visitedObjects.insert(object).second)
            return;
        ++capture.visitedNodes;

        SidecarAppearanceAttachment* attachment = sidecarFindAttachmentAt(capture, object);
        if (attachment == nullptr)
            attachment = inheritedAttachment;
        else
            attachment->reached = true;

        char* nameAddress = nullptr;
        safeRead(&object->m_pcName, nameAddress);
        std::string token = sidecarNormalizeNodeToken(safeRuntimeString(nameAddress));
        const std::string runtimeType
            = safeRuntimeString(runtimeTypeName(reinterpret_cast<NiObject*>(object)));
        if (token.empty())
            token = sidecarNormalizeNodeToken(runtimeType);
        const std::string nodePath = parentPath.empty() ? token : parentPath + '/' + token;

        UInt32 flags = 0;
        const bool flagsReadable
            = safeRead(reinterpret_cast<const UInt8*>(object) + 0x30, flags);
        const bool hidden = ancestorHidden || !flagsReadable
            || (flags & (0x00000001u | 0x00100000u)) != 0;
        if (isOracleGeometryType(runtimeType))
        {
            ++capture.geometryCandidates;
            if (capture.parts.size() >= sSidecarAppearanceMaximumCandidates)
                capture.traversalTruncated = true;
            else
            {
                NiObject* materialProperty = nullptr;
                NiObject* shaderProperty = nullptr;
                OracleGeometryData* geometryDataAddress = nullptr;
                safeRead(reinterpret_cast<const UInt8*>(object) + 0xA4, materialProperty);
                safeRead(reinterpret_cast<const UInt8*>(object) + 0xA8, shaderProperty);
                safeRead(reinterpret_cast<const UInt8*>(object) + 0xB8, geometryDataAddress);
                OracleGeometryData geometryData = {};
                const bool geometryReadable = geometryDataAddress != nullptr
                    && safeRead(geometryDataAddress, geometryData)
                    && geometryData.vertexCount > 0 && geometryData.vertexCount <= 32768
                    && geometryData.vertices != nullptr;

                const std::string inheritedRole
                    = attachment != nullptr ? attachment->role : std::string("actor");
                SidecarRenderPart part;
                part.role = sidecarClassifyAppearanceRole(inheritedRole, nodePath);
                part.sourceForm = sidecarAppearanceRoleSource(capture, attachment, part.role);
                part.sourceSlot
                    = attachment != nullptr ? attachment->sourceSlot : sSidecarNoSourceSlot;
                UInt32 shaderFlags1 = 0;
                if (shaderProperty != nullptr)
                    safeRead(reinterpret_cast<const UInt8*>(shaderProperty) + 0x20, shaderFlags1);
                const std::string lowerNodePath = sidecarLowerAscii(nodePath);
                part.skinSurface = part.role == "face" || part.role == "leftHand"
                    || part.role == "rightHand" || part.role == "exposedBody"
                    || (part.role == "equipment"
                        && ((shaderFlags1 & 0x400u) != 0
                            || lowerNodePath.find("skin") != std::string::npos
                            || lowerNodePath.find("arms") != std::string::npos));
                part.attached = true;
                part.drawable = geometryReadable && flagsReadable
                    && (flags & 0x00000020u) != 0 && shaderProperty != nullptr;

                float effectiveAlpha = 1.f;
                if (materialProperty != nullptr)
                {
                    float materialAlpha = 1.f;
                    if (safeRead(reinterpret_cast<const UInt8*>(materialProperty) + 0x3C,
                            materialAlpha) && std::isfinite(materialAlpha))
                        effectiveAlpha *= materialAlpha;
                    else
                        capture.evidenceComplete = false;
                }
                if (shaderProperty != nullptr)
                {
                    float shaderAlpha = 1.f;
                    float fadeAlpha = 1.f;
                    if (safeRead(reinterpret_cast<const UInt8*>(shaderProperty) + 0x28,
                            shaderAlpha) && std::isfinite(shaderAlpha))
                        effectiveAlpha *= shaderAlpha;
                    else
                        capture.evidenceComplete = false;
                    if (safeRead(reinterpret_cast<const UInt8*>(shaderProperty) + 0x2C,
                            fadeAlpha) && std::isfinite(fadeAlpha))
                        effectiveAlpha *= fadeAlpha;
                    else
                        capture.evidenceComplete = false;
                }
                if (!std::isfinite(effectiveAlpha))
                {
                    effectiveAlpha = 0.f;
                    capture.evidenceComplete = false;
                }
                effectiveAlpha = (std::min)(1.f, (std::max)(0.f, effectiveAlpha));
                part.alphaBits = sidecarFloatBits(effectiveAlpha);
                part.visible = part.drawable && !hidden && effectiveAlpha > 0.f;
                part.required = part.visible;
                if (attachment != nullptr && !attachment->modelPath.empty())
                    part.modelHash = sidecarHashText(attachment->modelPath);
                part.nodeHash = sidecarHashText(nodePath);
                if (geometryReadable)
                {
                    UInt32 geometryHash = 2166136261u;
                    geometryHash = sidecarHashAppend(
                        geometryHash, &geometryData.vertexCount, sizeof(geometryData.vertexCount));
                    UInt64 geometryBytes = 0;
                    if (sidecarHashReadableBytes(geometryHash,
                            reinterpret_cast<const UInt8*>(geometryData.vertices),
                            static_cast<std::size_t>(geometryData.vertexCount)
                                * sizeof(OracleVector3), geometryBytes))
                        part.geometryHash = sidecarHashLabel("fnv1a32:", geometryHash);
                    else
                        capture.evidenceComplete = false;
                }

                const std::string shaderRuntimeType
                    = safeRuntimeString(runtimeTypeName(shaderProperty));
                sidecarCollectShaderTextures(
                    capture, part, shaderProperty, shaderRuntimeType);
                std::sort(part.textureBindings.begin(), part.textureBindings.end(),
                    [](const SidecarTextureBinding& left, const SidecarTextureBinding& right) {
                        if (left.stage != right.stage) return left.stage < right.stage;
                        if (left.semantic != right.semantic) return left.semantic < right.semantic;
                        return left.path < right.path;
                    });
                if (part.visible && part.skinSurface)
                {
                    const bool hasBodyColor = std::any_of(part.textureBindings.begin(),
                        part.textureBindings.end(), [](const SidecarTextureBinding& binding) {
                            return binding.semantic == "bodyColor";
                        });
                    if (!hasBodyColor)
                        capture.evidenceComplete = false;
                }
                part.stableKey = sidecarRenderPartStableKey(part);
                part.deterministicKey = sidecarRenderPartDeterministicKey(part);
                capture.parts.push_back(std::move(part));
                if (attachment != nullptr)
                    attachment->emitted = true;
            }
        }

        NiNode* node = object->GetAsNiNode();
        if (node == nullptr)
            return;
        NiTArray<NiAVObject*> children = {};
        if (!safeRead(&node->m_children, children))
        {
            capture.evidenceComplete = false;
            return;
        }
        const UInt32 count = (std::min)(
            (std::min)(static_cast<UInt32>(children.firstFreeEntry),
                static_cast<UInt32>(children.capacity)), static_cast<UInt32>(2048));
        if (count > 0 && children.data == nullptr)
        {
            capture.evidenceComplete = false;
            return;
        }
        for (UInt32 index = 0; index < count; ++index)
        {
            NiAVObject* child = nullptr;
            if (!safeRead(children.data + index, child))
            {
                capture.evidenceComplete = false;
                continue;
            }
            sidecarCollectAppearanceRecursive(capture, child, attachment,
                nodePath, hidden, depth + 1);
        }
    }

    bool sidecarCollectAppearanceSafely(
        SidecarAppearanceCapture& capture, NiNode* root)
    {
        bool complete = false;
        __try
        {
            sidecarCollectAppearanceRecursive(
                capture, root, nullptr, sSidecarEmptyNodePath, false, 0);
            complete = true;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            capture.evidenceComplete = false;
            capture.traversalTruncated = true;
            complete = false;
        }
        return complete;
    }

    void sidecarAddMissingAttachmentParts(SidecarAppearanceCapture& capture)
    {
        for (const SidecarAppearanceAttachment& attachment : capture.attachments)
        {
            if (attachment.emitted)
                continue;
            SidecarRenderPart part;
            part.role = attachment.role;
            part.sourceForm = attachment.sourceForm;
            part.sourceSlot = attachment.sourceSlot;
            part.required = attachment.required;
            part.attached = attachment.reached;
            part.drawable = false;
            part.visible = false;
            if (attachment.required)
                capture.evidenceComplete = false;
            if (!attachment.modelPath.empty())
                part.modelHash = sidecarHashText(attachment.modelPath);
            const std::string missingIdentity = "missing/" + part.role + '/'
                + sidecarFormatFormId(part.sourceForm) + '/'
                + std::to_string(part.sourceSlot);
            part.nodeHash = sidecarHashText(missingIdentity);
            part.stableKey = sidecarRenderPartStableKey(part);
            part.deterministicKey = sidecarRenderPartDeterministicKey(part);
            capture.parts.push_back(std::move(part));
        }
    }

    void sidecarAssignAppearanceOrdinals(std::vector<SidecarRenderPart>& parts)
    {
        std::sort(parts.begin(), parts.end(), [](const SidecarRenderPart& left,
            const SidecarRenderPart& right) {
            if (left.stableKey != right.stableKey) return left.stableKey < right.stableKey;
            return left.deterministicKey < right.deterministicKey;
        });
        std::map<std::string, UInt32> ordinals;
        for (SidecarRenderPart& part : parts)
        {
            const std::string group = part.role + '|' + sidecarFormatFormId(part.sourceForm)
                + '|' + std::to_string(part.sourceSlot);
            part.ordinal = ordinals[group]++;
        }
    }

    std::string sidecarSerializeRenderPart(const SidecarRenderPart& part)
    {
        std::ostringstream out;
        out << "{\"role\":" << jsonString(part.role.c_str())
            << ",\"sourceFormId\":" << jsonString(sidecarFormatFormId(part.sourceForm).c_str())
            << ",\"sourceSlot\":" << part.sourceSlot
            << ",\"ordinal\":" << part.ordinal
            << ",\"required\":" << (part.required ? "true" : "false")
            << ",\"attached\":" << (part.attached ? "true" : "false")
            << ",\"drawable\":" << (part.drawable ? "true" : "false")
            << ",\"visible\":" << (part.visible ? "true" : "false")
            << ",\"alphaBits\":" << part.alphaBits;
        out << ",\"textureBindings\":[";
        for (std::size_t index = 0; index < part.textureBindings.size(); ++index)
        {
            if (index != 0)
                out << ',';
            const SidecarTextureBinding& binding = part.textureBindings[index];
            out << "{\"semantic\":" << jsonString(binding.semantic.c_str())
                << ",\"path\":" << jsonString(binding.path.c_str())
                << ",\"contentHash\":" << jsonString(binding.contentHash.c_str())
                << ",\"width\":" << binding.width
                << ",\"height\":" << binding.height
                << ",\"format\":" << jsonString(binding.format.c_str())
                << ",\"sourceKind\":" << jsonString(binding.sourceKind.c_str())
                << ",\"stage\":" << binding.stage << '}';
        }
        out << "]}";
        return out.str();
    }

    void sidecarWriteAppearanceTelemetry(std::ostringstream& out, Actor* actor)
    {
        SidecarAppearanceCapture capture;
        sidecarCollectAppearanceSourcesAndAttachments(actor, capture);
        NiNode* root = sidecarActorRootUnsafe(actor);
        if (root != nullptr)
            sidecarCollectAppearanceSafely(capture, root);
        sidecarAddMissingAttachmentParts(capture);
        if (capture.parts.empty())
        {
            SidecarRenderPart fallback;
            fallback.role = "actor";
            fallback.sourceForm = capture.sources.actorBaseForm;
            fallback.sourceSlot = sSidecarNoSourceSlot;
            fallback.required = actor != nullptr;
            fallback.attached = root != nullptr;
            fallback.nodeHash = sidecarHashText("missing/actor-root");
            fallback.stableKey = sidecarRenderPartStableKey(fallback);
            fallback.deterministicKey = sidecarRenderPartDeterministicKey(fallback);
            capture.parts.push_back(std::move(fallback));
            capture.evidenceComplete = false;
        }
        sidecarAssignAppearanceOrdinals(capture.parts);

        std::vector<std::string> serialized;
        serialized.reserve((std::min)(capture.parts.size(),
            static_cast<std::size_t>(sSidecarAppearanceMaximumParts)));
        const std::streampos currentPosition = out.tellp();
        const std::size_t currentBytes = currentPosition >= std::streampos(0)
            ? static_cast<std::size_t>(currentPosition) : 0;
        constexpr std::size_t reservedTailBytes = 4096;
        const std::size_t transportBudget = NikamiFNVSidecar::PayloadBytes
                > currentBytes + reservedTailBytes
            ? NikamiFNVSidecar::PayloadBytes - currentBytes - reservedTailBytes : 0;
        const std::size_t renderPartsBudget = (std::min)(
            sSidecarAppearanceMaximumJsonBytes,
            transportBudget > 512 ? transportBudget - 512 : std::size_t(0));
        std::size_t serializedBytes = 0;
        for (const SidecarRenderPart& part : capture.parts)
        {
            if (serialized.size() >= sSidecarAppearanceMaximumParts)
                break;
            std::string value = sidecarSerializeRenderPart(part);
            const std::size_t added = value.size() + (serialized.empty() ? 0 : 1);
            if (!serialized.empty()
                && serializedBytes + added > renderPartsBudget)
                break;
            serializedBytes += added;
            serialized.push_back(std::move(value));
        }
        const bool truncated = capture.traversalTruncated
            || serialized.size() != capture.parts.size();
        const bool complete = capture.evidenceComplete && !truncated && root != nullptr;
        out << ",\"appearance\":{\"schema\":\"nikami-fnv-sidecar-appearance/v1\""
            << ",\"complete\":" << (complete ? "true" : "false")
            << ",\"truncated\":" << (truncated ? "true" : "false")
            << ",\"visitedNodes\":" << capture.visitedNodes
            << ",\"candidateCount\":" << capture.geometryCandidates
            << ",\"renderParts\":[";
        for (std::size_t index = 0; index < serialized.size(); ++index)
        {
            if (index != 0)
                out << ',';
            out << serialized[index];
        }
        out << "]}";
    }

    void sidecarWriteTransformBits(std::ostream& out, const NiTransform& transform)
    {
        out << "\"rotationBits\":[";
        for (UInt32 index = 0; index < 9; ++index)
        {
            if (index != 0)
                out << ',';
            out << sidecarFloatBits(transform.rotate.data[index]);
        }
        out << "],\"translationBits\":[" << sidecarFloatBits(transform.translate.x) << ','
            << sidecarFloatBits(transform.translate.y) << ','
            << sidecarFloatBits(transform.translate.z) << "],\"scaleBits\":"
            << sidecarFloatBits(transform.scale);
    }

    void sidecarWriteWeaponAttachment(
        std::ostream& out, Actor* actor, UInt32 requestedWeapon)
    {
        out << ",\"attachment\":{";
        if (actor == nullptr || requestedWeapon == 0)
        {
            out << "\"available\":false}";
            return;
        }

        TESForm* actorBaseForm = nullptr;
        UInt8 actorBaseType = 0;
        if (!safeRead(&actor->baseForm, actorBaseForm) || actorBaseForm == nullptr
            || !safeRead(&actorBaseForm->typeID, actorBaseType)
            || actorBaseType != kFormType_TESNPC)
        {
            out << "\"available\":false}";
            return;
        }

        ValidBip01Names* slots = nullptr;
        if (!safeRead(&static_cast<Character*>(actor)->validBip01Names, slots) || slots == nullptr)
        {
            out << "\"available\":false}";
            return;
        }

        for (UInt32 slot = 0; slot < 20; ++slot)
        {
            ValidBip01Names::Data data = {};
            UInt32 modelForm = 0;
            if (!safeRead(&slots->unk002C[slot], data) || data.model == nullptr
                || !safeRead(&data.model->refID, modelForm) || modelForm != requestedWeapon
                || data.bones == nullptr)
                continue;

            NiAVObject* modelRoot = data.bones;
            NiNode* attachmentFrame = nullptr;
            NiNode* skeletonParent = nullptr;
            char* modelRootNameAddress = nullptr;
            char* frameNameAddress = nullptr;
            char* parentNameAddress = nullptr;
            NiTransform local = {};
            const bool readable = safeRead(&modelRoot->m_pcName, modelRootNameAddress)
                && safeRead(&modelRoot->m_parent, attachmentFrame) && attachmentFrame != nullptr
                && safeRead(&attachmentFrame->m_pcName, frameNameAddress)
                && safeRead(&attachmentFrame->m_parent, skeletonParent) && skeletonParent != nullptr
                && safeRead(&skeletonParent->m_pcName, parentNameAddress)
                && sidecarReadFiniteTransform(
                    attachmentFrame, sNiAVObjectLocalTransformOffset, local);
            const std::string modelRootName
                = readable ? safeRuntimeString(modelRootNameAddress) : std::string();
            const std::string frameName
                = readable ? safeRuntimeString(frameNameAddress) : std::string();
            const std::string parentName
                = readable ? safeRuntimeString(parentNameAddress) : std::string();
            if (!readable || modelRootName.empty() || frameName.empty() || parentName.empty())
                break;

            out << "\"available\":true,\"sourceForm\":" << modelForm
                << ",\"evaluatedSlot\":" << slot << ",\"evaluatedState\":" << data.unk00C
                << ",\"modelRootName\":" << jsonString(modelRootName.c_str())
                << ",\"frameName\":" << jsonString(frameName.c_str())
                << ",\"parentName\":" << jsonString(parentName.c_str()) << ',';
            sidecarWriteTransformBits(out, local);
            out << '}';
            return;
        }
        out << "\"available\":false}";
    }

    std::string sidecarBuildTelemetry(Actor* actor, bool screenshotReady,
        const SidecarScreenshotFile* screenshot)
    {
        std::ostringstream out;
        out << std::setprecision(9)
            << "{\"schema\":\"nikami-fnv-sidecar-retail/v1\""
            << ",\"sequenceId\":" << jsonString(gSidecarPlan.sequenceId.c_str())
            << ",\"key\":{\"sequenceId\":" << jsonString(gSidecarPlan.sequenceId.c_str())
            << ",\"actorIndex\":" << gSidecarActorIndex
            << ",\"actionIndex\":" << gSidecarActionIndex << '}'
            << ",\"generation\":" << gSidecarGeneration
            << ",\"frame\":" << gFrame;

        UInt32 reference = 0;
        UInt32 base = 0;
        sidecarReadActorIdentity(actor, reference, base);
        out << ",\"actor\":{\"refForm\":" << reference
            << ",\"baseForm\":" << base
            << ",\"spawned\":" << (gSidecarResolvedSpawned ? "true" : "false");
        if (actor != nullptr)
        {
            float position[3] = {};
            float rotation[3] = {};
            const bool hasTransform = safeRead(&actor->posX, position[0])
                && safeRead(&actor->posY, position[1]) && safeRead(&actor->posZ, position[2])
                && safeRead(&actor->rotX, rotation[0]) && safeRead(&actor->rotY, rotation[1])
                && safeRead(&actor->rotZ, rotation[2]);
            if (hasTransform)
                out << ",\"position\":[" << position[0] << ',' << position[1] << ',' << position[2]
                    << "],\"rotation\":[" << rotation[0] << ',' << rotation[1] << ',' << rotation[2] << ']';
        }
        out << '}';

        if (gSidecarActionIndex < gSidecarPlan.actions.size())
        {
            const SidecarActionPlan& action = gSidecarPlan.actions[gSidecarActionIndex];
            out << ",\"action\":{\"id\":" << jsonString(action.id.c_str())
                << ",\"retailPlayGroup\":" << jsonString(action.playGroup.c_str())
                << ",\"requestedFrames\":" << action.frames
                << ",\"elapsedFrames\":" << (gFrame - gSidecarActionStartFrame)
                << ",\"accepted\":" << (gSidecarActionAccepted ? "true" : "false") << '}';
        }
        sidecarWriteAnimationTelemetry(out, actor);
        sidecarWriteVatsTelemetry(out);

        std::map<UInt32, SidecarInventoryItem> inventory;
        const UInt32 requestedWeapon = gSidecarActorIndex < gSidecarPlan.actors.size()
            ? gSidecarPlan.actors[gSidecarActorIndex].weaponForm : 0;
        const bool exactWeapon = sidecarVerifyExactWeapon(actor, requestedWeapon, &inventory);
        out << ",\"weaponPolicy\":{\"requestedForm\":" << requestedWeapon
            << ",\"equippedForm\":" << sidecarEquippedWeaponForm(actor)
            << ",\"exact\":" << (exactWeapon ? "true" : "false")
            << ",\"requestedMetadata\":";
        TESObjectWEAP* requestedWeaponObject = nullptr;
        if (requestedWeapon != 0)
        {
            TESForm* requestedForm = lookupForm(requestedWeapon);
            UInt8 requestedType = 0;
            if (requestedForm != nullptr && safeRead(&requestedForm->typeID, requestedType)
                && requestedType == kFormType_TESObjectWEAP)
                requestedWeaponObject = static_cast<TESObjectWEAP*>(requestedForm);
        }
        if (requestedWeaponObject == nullptr)
            out << "null";
        else
        {
            UInt8 weaponType = 0xff;
            UInt8 grip = 0xff;
            UInt8 reload = 0xff;
            UInt8 attack = 0xff;
            char* modelAddress = nullptr;
            safeRead(&requestedWeaponObject->eWeaponType, weaponType);
            safeRead(&requestedWeaponObject->handGrip, grip);
            safeRead(&requestedWeaponObject->reloadAnim, reload);
            safeRead(&requestedWeaponObject->attackAnim, attack);
            safeRead(&requestedWeaponObject->textureSwap.nifPath.m_data, modelAddress);
            const std::string modelPath = safeRuntimeString(modelAddress);
            out << "{\"animationType\":" << static_cast<UInt32>(weaponType)
                << ",\"handGripRaw\":" << static_cast<UInt32>(grip)
                << ",\"handGripIndex\":" << handGripIndex(grip)
                << ",\"reloadAnimation\":" << static_cast<UInt32>(reload)
                << ",\"attackAnimationRaw\":" << static_cast<UInt32>(attack)
                << ",\"attackAnimationIndex\":" << attackAnimationIndex(attack)
                << ",\"model\":" << jsonString(modelPath.c_str()) << '}';
        }
        out << ",\"effectiveWeapons\":[";
        bool firstWeapon = true;
        for (const auto& pair : inventory)
        {
            UInt8 type = 0;
            if (pair.second.form == nullptr || !safeRead(&pair.second.form->typeID, type)
                || type != kFormType_TESObjectWEAP || pair.second.count <= 0)
                continue;
            if (!firstWeapon)
                out << ',';
            firstWeapon = false;
            out << "{\"form\":" << pair.first << ",\"count\":" << pair.second.count
                << ",\"worn\":" << (pair.second.worn ? "true" : "false") << '}';
        }
        out << ']';
        sidecarWriteWeaponAttachment(out, actor, requestedWeapon);
        out << '}';

        out << ",\"equipment\":{\"worn\":[";
        bool firstWorn = true;
        for (const auto& pair : inventory)
        {
            UInt8 type = 0;
            if (!pair.second.worn || pair.second.form == nullptr
                || !safeRead(&pair.second.form->typeID, type)
                || (type != kFormType_TESObjectARMO && type != kFormType_TESObjectCLOT))
                continue;
            const TESBipedModelForm* biped = type == kFormType_TESObjectARMO
                ? &static_cast<TESObjectARMO*>(pair.second.form)->bipedModel
                : &static_cast<TESObjectCLOT*>(pair.second.form)->bipedModel;
            UInt32 mask = 0;
            UInt8 flags = 0;
            const bool readable = safeRead(&biped->partMask, mask) && safeRead(&biped->bipedFlags, flags)
                ;
            if (!firstWorn)
                out << ',';
            firstWorn = false;
            out << "{\"form\":" << pair.first << ",\"type\":" << static_cast<UInt32>(type)
                << ",\"readable\":" << (readable ? "true" : "false");
            if (readable)
            {
                char* maleAddress = nullptr;
                char* femaleAddress = nullptr;
                safeRead(&biped->bipedModel[0].nifPath.m_data, maleAddress);
                safeRead(&biped->bipedModel[1].nifPath.m_data, femaleAddress);
                const std::string malePath = safeRuntimeString(maleAddress);
                const std::string femalePath = safeRuntimeString(femaleAddress);
                out << ",\"partMask\":" << mask << ",\"bipedFlags\":" << static_cast<UInt32>(flags)
                    << ",\"maleModel\":" << jsonString(malePath.c_str())
                    << ",\"femaleModel\":" << jsonString(femalePath.c_str());
            }
            out << '}';
        }
        out << "],\"evaluatedSlots\":[";
        bool firstSlot = true;
        TESForm* actorBaseForm = nullptr;
        UInt8 actorBaseType = 0;
        if (actor != nullptr && safeRead(&actor->baseForm, actorBaseForm) && actorBaseForm != nullptr)
            safeRead(&actorBaseForm->typeID, actorBaseType);
        if (actorBaseType == kFormType_TESNPC)
        {
            ValidBip01Names* slots = nullptr;
            if (safeRead(&static_cast<Character*>(actor)->validBip01Names, slots) && slots != nullptr)
            {
                for (UInt32 slot = 0; slot < 20; ++slot)
                {
                    ValidBip01Names::Data data = {};
                    if (!safeRead(&slots->unk002C[slot], data))
                        continue;
                    UInt32 modelForm = 0;
                    if (data.model != nullptr)
                        safeRead(&data.model->refID, modelForm);
                    if (modelForm == 0 && data.texture == nullptr && data.bones == nullptr)
                        continue;
                    std::string modelPath;
                    if (data.texture != nullptr)
                    {
                        char* modelAddress = nullptr;
                        if (safeRead(&data.texture->nifPath.m_data, modelAddress))
                            modelPath = safeRuntimeString(modelAddress);
                    }
                    if (!firstSlot)
                        out << ',';
                    firstSlot = false;
                    out << "{\"slot\":" << slot << ",\"modelForm\":" << modelForm
                        << ",\"modelPath\":" << jsonString(modelPath.c_str())
                        << ",\"bonesAddress\":" << reinterpret_cast<std::uintptr_t>(data.bones)
                        << ",\"state\":" << data.unk00C << '}';
                }
            }
        }
        out << "]}";

        out << ",\"face\":";
        if (actorBaseType != kFormType_TESNPC)
            out << "{\"npc\":false}";
        else
        {
            TESNPC* npc = static_cast<TESNPC*>(actorBaseForm);
            NpcAppearanceSnapshot appearance = {};
            const bool appearanceReadable = readNpcAppearanceUnsafe(actor, appearance);
            UInt32 hairForm = 0;
            UInt32 eyesForm = 0;
            UInt32 hairColor = 0;
            float hairLength = 0.f;
            TESHair* hair = nullptr;
            TESEyes* eyes = nullptr;
            safeRead(&npc->hair, hair);
            safeRead(&npc->eyes, eyes);
            safeRead(&npc->hairColor, hairColor);
            safeRead(&npc->hairLength, hairLength);
            if (hair != nullptr)
                safeRead(&hair->refID, hairForm);
            if (eyes != nullptr)
                safeRead(&eyes->refID, eyesForm);
            out << "{\"npc\":true,\"appearanceReadable\":"
                << (appearanceReadable ? "true" : "false")
                << ",\"female\":"
                << (appearanceReadable && appearance.female ? "true" : "false")
                << ",\"raceForm\":" << (appearanceReadable ? appearance.raceForm : 0)
                << ",\"raceFieldForm\":" << (appearanceReadable ? appearance.raceFieldForm : 0)
                << ",\"runtimeRaceForm\":" << (appearanceReadable ? appearance.runtimeRaceForm : 0)
                << ",\"copyFromForm\":" << (appearanceReadable ? appearance.copyFromForm : 0)
                << ",\"hairForm\":" << hairForm
                << ",\"eyesForm\":" << eyesForm << ",\"hairColor\":" << hairColor
                << ",\"hairColorBytes\":["
                << static_cast<UInt32>(appearanceReadable ? appearance.hairColor[0] : 0) << ','
                << static_cast<UInt32>(appearanceReadable ? appearance.hairColor[1] : 0) << ','
                << static_cast<UInt32>(appearanceReadable ? appearance.hairColor[2] : 0) << ','
                << static_cast<UInt32>(appearanceReadable ? appearance.hairColor[3] : 0) << ']'
                << ",\"hairLength\":" << hairLength
                << ",\"hairModel\":"
                << jsonString(appearanceReadable
                        ? safeRuntimeString(appearance.hairModel).c_str() : nullptr)
                << ",\"eyeTexture\":"
                << jsonString(appearanceReadable
                        ? safeRuntimeString(appearance.eyeTexture).c_str() : nullptr)
                << ",\"raceFaceSlots\":[";
            if (appearanceReadable)
            {
                for (UInt32 slot = 0; slot < appearance.raceFaceSlotCount; ++slot)
                {
                    if (slot != 0)
                        out << ',';
                    const std::string model
                        = safeRuntimeString(appearance.raceFaceSlots[slot].model);
                    const std::string texture
                        = safeRuntimeString(appearance.raceFaceSlots[slot].texture);
                    out << "{\"slot\":" << slot << ",\"model\":" << jsonString(model.c_str())
                        << ",\"texture\":" << jsonString(texture.c_str()) << '}';
                }
            }
            out << "],\"headParts\":[";
            UInt32 headHash = 2166136261u;
            bool firstPart = true;
            auto* partAddress = npc->headPart.Head();
            for (UInt32 visited = 0; partAddress != nullptr && visited < 128; ++visited)
            {
                ListNode<BGSHeadPart> node;
                if (!safeRead(partAddress, node))
                    break;
                if (node.data != nullptr)
                {
                    UInt32 form = 0;
                    safeRead(&node.data->refID, form);
                    std::string path;
                    char* modelAddress = nullptr;
                    if (safeRead(&node.data->texSwap.nifPath.m_data, modelAddress))
                        path = safeRuntimeString(modelAddress);
                    headHash = sidecarHashAppend(headHash, &form, sizeof(form));
                    headHash = sidecarHashAppend(headHash, path.data(), path.size());
                    if (!firstPart)
                        out << ',';
                    firstPart = false;
                    out << "{\"form\":" << form << ",\"model\":" << jsonString(path.c_str()) << '}';
                }
                partAddress = node.next;
            }
            out << "],\"headPartsHash\":" << headHash << ",\"faceGenChannels\":[";
            for (UInt32 channelIndex = 0; channelIndex < 3; ++channelIndex)
            {
                UInt32 count = 0;
                UInt32 size = 0;
                UInt32 usedBytes = 0;
                UInt32 capacityBytes = 0;
                UInt32 hash = 0;
                bool truncated = false;
                std::vector<float> values;
                const bool readable = sidecarReadFaceGenChannel(&npc->faceGenData[channelIndex],
                    count, size, usedBytes, capacityBytes, hash, values, truncated);
                if (channelIndex != 0)
                    out << ',';
                out << "{\"index\":" << channelIndex << ",\"count\":" << count
                    << ",\"size\":" << size << ",\"usedBytes\":" << usedBytes
                    << ",\"capacityBytes\":" << capacityBytes
                    << ",\"layout\":\"contiguous-float\",\"readable\":"
                    << (readable ? "true" : "false")
                    << ",\"hash\":" << hash << ",\"truncated\":" << (truncated ? "true" : "false")
                    << ",\"values\":[";
                for (std::size_t valueIndex = 0; valueIndex < values.size(); ++valueIndex)
                {
                    if (valueIndex != 0)
                        out << ',';
                    out << values[valueIndex];
                }
                out << "]}";
            }
            out << "]}";
        }

        sidecarWriteAppearanceTelemetry(out, actor);

        PlayerCharacter* player = nullptr;
        safeRead(reinterpret_cast<const void*>(0x011DEA3C), player);
        float fly[5] = {};
        const bool hasFly = player != nullptr
            && safeRead(reinterpret_cast<const UInt8*>(player) + 0x7E0, fly[0])
            && safeRead(reinterpret_cast<const UInt8*>(player) + 0x7E4, fly[1])
            && safeRead(reinterpret_cast<const UInt8*>(player) + 0x7E8, fly[2])
            && safeRead(reinterpret_cast<const UInt8*>(player) + 0x7EC, fly[3])
            && safeRead(reinterpret_cast<const UInt8*>(player) + 0x7F0, fly[4]);
        void* sceneCamera = sidecarGetSceneCameraUnsafe();
        NiTransform world = {};
        NiFrustum frustum = {};
        NiViewport viewport = {};
        const bool hasCamera = sceneCamera != nullptr
            && safeRead(reinterpret_cast<const UInt8*>(sceneCamera) + sNiAVObjectWorldTransformOffset, world)
            && safeRead(reinterpret_cast<const UInt8*>(sceneCamera) + 0xEC, frustum)
            && safeRead(reinterpret_cast<const UInt8*>(sceneCamera) + 0x110, viewport);
        out << ",\"camera\":{\"fly\":";
        if (hasFly)
            out << '[' << fly[0] << ',' << fly[1] << ',' << fly[2] << ',' << fly[3] << ',' << fly[4] << ']';
        else
            out << "null";
        if (hasCamera)
        {
            const float height = std::fabs(frustum.t - frustum.b);
            const float fovY = frustum.n > 0.f ? 2.f * std::atan(height / (2.f * frustum.n)) : 0.f;
            float view[16] = { world.rotate.data[0], world.rotate.data[3], world.rotate.data[6], 0.f,
                world.rotate.data[1], world.rotate.data[4], world.rotate.data[7], 0.f,
                world.rotate.data[2], world.rotate.data[5], world.rotate.data[8], 0.f, 0.f, 0.f, 0.f, 1.f };
            view[12] = -(view[0] * world.translate.x + view[4] * world.translate.y + view[8] * world.translate.z);
            view[13] = -(view[1] * world.translate.x + view[5] * world.translate.y + view[9] * world.translate.z);
            view[14] = -(view[2] * world.translate.x + view[6] * world.translate.y + view[10] * world.translate.z);
            float projection[16] = {};
            if (frustum.r != frustum.l && frustum.t != frustum.b && frustum.f != frustum.n)
            {
                projection[0] = 2.f * frustum.n / (frustum.r - frustum.l);
                projection[5] = 2.f * frustum.n / (frustum.t - frustum.b);
                projection[8] = (frustum.l + frustum.r) / (frustum.l - frustum.r);
                projection[9] = (frustum.t + frustum.b) / (frustum.b - frustum.t);
                projection[10] = frustum.f / (frustum.f - frustum.n);
                projection[11] = 1.f;
                projection[14] = -frustum.n * frustum.f / (frustum.f - frustum.n);
            }
            out << ",\"fovYRadians\":" << fovY
                << ",\"world\":{\"rotation\":[";
            for (UInt32 i = 0; i < 9; ++i)
            {
                if (i != 0)
                    out << ',';
                out << world.rotate.data[i];
            }
            out << "],\"translation\":[" << world.translate.x << ',' << world.translate.y << ','
                << world.translate.z << "],\"scale\":" << world.scale << "}"
                << ",\"frustum\":[" << frustum.l << ',' << frustum.r << ',' << frustum.t << ','
                << frustum.b << ',' << frustum.n << ',' << frustum.f << ',' << static_cast<UInt32>(frustum.o) << ']'
                << ",\"viewport\":[" << viewport.l << ',' << viewport.r << ',' << viewport.t << ',' << viewport.b << ']'
                << ",\"viewMatrix\":[";
            for (UInt32 i = 0; i < 16; ++i)
            {
                if (i != 0)
                    out << ',';
                out << view[i];
            }
            out << "],\"projectionMatrix\":[";
            for (UInt32 i = 0; i < 16; ++i)
            {
                if (i != 0)
                    out << ',';
                out << projection[i];
            }
            out << ']';
        }
        out << '}';

        const UInt8* sky = nullptr;
        safeRead(reinterpret_cast<const void*>(0x011DEA20), sky);
        TESWeather* currentWeather = nullptr;
        TESWeather* previousWeather = nullptr;
        float hour = 0.f;
        float transition = 0.f;
        UInt32 skyMode = 0;
        if (sky != nullptr)
        {
            safeRead(sky + 0x10, currentWeather);
            safeRead(sky + 0x14, previousWeather);
            safeRead(sky + 0xEC, hour);
            safeRead(sky + 0xF4, transition);
            safeRead(sky + 0xF8, skyMode);
        }
        UInt32 currentWeatherForm = 0;
        UInt32 previousWeatherForm = 0;
        if (currentWeather != nullptr)
            safeRead(&currentWeather->refID, currentWeatherForm);
        if (previousWeather != nullptr)
            safeRead(&previousWeather->refID, previousWeatherForm);
        out << ",\"environment\":{\"currentWeatherForm\":" << currentWeatherForm
            << ",\"previousWeatherForm\":" << previousWeatherForm
            << ",\"gameHour\":" << hour << ",\"transition\":" << transition
            << ",\"skyMode\":" << skyMode << '}';

        out << ",\"capture\":{\"screenshotReady\":" << (screenshotReady ? "true" : "false");
        if (screenshot != nullptr && screenshot->valid)
            out << ",\"ordinal\":" << screenshot->ordinal << ",\"writeTime\":" << screenshot->writeTime
                << ",\"size\":" << screenshot->size << ",\"width\":" << screenshot->width
                << ",\"height\":" << screenshot->height
                << ",\"bitsPerPixel\":" << screenshot->bitsPerPixel
                << ",\"stableFrames\":" << gSidecarScreenshotStableFrames
                << ",\"file\":" << jsonString(screenshot->path.c_str());
        out << "}}";
        return out.str();
    }

    void bootstrapProofFreeCamera(PlayerCharacter* player)
    {
        if (player == nullptr)
            return;
        const float forwardX = std::sin(gBatchProofTargetYaw);
        const float forwardY = std::cos(gBatchProofTargetYaw);
        const float aimX = gBatchProofTargetX;
        const float aimY = gBatchProofTargetY;
        const float aimZ = gBatchProofTargetZ + 96.f;
        const float distance = 400.f;
        const float cameraX = aimX + forwardX * distance;
        const float cameraY = aimY + forwardY * distance;
        const float cameraYaw = std::atan2(aimX - cameraX, aimY - cameraY);
        *reinterpret_cast<float*>(reinterpret_cast<UInt8*>(player) + 0x7E0) = cameraYaw;
        *reinterpret_cast<float*>(reinterpret_cast<UInt8*>(player) + 0x7E4) = 0.f;
        *reinterpret_cast<float*>(reinterpret_cast<UInt8*>(player) + 0x7E8) = cameraX;
        *reinterpret_cast<float*>(reinterpret_cast<UInt8*>(player) + 0x7EC) = cameraY;
        *reinterpret_cast<float*>(reinterpret_cast<UInt8*>(player) + 0x7F0) = aimZ;
    }

    void driveBatchTargetLoading()
    {
        if (gBatchTargetForms.empty() || gBatchTargetLoadRequested || gConsole == nullptr)
            return;
        if (!gBatchEnableParentsRequested)
        {
            gBatchEnableParentsRequested = true;
            for (const UInt32 parentForm : gBatchEnableParentForms)
            {
                TESForm* form = lookupForm(parentForm);
                TESObjectREFR* parent = form != nullptr && form->GetIsReference()
                    ? static_cast<TESObjectREFR*>(form)
                    : nullptr;
                const bool accepted = parent != nullptr && gConsole->RunScriptLine2("Enable", parent, true);
                gOutput << "{\"schema\":" << sSchemaJson
                        << ",\"event\":\"batch-enable-parent-request\""
                        << ",\"frame\":" << gFrame
                        << ",\"parentForm\":" << parentForm
                        << ",\"referenceAvailable\":" << (parent != nullptr ? "true" : "false")
                        << ",\"accepted\":" << (accepted ? "true" : "false") << "}\n";
            }
            gOutput.flush();
        }

        PlayerCharacter* player = *reinterpret_cast<PlayerCharacter**>(0x011DEA3C);
        if (gBatchProofStaging && !gBatchProofVolumeReady)
        {
            if (!gBatchProofLoadRequested)
            {
                TESForm* anchorForm = lookupForm(gBatchProofAnchorForm);
                TESObjectREFR* anchor = anchorForm != nullptr && anchorForm->GetIsReference()
                    ? static_cast<TESObjectREFR*>(anchorForm)
                    : nullptr;
                char command[64] = {};
                sprintf_s(command, "player.moveto %08X", gBatchProofAnchorForm);
                const bool accepted = anchor != nullptr && gConsole->RunScriptLine2(command, nullptr, true);
                gBatchProofLoadRequested = true;
                gBatchProofLoadFrame = gFrame;
                bootstrapProofFreeCamera(player);
                gOutput << "{\"schema\":" << sSchemaJson
                        << ",\"event\":\"batch-proof-volume-load-request\""
                        << ",\"frame\":" << gFrame
                        << ",\"anchorForm\":" << gBatchProofAnchorForm
                        << ",\"referenceAvailable\":" << (anchor != nullptr ? "true" : "false")
                        << ",\"accepted\":" << (accepted ? "true" : "false")
                        << ",\"targetPosition\":[" << gBatchProofTargetX << ',' << gBatchProofTargetY
                        << ',' << gBatchProofTargetZ << ']'
                        << ",\"targetYaw\":" << gBatchProofTargetYaw << "}\n";
                gOutput.flush();
                return;
            }
            if (gFrame < gBatchProofLoadFrame + gBatchProofInitializationFrames || player == nullptr)
            {
                bootstrapProofFreeCamera(player);
                return;
            }

            const bool playerX = runReferenceFloatCommand(player, "SetPos X", gBatchProofPlayerX);
            const bool playerY = runReferenceFloatCommand(player, "SetPos Y", gBatchProofPlayerY);
            const bool playerZ = runReferenceFloatCommand(player, "SetPos Z", gBatchProofPlayerZ);
            UInt32 disabledTargets = 0;
            UInt32 disableFailures = 0;
            UInt32 relocatedTargets = 0;
            UInt32 relocationFailures = 0;
            std::vector<UInt32> stagingReferences = gBatchTargetForms;
            if (std::find(stagingReferences.begin(), stagingReferences.end(), gBatchProofAnchorForm)
                == stagingReferences.end())
                stagingReferences.push_back(gBatchProofAnchorForm);
            for (const UInt32 targetFormId : stagingReferences)
            {
                TESForm* form = lookupForm(targetFormId);
                TESObjectREFR* reference = form != nullptr && form->GetIsReference()
                    ? static_cast<TESObjectREFR*>(form)
                    : nullptr;
                if (reference != nullptr
                    && gConsole->RunScriptLine2("MoveTo 00000014", reference, true))
                    ++relocatedTargets;
                else
                    ++relocationFailures;
                if (reference != nullptr && gConsole->RunScriptLine2("Disable", reference, true))
                    ++disabledTargets;
                else
                    ++disableFailures;
            }
            gBatchProofVolumeReady = playerX && playerY && playerZ
                && disableFailures == 0 && relocationFailures == 0;
            bootstrapProofFreeCamera(player);
            gOutput << "{\"schema\":" << sSchemaJson
                    << ",\"event\":\"batch-proof-volume-ready\""
                    << ",\"frame\":" << gFrame
                    << ",\"passed\":" << (gBatchProofVolumeReady ? "true" : "false")
                    << ",\"playerParkingAccepted\":[" << (playerX ? "true" : "false") << ','
                    << (playerY ? "true" : "false") << ',' << (playerZ ? "true" : "false") << ']'
                    << ",\"stagingReferences\":" << stagingReferences.size()
                    << ",\"relocatedTargets\":" << relocatedTargets
                    << ",\"relocationFailures\":" << relocationFailures
                    << ",\"disabledTargets\":" << disabledTargets
                    << ",\"disableFailures\":" << disableFailures << "}\n";
            gOutput.flush();
            if (!gBatchProofVolumeReady)
                return;
        }

        gBatchTargetLoadRequested = true;
        TESForm* targetForm = lookupForm(gTargetForm);
        TESObjectREFR* target = targetForm != nullptr && targetForm->GetIsReference()
            ? static_cast<TESObjectREFR*>(targetForm)
            : nullptr;
        bool enableAccepted = !gBatchEnableTargets;
        if (gBatchEnableTargets && target != nullptr)
            enableAccepted = gConsole->RunScriptLine2("Enable", target, true);
        bool moveAccepted = !gBatchMoveToTargets;
        bool stageAccepted = !gBatchProofStaging;
        bool positionXAccepted = !gBatchProofStaging;
        bool positionYAccepted = !gBatchProofStaging;
        bool positionZAccepted = !gBatchProofStaging;
        bool angleXAccepted = !gBatchProofStaging;
        bool angleYAccepted = !gBatchProofStaging;
        bool angleZAccepted = !gBatchProofStaging;
        if (gBatchProofStaging)
        {
            moveAccepted = target != nullptr
                && gConsole->RunScriptLine2("MoveTo 00000014", target, true);
            positionXAccepted = runReferenceFloatCommand(target, "SetPos X", gBatchProofTargetX);
            positionYAccepted = runReferenceFloatCommand(target, "SetPos Y", gBatchProofTargetY);
            positionZAccepted = runReferenceFloatCommand(target, "SetPos Z", gBatchProofTargetZ);
            angleXAccepted = runReferenceFloatCommand(target, "SetAngle X", 0.f);
            angleYAccepted = runReferenceFloatCommand(target, "SetAngle Y", 0.f);
            const float yawDegrees = gBatchProofTargetYaw * 180.f / 3.14159265358979323846f;
            angleZAccepted = runReferenceFloatCommand(target, "SetAngle Z", yawDegrees);
            stageAccepted = enableAccepted && moveAccepted && positionXAccepted && positionYAccepted
                && positionZAccepted && angleXAccepted && angleYAccepted && angleZAccepted;
            gBatchTargetStaged = stageAccepted;
            gBatchTargetStageFrame = gFrame;
            bootstrapProofFreeCamera(player);
            gOutput << "{\"schema\":" << sSchemaJson
                    << ",\"event\":\"batch-target-stage-request\""
                    << ",\"frame\":" << gFrame
                    << ",\"targetIndex\":" << gBatchTargetIndex
                    << ",\"targetForm\":" << gTargetForm
                    << ",\"accepted\":" << (stageAccepted ? "true" : "false")
                    << ",\"moveToPlayerAccepted\":" << (moveAccepted ? "true" : "false")
                    << ",\"positionAccepted\":[" << (positionXAccepted ? "true" : "false") << ','
                    << (positionYAccepted ? "true" : "false") << ','
                    << (positionZAccepted ? "true" : "false") << ']'
                    << ",\"angleAccepted\":[" << (angleXAccepted ? "true" : "false") << ','
                    << (angleYAccepted ? "true" : "false") << ','
                    << (angleZAccepted ? "true" : "false") << ']'
                    << ",\"position\":[" << gBatchProofTargetX << ',' << gBatchProofTargetY << ','
                    << gBatchProofTargetZ << ']'
                    << ",\"yaw\":" << gBatchProofTargetYaw << "}\n";
        }
        else if (gBatchMoveToTargets)
        {
            char command[64] = {};
            sprintf_s(command, "player.moveto %08X", gTargetForm);
            moveAccepted = gConsole->RunScriptLine2(command, nullptr, true);
        }
        gOutput << "{\"schema\":" << sSchemaJson << ",\"event\":\"batch-target-load-request\""
                << ",\"frame\":" << gFrame
                << ",\"targetIndex\":" << gBatchTargetIndex
                << ",\"targetForm\":" << gTargetForm
                << ",\"referenceAvailable\":" << (target != nullptr ? "true" : "false")
                << ",\"enableRequested\":" << (gBatchEnableTargets ? "true" : "false")
                << ",\"enableAccepted\":" << (enableAccepted ? "true" : "false")
                << ",\"moveRequested\":" << (gBatchMoveToTargets || gBatchProofStaging ? "true" : "false")
                << ",\"moveAccepted\":" << (moveAccepted ? "true" : "false")
                << ",\"proofStaging\":" << (gBatchProofStaging ? "true" : "false")
                << ",\"stageAccepted\":" << (stageAccepted ? "true" : "false") << "}\n";
        gOutput.flush();
    }

    void captureAppearanceBatch()
    {
        if (gBatchTargetForms.empty() || gFinishRequested)
            return;
        if (!gPortraitCameraLogged || !gAppearanceLogged
            || (gBatchForceWeaponOut && !gBatchWeaponStateLogged))
            return;
        if (gBatchTargetReadyFrame == 0)
        {
            gBatchTargetReadyFrame = gFrame;
            gOutput << "{\"schema\":" << sSchemaJson << ",\"event\":\"batch-target-ready\""
                    << ",\"frame\":" << gFrame
                    << ",\"targetIndex\":" << gBatchTargetIndex
                    << ",\"targetForm\":" << gTargetForm << "}\n";
            gOutput.flush();
            if (gCaptureAnimation)
                writeActor(findDriveActor());
        }
        const UInt32 screenshotFrame = gBatchTargetReadyFrame + gBatchSettleFrames;
        if (!gBatchScreenshotRequested && gFrame >= screenshotFrame)
        {
            gBatchScreenshotRequested = true;
            if (gCaptureAnimation)
                writeActor(findDriveActor());
            const bool accepted = gConsole != nullptr && gConsole->RunScriptLine2("TapKey 183", nullptr, true);
            gOutput << "{\"schema\":" << sSchemaJson << ",\"event\":\"batch-screenshot-request\""
                    << ",\"frame\":" << gFrame
                    << ",\"targetIndex\":" << gBatchTargetIndex
                    << ",\"targetForm\":" << gTargetForm
                    << ",\"accepted\":" << (accepted ? "true" : "false") << "}\n";
            gOutput.flush();
        }
        if (!gBatchScreenshotRequested || gFrame < screenshotFrame + gBatchAdvanceFrames)
            return;

        if (gBatchProofStaging && !gBatchTargetReleaseRequested)
        {
            gBatchTargetReleaseRequested = true;
            TESForm* completedForm = lookupForm(gTargetForm);
            TESObjectREFR* completedReference = completedForm != nullptr && completedForm->GetIsReference()
                ? static_cast<TESObjectREFR*>(completedForm)
                : nullptr;
            const bool moveAccepted = completedReference != nullptr && gConsole != nullptr
                && gConsole->RunScriptLine2("MoveTo 00000014", completedReference, true);
            const bool disableAccepted = completedReference != nullptr && gConsole != nullptr
                && gConsole->RunScriptLine2("Disable", completedReference, true);
            gBatchTargetReleased = moveAccepted && disableAccepted;
            gOutput << "{\"schema\":" << sSchemaJson
                    << ",\"event\":\"batch-target-release\""
                    << ",\"frame\":" << gFrame
                    << ",\"targetIndex\":" << gBatchTargetIndex
                    << ",\"targetForm\":" << gTargetForm
                    << ",\"referenceAvailable\":"
                    << (completedReference != nullptr ? "true" : "false")
                    << ",\"moveToPlayerAccepted\":" << (moveAccepted ? "true" : "false")
                    << ",\"disableAccepted\":" << (disableAccepted ? "true" : "false")
                    << ",\"accepted\":" << (gBatchTargetReleased ? "true" : "false") << "}\n";
            gOutput.flush();
        }
        if (gBatchProofStaging && !gBatchTargetReleased)
            return;

        gOutput << "{\"schema\":" << sSchemaJson << ",\"event\":\"batch-target-complete\""
                << ",\"frame\":" << gFrame
                << ",\"targetIndex\":" << gBatchTargetIndex
                << ",\"targetForm\":" << gTargetForm << "}\n";
        gOutput.flush();
        ++gBatchTargetIndex;
        if (gBatchTargetIndex >= gBatchTargetForms.size())
        {
            finishCapture();
            return;
        }
        gTargetForm = gBatchTargetForms[gBatchTargetIndex];
        gAppearanceLogged = false;
        gPortraitCameraLogged = false;
        gPortraitCameraWaitingLogged = false;
        gFullBodyBoundsWaitingLogged = false;
        gBatchWeaponStateLogged = false;
        gBatchWeaponWaitingLogged = false;
        gBatchWeaponProbeStartFrame = 0;
        gBatchTargetReadyFrame = 0;
        gBatchScreenshotRequested = false;
        gBatchTargetLoadRequested = false;
        gBatchTargetStaged = false;
        gBatchTargetStageFrame = 0;
        gBatchTargetStageWaitingLogged = false;
        gBatchVisualStageGateLogged = false;
        gBatchVisualStageGatePassed = false;
        gBatchTargetReleaseRequested = false;
        gBatchTargetReleased = false;
        gBatchProofCensusLogged = false;
        gBatchProofEvictionCount = 0;
    }

    void sidecarSetPhase(SidecarPhase phase, bool withDeadline = false)
    {
        gSidecarPhase = phase;
        gSidecarPhaseFrame = gFrame;
        gSidecarBarrierDeadlineMs = withDeadline ? GetTickCount64() + gSidecarBarrierTimeoutMs : 0;
    }

    bool sidecarDeadlineExpired()
    {
        return gSidecarBarrierDeadlineMs != 0 && GetTickCount64() >= gSidecarBarrierDeadlineMs;
    }

    Actor* sidecarResolvedActor()
    {
        if (gSidecarResolvedRef == 0)
            return nullptr;
        TESForm* form = lookupForm(gSidecarResolvedRef);
        return form != nullptr && form->IsActor_Runtime() ? static_cast<Actor*>(form) : nullptr;
    }

    NiNode* sidecarActorRootUnsafe(Actor* actor)
    {
        NiNode* root = nullptr;
        __try
        {
            root = actor != nullptr ? actor->GetNiNode() : nullptr;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            root = nullptr;
        }
        return root;
    }

    void sidecarResetCameraForActor()
    {
        gAppearanceLogged = false;
        gPortraitCameraLogged = false;
        gPortraitCameraWaitingLogged = false;
        gFullBodyBoundsWaitingLogged = false;
        gBatchTargetStageWaitingLogged = false;
        gBatchVisualStageGateLogged = false;
        gBatchVisualStageGatePassed = false;
        gBatchProofCensusLogged = false;
        gBatchProofEvictionCount = 0;
        gActorGeometryLogged.erase(gSidecarResolvedRef);
    }

    void sidecarUpdateShared(NikamiFNVSidecar::State state, UInt32 flagsToSet)
    {
        if (gSidecarShared == nullptr || !lockSidecarShared())
        {
            sidecarFail(NikamiFNVSidecar::ErrorCode::SharedMemoryFault,
                "shared-memory-lock-failed");
            return;
        }
        gSidecarShared->header.state = static_cast<UInt32>(state);
        gSidecarShared->header.flags |= flagsToSet;
        gSidecarShared->header.retailFrame = gFrame;
        gSidecarShared->header.deadlineTickMs = gSidecarBarrierDeadlineMs;
        unlockSidecarShared();
    }

    bool sidecarBeginSharedAction()
    {
        if (gSidecarShared == nullptr || gSidecarRetailReadyEvent == nullptr
            || gSidecarOpenMwReadyEvent == nullptr || gSidecarCaptureAckEvent == nullptr
            || gSidecarErrorEvent == nullptr)
            return false;
        if (!lockSidecarShared())
            return false;
        if ((gSidecarShared->header.flags & NikamiFNVSidecar::ErrorFlag) != 0
            || gSidecarShared->header.state
                == static_cast<UInt32>(NikamiFNVSidecar::State::Error))
        {
            unlockSidecarShared();
            return false;
        }
        constexpr UInt32 transient = NikamiFNVSidecar::RetailReadyFlag
            | NikamiFNVSidecar::OpenMwReadyFlag | NikamiFNVSidecar::RetailCapturedFlag
            | NikamiFNVSidecar::OpenMwCapturedFlag | NikamiFNVSidecar::CaptureAckFlag;
        const UInt64 now = GetTickCount64();
        gSidecarGeneration = gSidecarShared->header.generation + 1;
        gSidecarShared->header.generation = gSidecarGeneration;
        gSidecarShared->header.actorIndex = static_cast<UInt32>(gSidecarActorIndex);
        gSidecarShared->header.actionIndex = static_cast<UInt32>(gSidecarActionIndex);
        gSidecarShared->header.actionCount = static_cast<UInt32>(gSidecarPlan.actions.size());
        gSidecarShared->header.captureOrdinal
            = static_cast<UInt64>(gSidecarActorIndex) * gSidecarPlan.actions.size()
            + gSidecarActionIndex;
        gSidecarShared->header.deadlineTickMs = now + gSidecarBarrierTimeoutMs;
        gSidecarShared->header.flags &= ~transient;
        gSidecarShared->header.errorCode = static_cast<UInt32>(NikamiFNVSidecar::ErrorCode::None);
        gSidecarShared->header.errorMessage[0] = '\0';
        gSidecarShared->header.retailPayloadLength = 0;
        gSidecarShared->header.retailPayloadCrc32 = sidecarCrc32(nullptr, 0);
        gSidecarShared->header.openmwPayloadLength = 0;
        gSidecarShared->header.openmwPayloadCrc32 = sidecarCrc32(nullptr, 0);
        gSidecarShared->retailPayload[0] = '\0';
        gSidecarShared->openmwPayload[0] = '\0';
        gSidecarShared->header.openmwFrame = 0;
        gSidecarShared->header.state = static_cast<UInt32>(NikamiFNVSidecar::State::RetailPreparing);
        gSidecarShared->header.retailFrame = gFrame;
        unlockSidecarShared();
        if (!ResetEvent(gSidecarRetailReadyEvent) || !ResetEvent(gSidecarOpenMwReadyEvent)
            || !ResetEvent(gSidecarCaptureAckEvent))
            return false;
        gSidecarBarrierDeadlineMs = now + gSidecarBarrierTimeoutMs;
        gSidecarScreenshotCandidate = {};
        gSidecarScreenshotReady = {};
        gSidecarScreenshotStableFrames = 0;
        return true;
    }

    bool sidecarSharedHas(UInt32 requiredFlag)
    {
        if (gSidecarShared == nullptr)
            return false;
        HANDLE requiredEvent = nullptr;
        if (requiredFlag == NikamiFNVSidecar::OpenMwReadyFlag)
            requiredEvent = gSidecarOpenMwReadyEvent;
        else if (requiredFlag == NikamiFNVSidecar::CaptureAckFlag)
            requiredEvent = gSidecarCaptureAckEvent;
        if (requiredEvent != nullptr && WaitForSingleObject(requiredEvent, 0) != WAIT_OBJECT_0)
            return false;
        if (!lockSidecarShared())
            return false;
        const UInt32 flags = gSidecarShared->header.flags;
        const UInt32 actorIndex = gSidecarShared->header.actorIndex;
        const UInt32 actionIndex = gSidecarShared->header.actionIndex;
        const UInt64 generation = gSidecarShared->header.generation;
        const UInt32 errorCode = gSidecarShared->header.errorCode;
        const std::size_t sequenceLength = strnlen_s(
            gSidecarShared->header.sequenceId, std::size(gSidecarShared->header.sequenceId));
        char sequenceId[128] = {};
        std::memcpy(sequenceId, gSidecarShared->header.sequenceId, sizeof(sequenceId) - 1);
        char errorMessage[256] = {};
        std::memcpy(errorMessage, gSidecarShared->header.errorMessage, sizeof(errorMessage) - 1);
        const UInt32 payloadLength = gSidecarShared->header.openmwPayloadLength;
        const UInt32 payloadCrc = gSidecarShared->header.openmwPayloadCrc32;
        std::string payload;
        if (payloadLength <= NikamiFNVSidecar::PayloadBytes)
            payload.assign(gSidecarShared->openmwPayload,
                gSidecarShared->openmwPayload + payloadLength);
        unlockSidecarShared();
        if ((flags & NikamiFNVSidecar::ErrorFlag) != 0)
        {
            sidecarFail(errorCode <= static_cast<UInt32>(NikamiFNVSidecar::ErrorCode::InternalFault)
                    ? static_cast<NikamiFNVSidecar::ErrorCode>(errorCode)
                    : NikamiFNVSidecar::ErrorCode::InternalFault,
                std::string("peer-error-") + errorMessage);
            return false;
        }
        if ((flags & requiredFlag) == 0)
            return false;
        if (sequenceLength == sizeof(sequenceId)
            || gSidecarPlan.sequenceId != std::string(sequenceId, sequenceLength)
            || actorIndex != gSidecarActorIndex || actionIndex != gSidecarActionIndex
            || generation != gSidecarGeneration)
        {
            sidecarFail(NikamiFNVSidecar::ErrorCode::SharedMemoryFault,
                "peer-ready-identity-mismatch");
            return false;
        }
        if ((requiredFlag == NikamiFNVSidecar::OpenMwReadyFlag
                || requiredFlag == NikamiFNVSidecar::CaptureAckFlag)
            && (payloadLength == 0 || payloadLength > NikamiFNVSidecar::PayloadBytes
                || sidecarCrc32(payload.data(), payload.size()) != payloadCrc
                || payload.front() != '{' || payload.back() != '}'))
        {
            sidecarFail(NikamiFNVSidecar::ErrorCode::SharedMemoryFault,
                "openmw-payload-contract-failed");
            return false;
        }
        if (requiredFlag == NikamiFNVSidecar::OpenMwReadyFlag
            && (flags & NikamiFNVSidecar::RetailReadyFlag) == 0)
        {
            sidecarFail(NikamiFNVSidecar::ErrorCode::SharedMemoryFault,
                "openmw-ready-before-retail-ready");
            return false;
        }
        constexpr UInt32 capturedFlags = NikamiFNVSidecar::RetailCapturedFlag
            | NikamiFNVSidecar::OpenMwCapturedFlag;
        if (requiredFlag == NikamiFNVSidecar::CaptureAckFlag
            && (flags & capturedFlags) != capturedFlags)
        {
            sidecarFail(NikamiFNVSidecar::ErrorCode::SharedMemoryFault,
                "capture-ack-before-both-files");
            return false;
        }
        return true;
    }

    bool sidecarReadSceneState(UInt32& weather, float& hour)
    {
        weather = 0;
        hour = 0.f;
        const UInt8* sky = nullptr;
        if (!safeRead(reinterpret_cast<const void*>(0x011DEA20), sky) || sky == nullptr)
            return false;
        TESWeather* current = nullptr;
        if (!safeRead(sky + 0x10, current) || current == nullptr
            || !safeRead(&current->refID, weather) || !safeRead(sky + 0xEC, hour))
            return false;
        return std::isfinite(hour);
    }

    bool sidecarValidateRuntimePlan(std::string& error)
    {
        TESForm* anchor = lookupForm(gSidecarPlan.anchorForm);
        TESForm* weather = lookupForm(gSidecarPlan.weatherForm);
        UInt8 weatherType = 0;
        if (anchor == nullptr || !anchor->GetIsReference())
        {
            error = "proof-anchor-is-not-a-reference";
            return false;
        }
        if (weather == nullptr || !safeRead(&weather->typeID, weatherType)
            || weatherType != kFormType_TESWeather)
        {
            error = "weather-form-is-not-weather";
            return false;
        }
        for (std::size_t index = 0; index < gSidecarPlan.actors.size(); ++index)
        {
            const SidecarActorPlan& actorPlan = gSidecarPlan.actors[index];
            TESForm* base = lookupForm(actorPlan.baseForm);
            UInt8 baseType = 0;
            if (base == nullptr || !safeRead(&base->typeID, baseType)
                || (baseType != kFormType_TESNPC && baseType != kFormType_TESCreature))
            {
                error = "actor-base-form-type-invalid-index-" + std::to_string(index);
                return false;
            }
            if (actorPlan.authoredRefForm != 0)
            {
                TESForm* authored = lookupForm(actorPlan.authoredRefForm);
                Actor* actor = authored != nullptr && authored->IsActor_Runtime()
                    ? static_cast<Actor*>(authored) : nullptr;
                UInt32 reference = 0;
                UInt32 actualBase = 0;
                if (!sidecarReadActorIdentity(actor, reference, actualBase)
                    || reference != actorPlan.authoredRefForm || actualBase != actorPlan.baseForm)
                {
                    error = "authored-reference-correlation-invalid-index-" + std::to_string(index);
                    return false;
                }
            }
            if (actorPlan.weaponForm != 0)
            {
                TESForm* weapon = lookupForm(actorPlan.weaponForm);
                UInt8 weaponType = 0;
                if (weapon == nullptr || !safeRead(&weapon->typeID, weaponType)
                    || weaponType != kFormType_TESObjectWEAP)
                {
                    error = "weapon-form-type-invalid-index-" + std::to_string(index);
                    return false;
                }
            }
            if (actorPlan.enableParentForm != 0)
            {
                TESForm* parent = lookupForm(actorPlan.enableParentForm);
                if (parent == nullptr || !parent->GetIsReference())
                {
                    error = "enable-parent-is-not-reference-index-" + std::to_string(index);
                    return false;
                }
            }
        }
        return true;
    }

    bool sidecarRequestSceneStateCommand(UInt32 commandIndex, const char*& commandName)
    {
        if (gConsole == nullptr)
            return false;
        char command[96] = {};
        switch (commandIndex)
        {
            case 0:
                commandName = "game-hour";
                sprintf_s(command, "Set GameHour To %.6f", gSidecarPlan.gameHour);
                break;
            case 1:
                commandName = "weather";
                sprintf_s(command, "fw %08X", gSidecarPlan.weatherForm);
                break;
            default:
                commandName = "invalid";
                return false;
        }
        return gConsole->RunScriptLine2(command, nullptr, true);
    }

    bool sidecarRequestTimeFreeze()
    {
        if (gConsole == nullptr)
            return false;
        char command[96] = {};
        sprintf_s(command, "Set TimeScale To %.6f", gSidecarPlan.timeScale);
        return gConsole->RunScriptLine2(command, nullptr, true);
    }

    bool sidecarStageResolvedActor(Actor* actor)
    {
        if (actor == nullptr || gConsole == nullptr)
            return false;
        const bool enabled = gConsole->RunScriptLine2("Enable", actor, true);
        const bool moved = gConsole->RunScriptLine2("MoveTo 00000014", actor, true);
        const bool x = runReferenceFloatCommand(actor, "SetPos X", gSidecarPlan.targetX);
        const bool y = runReferenceFloatCommand(actor, "SetPos Y", gSidecarPlan.targetY);
        const bool z = runReferenceFloatCommand(actor, "SetPos Z", gSidecarPlan.targetZ);
        const bool rx = runReferenceFloatCommand(actor, "SetAngle X", 0.f);
        const bool ry = runReferenceFloatCommand(actor, "SetAngle Y", 0.f);
        const float yawDegrees = gSidecarPlan.targetYaw * 180.f / 3.14159265358979323846f;
        const bool rz = runReferenceFloatCommand(actor, "SetAngle Z", yawDegrees);
        gOutput << "{\"schema\":\"nikami-fnv-sidecar-retail/v1\",\"event\":\"sidecar-actor-stage\""
                << ",\"sequenceId\":" << jsonString(gSidecarPlan.sequenceId.c_str())
                << ",\"actorIndex\":" << gSidecarActorIndex << ",\"refForm\":" << gSidecarResolvedRef
                << ",\"baseForm\":" << gSidecarPlan.actors[gSidecarActorIndex].baseForm
                << ",\"spawned\":" << (gSidecarResolvedSpawned ? "true" : "false")
                << ",\"accepted\":[" << (enabled ? "true" : "false") << ','
                << (moved ? "true" : "false") << ',' << (x ? "true" : "false") << ','
                << (y ? "true" : "false") << ',' << (z ? "true" : "false") << ','
                << (rx ? "true" : "false") << ',' << (ry ? "true" : "false") << ','
                << (rz ? "true" : "false") << "]}\n";
        gOutput.flush();
        return enabled && moved && x && y && z && rx && ry && rz;
    }

    float sidecarAngleDistance(float left, float right)
    {
        constexpr float pi = 3.14159265358979323846f;
        constexpr float tau = 2.f * pi;
        float delta = std::fmod(std::fabs(left - right), tau);
        return delta > pi ? tau - delta : delta;
    }

    bool sidecarActorMatchesStage(Actor* actor, float& positionError, float& yawError)
    {
        positionError = (std::numeric_limits<float>::infinity)();
        yawError = (std::numeric_limits<float>::infinity)();
        float x = 0.f;
        float y = 0.f;
        float z = 0.f;
        float rx = 0.f;
        float ry = 0.f;
        float rz = 0.f;
        if (actor == nullptr || !safeRead(&actor->posX, x) || !safeRead(&actor->posY, y)
            || !safeRead(&actor->posZ, z) || !safeRead(&actor->rotX, rx)
            || !safeRead(&actor->rotY, ry) || !safeRead(&actor->rotZ, rz))
            return false;
        const float dx = x - gSidecarPlan.targetX;
        const float dy = y - gSidecarPlan.targetY;
        const float dz = z - gSidecarPlan.targetZ;
        positionError = std::sqrt(dx * dx + dy * dy + dz * dz);
        yawError = sidecarAngleDistance(rz, gSidecarPlan.targetYaw);
        return std::isfinite(positionError) && std::isfinite(yawError)
            && positionError <= 0.05f && std::fabs(rx) <= 0.001f
            && std::fabs(ry) <= 0.001f && yawError <= 0.001f;
    }

    void sidecarCleanupResolvedActor()
    {
        Actor* actor = sidecarResolvedActor();
        if (actor != nullptr && gConsole != nullptr)
        {
            gConsole->RunScriptLine2("MoveTo 00000014", actor, true);
            gConsole->RunScriptLine2("Disable", actor, true);
            if (gSidecarResolvedSpawned)
                gConsole->RunScriptLine2("MarkForDelete", actor, true);
        }
        gTargetForm = 0;
        gDrivenActor = nullptr;
        gSidecarResolvedRef = 0;
        gSidecarResolvedSpawned = false;
        gBatchTargetStaged = false;
        gPortraitCameraLogged = false;
    }

    void driveSidecarPlan()
    {
        if (!gSidecarPlanActive || gSidecarPhase == SidecarPhase::Disabled)
            return;
        PlayerCharacter* player = nullptr;
        safeRead(reinterpret_cast<const void*>(0x011DEA3C), player);

        switch (gSidecarPhase)
        {
            case SidecarPhase::LoadProofVolume:
            {
                gSidecarSceneStateRequested = false;
                gSidecarSceneStateCommandIndex = 0;
                gSidecarTimeFreezeRequested = false;
                gSidecarTimeFreezeRequestFrame = 0;
                std::string runtimePlanError;
                if (!sidecarValidateRuntimePlan(runtimePlanError))
                {
                    sidecarFail(NikamiFNVSidecar::ErrorCode::InvalidPlan, runtimePlanError);
                    break;
                }
                TESForm* anchorForm = lookupForm(gSidecarPlan.anchorForm);
                TESObjectREFR* anchor = anchorForm != nullptr && anchorForm->GetIsReference()
                    ? static_cast<TESObjectREFR*>(anchorForm) : nullptr;
                if (gConsole == nullptr || player == nullptr || anchor == nullptr)
                {
                    sidecarFail(NikamiFNVSidecar::ErrorCode::InvalidPlan,
                        "proof-anchor-or-player-unavailable");
                    break;
                }
                char command[64] = {};
                sprintf_s(command, "player.moveto %08X", gSidecarPlan.anchorForm);
                if (!gConsole->RunScriptLine2(command, nullptr, true))
                {
                    sidecarFail(NikamiFNVSidecar::ErrorCode::InvalidPlan,
                        "proof-anchor-move-rejected");
                    break;
                }
                gBatchProofLoadFrame = gFrame;
                bootstrapProofFreeCamera(player);
                gOutput << "{\"schema\":\"nikami-fnv-sidecar-retail/v1\",\"event\":\"sidecar-proof-volume-request\""
                        << ",\"sequenceId\":" << jsonString(gSidecarPlan.sequenceId.c_str())
                        << ",\"frame\":" << gFrame << ",\"anchorForm\":" << gSidecarPlan.anchorForm
                        << ",\"weatherForm\":" << gSidecarPlan.weatherForm
                        << ",\"gameHour\":" << gSidecarPlan.gameHour << "}\n";
                gOutput.flush();
                // Hidden/minimized retail can advance well below one frame per second while the proof
                // volume streams.  The initialization gate is frame based, so starting the wall-clock
                // barrier here can consume the entire timeout before the scene-state commands are even
                // issued.  Arm the convergence deadline only after both commands have been accepted.
                sidecarSetPhase(SidecarPhase::WaitProofVolume);
                break;
            }
            case SidecarPhase::WaitProofVolume:
            {
                bootstrapProofFreeCamera(player);
                if (!gSidecarSceneStateRequested)
                {
                    if (gFrame < gSidecarPhaseFrame + gSidecarPlan.initializationFrames)
                        break;
                    const char* commandName = nullptr;
                    const UInt32 commandIndex = gSidecarSceneStateCommandIndex;
                    const bool accepted = sidecarRequestSceneStateCommand(commandIndex, commandName);
                    gOutput << "{\"schema\":\"nikami-fnv-sidecar-retail/v1\",\"event\":\"sidecar-scene-command-request\""
                            << ",\"sequenceId\":" << jsonString(gSidecarPlan.sequenceId.c_str())
                            << ",\"frame\":" << gFrame << ",\"commandIndex\":" << commandIndex
                            << ",\"command\":" << jsonString(commandName)
                            << ",\"accepted\":"
                            << (accepted ? "true" : "false") << "}\n";
                    gOutput.flush();
                    if (!accepted)
                    {
                        sidecarFail(NikamiFNVSidecar::ErrorCode::InternalFault,
                            "scene-state-command-rejected");
                        break;
                    }
                    ++gSidecarSceneStateCommandIndex;
                    if (gSidecarSceneStateCommandIndex < 2)
                        break;
                    gSidecarSceneStateRequested = true;
                    gSidecarBarrierDeadlineMs = GetTickCount64() + gSidecarBarrierTimeoutMs;
                    gOutput << "{\"schema\":\"nikami-fnv-sidecar-retail/v1\",\"event\":\"sidecar-scene-state-convergence-start\""
                            << ",\"sequenceId\":" << jsonString(gSidecarPlan.sequenceId.c_str())
                            << ",\"frame\":" << gFrame
                            << ",\"timeoutMilliseconds\":" << gSidecarBarrierTimeoutMs << "}\n";
                    gOutput.flush();
                }
                if (gFrame < gSidecarPhaseFrame + gSidecarPlan.initializationFrames || player == nullptr)
                    break;
                const bool x = runReferenceFloatCommand(player, "SetPos X", gSidecarPlan.playerX);
                const bool y = runReferenceFloatCommand(player, "SetPos Y", gSidecarPlan.playerY);
                const bool z = runReferenceFloatCommand(player, "SetPos Z", gSidecarPlan.playerZ);
                UInt32 weather = 0;
                float hour = 0.f;
                const bool sceneReadable = sidecarReadSceneState(weather, hour);
                float hourError = sceneReadable ? std::fabs(hour - gSidecarPlan.gameHour) : 24.f;
                if (hourError > 12.f)
                    hourError = 24.f - hourError;
                if (x && y && z && sceneReadable && weather == gSidecarPlan.weatherForm && hourError <= 0.01f)
                {
                    gBatchProofVolumeReady = true;
                    gOutput << "{\"schema\":\"nikami-fnv-sidecar-retail/v1\",\"event\":\"sidecar-proof-volume-ready\""
                            << ",\"sequenceId\":" << jsonString(gSidecarPlan.sequenceId.c_str())
                            << ",\"frame\":" << gFrame << ",\"weatherForm\":" << weather
                            << ",\"gameHour\":" << hour << "}\n";
                    gOutput.flush();
                    sidecarSetPhase(SidecarPhase::FreezeTime);
                }
                else if (sidecarDeadlineExpired())
                    sidecarFail(NikamiFNVSidecar::ErrorCode::RetailReadyTimeout,
                        "proof-volume-time-weather-timeout");
                else if ((gFrame - gSidecarPhaseFrame) % 30 == 0)
                {
                    gSidecarSceneStateRequested = false;
                    gSidecarSceneStateCommandIndex = 0;
                }
                break;
            }
            case SidecarPhase::FreezeTime:
            {
                bootstrapProofFreeCamera(player);
                if (gFrame < gSidecarPhaseFrame + gSidecarPlan.targetSettleFrames)
                    break;
                if (!gSidecarTimeFreezeRequested)
                {
                    const bool accepted = sidecarRequestTimeFreeze();
                    gSidecarTimeFreezeRequested = true;
                    gSidecarTimeFreezeRequestFrame = gFrame;
                    gOutput << "{\"schema\":\"nikami-fnv-sidecar-retail/v1\",\"event\":\"sidecar-time-freeze-request\""
                            << ",\"sequenceId\":" << jsonString(gSidecarPlan.sequenceId.c_str())
                            << ",\"frame\":" << gFrame << ",\"accepted\":"
                            << (accepted ? "true" : "false") << "}\n";
                    gOutput.flush();
                    if (!accepted)
                        sidecarFail(NikamiFNVSidecar::ErrorCode::InternalFault,
                            "time-freeze-command-rejected");
                    break;
                }
                if (gFrame < gSidecarTimeFreezeRequestFrame + gSidecarPlan.targetSettleFrames)
                    break;
                sidecarSetPhase(SidecarPhase::SelectActor);
                break;
            }
            case SidecarPhase::SelectActor:
            {
                if (gSidecarActorIndex >= gSidecarPlan.actors.size())
                {
                    sidecarSetPhase(SidecarPhase::Complete);
                    break;
                }
                const SidecarActorPlan& plan = gSidecarPlan.actors[gSidecarActorIndex];
                gSidecarActionIndex = 0;
                gSidecarResolvedRef = 0;
                gSidecarResolvedSpawned = false;
                gSidecarWeaponPolicyApplied = false;
                if (plan.enableParentForm != 0)
                {
                    TESForm* parentForm = lookupForm(plan.enableParentForm);
                    TESObjectREFR* parent = parentForm != nullptr && parentForm->GetIsReference()
                        ? static_cast<TESObjectREFR*>(parentForm) : nullptr;
                    if (parent == nullptr || gConsole == nullptr
                        || !gConsole->RunScriptLine2("Enable", parent, true))
                    {
                        sidecarFail(NikamiFNVSidecar::ErrorCode::ActorUnavailable,
                            "enable-parent-unavailable-or-rejected");
                        break;
                    }
                }
                if (plan.authoredRefForm != 0)
                {
                    TESForm* form = lookupForm(plan.authoredRefForm);
                    Actor* actor = form != nullptr && form->IsActor_Runtime()
                        ? static_cast<Actor*>(form) : nullptr;
                    UInt32 reference = 0;
                    UInt32 base = 0;
                    if (!sidecarReadActorIdentity(actor, reference, base)
                        || reference != plan.authoredRefForm || base != plan.baseForm)
                    {
                        sidecarFail(NikamiFNVSidecar::ErrorCode::ActorUnavailable,
                            "authored-reference-base-correlation-failed");
                        break;
                    }
                    gSidecarResolvedRef = reference;
                    sidecarSetPhase(SidecarPhase::StageActor, true);
                    break;
                }
                gSidecarSpawnBaselineRefs.clear();
                std::set<Actor*> actors;
                sidecarCollectActors(actors);
                for (Actor* actor : actors)
                {
                    UInt32 reference = 0;
                    UInt32 base = 0;
                    if (sidecarReadActorIdentity(actor, reference, base))
                        gSidecarSpawnBaselineRefs.insert(reference);
                }
                char command[96] = {};
                sprintf_s(command, "player.placeatme %08X 1", plan.baseForm);
                if (gConsole == nullptr || !gConsole->RunScriptLine2(command, nullptr, true))
                {
                    sidecarFail(NikamiFNVSidecar::ErrorCode::ActorSpawnFailed,
                        "spawn-command-rejected");
                    break;
                }
                gSidecarSpawnRequestFrame = gFrame;
                sidecarSetPhase(SidecarPhase::WaitSpawn, true);
                break;
            }
            case SidecarPhase::WaitSpawn:
            {
                const std::vector<Actor*> actors = sidecarFindSpawnedActors(
                    gSidecarPlan.actors[gSidecarActorIndex].baseForm);
                if (actors.size() > 1)
                {
                    sidecarFail(NikamiFNVSidecar::ErrorCode::ActorSpawnFailed,
                        "spawn-correlation-ambiguous");
                }
                else if (actors.size() == 1)
                {
                    UInt32 base = 0;
                    sidecarReadActorIdentity(actors.front(), gSidecarResolvedRef, base);
                    gSidecarResolvedSpawned = true;
                    sidecarSetPhase(SidecarPhase::StageActor, true);
                }
                else if (sidecarDeadlineExpired())
                    sidecarFail(NikamiFNVSidecar::ErrorCode::ActorSpawnFailed,
                        "spawn-correlation-timeout");
                break;
            }
            case SidecarPhase::StageActor:
            {
                Actor* actor = sidecarResolvedActor();
                UInt32 reference = 0;
                UInt32 base = 0;
                if (!sidecarReadActorIdentity(actor, reference, base)
                    || base != gSidecarPlan.actors[gSidecarActorIndex].baseForm)
                {
                    if (sidecarDeadlineExpired())
                        sidecarFail(NikamiFNVSidecar::ErrorCode::ActorUnavailable,
                            "resolved-actor-lost-before-stage");
                    break;
                }
                if (!sidecarStageResolvedActor(actor))
                {
                    sidecarFail(NikamiFNVSidecar::ErrorCode::ActorUnavailable,
                        "actor-stage-command-rejected");
                    break;
                }
                gTargetForm = reference;
                gDrivenActor = actor;
                gBatchTargetStaged = true;
                gBatchTargetStageFrame = gFrame;
                sidecarResetCameraForActor();
                bootstrapProofFreeCamera(player);
                sidecarSetPhase(SidecarPhase::WaitActor3D, true);
                break;
            }
            case SidecarPhase::WaitActor3D:
            {
                Actor* actor = sidecarResolvedActor();
                float positionError = 0.f;
                float yawError = 0.f;
                if (actor != nullptr && sidecarActorRootUnsafe(actor) != nullptr
                    && sidecarActorMatchesStage(actor, positionError, yawError)
                    && gFrame >= gSidecarPhaseFrame + gSidecarPlan.targetSettleFrames)
                    sidecarSetPhase(SidecarPhase::ApplyWeapon, true);
                else if (sidecarDeadlineExpired())
                    sidecarFail(NikamiFNVSidecar::ErrorCode::ActorUnavailable,
                        "actor-3d-generation-timeout");
                break;
            }
            case SidecarPhase::ApplyWeapon:
            {
                Actor* actor = sidecarResolvedActor();
                const UInt32 weapon = gSidecarPlan.actors[gSidecarActorIndex].weaponForm;
                gSidecarWeaponPolicyApplied = sidecarApplyExactWeapon(actor, weapon);
                gSidecarWeaponVerifyStartFrame = gFrame;
                if (!gSidecarWeaponPolicyApplied)
                {
                    sidecarFail(NikamiFNVSidecar::ErrorCode::WeaponPolicyFailed,
                        "exact-weapon-application-rejected");
                    break;
                }
                sidecarSetPhase(SidecarPhase::VerifyWeapon, true);
                break;
            }
            case SidecarPhase::VerifyWeapon:
            {
                Actor* actor = sidecarResolvedActor();
                const UInt32 weapon = gSidecarPlan.actors[gSidecarActorIndex].weaponForm;
                if (gFrame >= gSidecarWeaponVerifyStartFrame + 2
                    && sidecarVerifyExactWeapon(actor, weapon))
                {
                    if (weapon != 0)
                        setWeaponOutUnsafe(actor);
                    sidecarSetPhase(SidecarPhase::StartAction);
                }
                else if (sidecarDeadlineExpired())
                    sidecarFail(NikamiFNVSidecar::ErrorCode::WeaponPolicyFailed,
                        "exact-weapon-verification-timeout");
                break;
            }
            case SidecarPhase::StartAction:
            {
                if (gSidecarActionIndex >= gSidecarPlan.actions.size())
                {
                    sidecarSetPhase(SidecarPhase::CleanupActor);
                    break;
                }
                Actor* actor = sidecarResolvedActor();
                const SidecarActionPlan& action = gSidecarPlan.actions[gSidecarActionIndex];
                char command[256] = {};
                sprintf_s(command, "PlayGroup %s 1", action.playGroup.c_str());
                gSidecarActionAccepted = actor != nullptr && gConsole != nullptr
                    && gConsole->RunScriptLine2(command, actor, true);
                if (!gSidecarActionAccepted)
                {
                    sidecarFail(NikamiFNVSidecar::ErrorCode::ActionRejected,
                        std::string("play-group-rejected-") + action.id);
                    break;
                }
                if (gSidecarPlan.actors[gSidecarActorIndex].weaponForm != 0)
                    setWeaponOutUnsafe(actor);
                if (!sidecarBeginSharedAction())
                {
                    sidecarFail(NikamiFNVSidecar::ErrorCode::SharedMemoryFault,
                        "shared-action-initialization-failed");
                    break;
                }
                gSidecarActionStartFrame = gFrame;
                gSidecarRetailReadyPublished = false;
                gSidecarScreenshotAccepted = false;
                sidecarResetCameraForActor();
                const std::string telemetry = sidecarBuildTelemetry(actor, false, nullptr);
                if (!publishSidecarRetailPayload(
                        telemetry, NikamiFNVSidecar::State::RetailPreparing, 0, false))
                {
                    sidecarFail(NikamiFNVSidecar::ErrorCode::SharedMemoryFault,
                        "retail-preparing-payload-too-large-or-lock-failed");
                    break;
                }
                gOutput << "{\"schema\":\"nikami-fnv-sidecar-retail/v1\",\"event\":\"sidecar-action-start\""
                        << ",\"sequenceId\":" << jsonString(gSidecarPlan.sequenceId.c_str())
                        << ",\"actorIndex\":" << gSidecarActorIndex
                        << ",\"actionIndex\":" << gSidecarActionIndex
                        << ",\"generation\":" << gSidecarGeneration
                        << ",\"id\":" << jsonString(action.id.c_str()) << "}\n";
                gOutput.flush();
                sidecarSetPhase(SidecarPhase::SettleAction, true);
                break;
            }
            case SidecarPhase::SettleAction:
            {
                Actor* actor = sidecarResolvedActor();
                const SidecarActionPlan& action = gSidecarPlan.actions[gSidecarActionIndex];
                if (!sidecarVerifyExactWeapon(actor,
                        gSidecarPlan.actors[gSidecarActorIndex].weaponForm))
                {
                    sidecarFail(NikamiFNVSidecar::ErrorCode::WeaponPolicyFailed,
                        "weapon-policy-lost-during-action");
                    break;
                }
                if (gFrame >= gSidecarActionStartFrame + action.frames && gPortraitCameraLogged
                    && sidecarHasEvaluatedAnimation(actor))
                    sidecarSetPhase(SidecarPhase::PublishRetailReady, true);
                else if (sidecarDeadlineExpired())
                    sidecarFail(NikamiFNVSidecar::ErrorCode::RetailReadyTimeout,
                        "action-animation-or-camera-settle-timeout");
                break;
            }
            case SidecarPhase::PublishRetailReady:
            {
                Actor* actor = sidecarResolvedActor();
                const std::string telemetry = sidecarBuildTelemetry(actor, false, nullptr);
                if (!publishSidecarRetailPayload(telemetry, NikamiFNVSidecar::State::RetailReady,
                        NikamiFNVSidecar::RetailReadyFlag, false))
                {
                    sidecarFail(NikamiFNVSidecar::ErrorCode::SharedMemoryFault,
                        "retail-ready-payload-too-large-or-lock-failed");
                    break;
                }
                SetEvent(gSidecarRetailReadyEvent);
                gSidecarRetailReadyPublished = true;
                gOutput << "{\"schema\":\"nikami-fnv-sidecar-retail/v1\",\"event\":\"sidecar-retail-ready\""
                        << ",\"sequenceId\":" << jsonString(gSidecarPlan.sequenceId.c_str())
                        << ",\"actorIndex\":" << gSidecarActorIndex
                        << ",\"actionIndex\":" << gSidecarActionIndex
                        << ",\"generation\":" << gSidecarGeneration
                        << ",\"telemetry\":" << telemetry << "}\n";
                gOutput.flush();
                sidecarSetPhase(SidecarPhase::WaitOpenMwReady, true);
                break;
            }
            case SidecarPhase::WaitOpenMwReady:
                if (sidecarSharedHas(NikamiFNVSidecar::OpenMwReadyFlag))
                {
                    sidecarUpdateShared(NikamiFNVSidecar::State::BothReady, 0);
                    sidecarSetPhase(SidecarPhase::RequestScreenshot, true);
                }
                else if (sidecarDeadlineExpired())
                    sidecarFail(NikamiFNVSidecar::ErrorCode::OpenMwReadyTimeout,
                        "openmw-ready-timeout");
                break;
            case SidecarPhase::RequestScreenshot:
            {
                gSidecarScreenshotBaseline = sidecarNewestScreenshot();
                gSidecarScreenshotCandidate = {};
                gSidecarScreenshotReady = {};
                gSidecarScreenshotStableFrames = 0;
                gSidecarScreenshotRequestFrame = gFrame;
                std::string screenshotPath;
                long captureResult = E_FAIL;
                gSidecarScreenshotAccepted
                    = sidecarCaptureBackBuffer(screenshotPath, captureResult);
                gOutput << "{\"schema\":\"nikami-fnv-sidecar-retail/v1\",\"event\":\"sidecar-screenshot-request\""
                        << ",\"sequenceId\":" << jsonString(gSidecarPlan.sequenceId.c_str())
                        << ",\"actorIndex\":" << gSidecarActorIndex
                        << ",\"actionIndex\":" << gSidecarActionIndex
                        << ",\"generation\":" << gSidecarGeneration
                        << ",\"frame\":" << gFrame << ",\"mode\":\"d3d9-backbuffer\""
                        << ",\"path\":" << jsonString(screenshotPath.c_str())
                        << ",\"result\":" << captureResult
                        << ",\"accepted\":" << (gSidecarScreenshotAccepted ? "true" : "false")
                        << "}\n";
                gOutput.flush();
                if (!gSidecarScreenshotAccepted)
                {
                    sidecarFail(NikamiFNVSidecar::ErrorCode::ScreenshotTimeout,
                        "screenshot-request-rejected");
                    break;
                }
                sidecarUpdateShared(NikamiFNVSidecar::State::CaptureIssued, 0);
                sidecarSetPhase(SidecarPhase::WaitScreenshotFile, true);
                break;
            }
            case SidecarPhase::WaitScreenshotFile:
            {
                const SidecarScreenshotFile candidate = sidecarNewestScreenshot();
                SidecarScreenshotFile validated;
                if (sidecarScreenshotIsNew(gSidecarScreenshotBaseline, candidate)
                    && sidecarScreenshotStableAndComplete(candidate, validated))
                {
                    gSidecarScreenshotReady = validated;
                    const std::string telemetry = sidecarBuildTelemetry(
                        sidecarResolvedActor(), true, &gSidecarScreenshotReady);
                    if (!publishSidecarRetailPayload(telemetry,
                            NikamiFNVSidecar::State::WaitingCaptureAck,
                            NikamiFNVSidecar::RetailCapturedFlag, false))
                    {
                        sidecarFail(NikamiFNVSidecar::ErrorCode::SharedMemoryFault,
                            "retail-captured-payload-too-large-or-lock-failed");
                        break;
                    }
                    gOutput << "{\"schema\":\"nikami-fnv-sidecar-retail/v1\",\"event\":\"sidecar-screenshot-ready\""
                            << ",\"sequenceId\":" << jsonString(gSidecarPlan.sequenceId.c_str())
                            << ",\"actorIndex\":" << gSidecarActorIndex
                            << ",\"actionIndex\":" << gSidecarActionIndex
                            << ",\"generation\":" << gSidecarGeneration
                            << ",\"telemetry\":" << telemetry << "}\n";
                    gOutput.flush();
                    sidecarSetPhase(SidecarPhase::WaitCaptureAck, true);
                }
                else if (sidecarDeadlineExpired())
                    sidecarFail(NikamiFNVSidecar::ErrorCode::ScreenshotTimeout,
                        "screenshot-file-timeout");
                break;
            }
            case SidecarPhase::WaitCaptureAck:
                if (sidecarSharedHas(NikamiFNVSidecar::CaptureAckFlag))
                    sidecarSetPhase(SidecarPhase::AdvanceAction);
                else if (sidecarDeadlineExpired())
                    sidecarFail(NikamiFNVSidecar::ErrorCode::CaptureAckTimeout,
                        "capture-ack-timeout");
                break;
            case SidecarPhase::AdvanceAction:
                sidecarUpdateShared(NikamiFNVSidecar::State::Advancing, 0);
                ++gSidecarActionIndex;
                sidecarSetPhase(gSidecarActionIndex < gSidecarPlan.actions.size()
                        ? SidecarPhase::StartAction : SidecarPhase::CleanupActor);
                break;
            case SidecarPhase::CleanupActor:
                sidecarCleanupResolvedActor();
                ++gSidecarActorIndex;
                sidecarSetPhase(gSidecarActorIndex < gSidecarPlan.actors.size()
                        ? SidecarPhase::SelectActor : SidecarPhase::Complete);
                break;
            case SidecarPhase::Complete:
                sidecarUpdateShared(NikamiFNVSidecar::State::Complete,
                    NikamiFNVSidecar::RetailCompleteFlag);
                gOutput << "{\"schema\":\"nikami-fnv-sidecar-retail/v1\",\"event\":\"sidecar-sequence-complete\""
                        << ",\"sequenceId\":" << jsonString(gSidecarPlan.sequenceId.c_str())
                        << ",\"actors\":" << gSidecarPlan.actors.size()
                        << ",\"actionsPerActor\":" << gSidecarPlan.actions.size()
                        << ",\"captures\":" << gSidecarPlan.actors.size() * gSidecarPlan.actions.size()
                        << ",\"frame\":" << gFrame << "}\n";
                gOutput.flush();
                gSidecarPhase = SidecarPhase::Disabled;
                finishCapture();
                break;
            case SidecarPhase::Error:
                finishCapture();
                break;
            default:
                break;
        }
    }

    void captureFrame()
    {
        openOutput();
        if (!gOutput || !gWorldReady)
            return;
        if (gFrame >= gMaxFrames)
        {
            if (gSidecarPlanActive)
                sidecarFail(NikamiFNVSidecar::ErrorCode::RetailReadyTimeout,
                    "sidecar-max-frames-exhausted");
            finishCapture();
            return;
        }
        ++gFrame;
        captureRequestedGameSettings();
        if (gSidecarPlanActive)
        {
            driveSidecarPlan();
            gOutput.flush();
            return;
        }
        driveBatchTargetLoading();
        captureTargetAppearance();
        captureAppearanceBatch();
        if (!gBehaviorBeforeCaptured && gFrame >= gBehaviorBeforeFrame)
        {
            gBehaviorBeforeCaptured = true;
            captureBehaviorSnapshot("before");
        }
        if (!gBehaviorCommandsRun && gFrame >= gBehaviorCommandFrame)
            runBehaviorCommands();
        while (gScreenshotFrameIndex < gScreenshotFrames.size()
            && gFrame >= gScreenshotFrames[gScreenshotFrameIndex])
        {
            const UInt32 requestedFrame = gScreenshotFrames[gScreenshotFrameIndex++];
            const bool accepted = gConsole != nullptr
                && gConsole->RunScriptLine2("TapKey 183", nullptr, true);
            gOutput << "{\"schema\":" << sSchemaJson
                    << ",\"event\":\"screenshot-request\""
                    << ",\"frame\":" << gFrame
                    << ",\"requestedFrame\":" << requestedFrame
                    << ",\"accepted\":" << (accepted ? "true" : "false") << "}\n";
            gOutput.flush();
        }
        if (!gBehaviorAfterCaptured && gFrame >= gBehaviorAfterFrame)
        {
            gBehaviorAfterCaptured = true;
            captureBehaviorSnapshot("after");
        }
        if (gFrame % gSampleEvery != 0)
        {
            if (gFrame >= gMaxFrames)
                finishCapture();
            return;
        }

        if (gCaptureAnimation || gFurnitureOnly)
        {
            std::set<Actor*> captured;
            if (gFurnitureOnly && gDrivenActor == nullptr)
                gDrivenActor = findDriveActor();
            if (gDrivenActor != nullptr)
            {
                captured.insert(gDrivenActor);
                writeActor(gDrivenActor);
            }
            PlayerCharacter* player = *reinterpret_cast<PlayerCharacter**>(0x011DEA3C);
            if (player != nullptr)
            {
                captured.insert(player);
                writeActor(player);
            }

            if (gCaptureAnimation && gAllHighActors)
            {
                ActorProcessManager* manager = reinterpret_cast<ActorProcessManager*>(0x011E0E80);
                for (auto* node = manager->highActors.Head(); node != nullptr; node = node->next)
                {
                    Actor* actor = node->data;
                    if (actor != nullptr && captured.insert(actor).second)
                        writeActor(actor);
                }
            }
        }
        gOutput.flush();
        if (gExitAfterFurnitureRelease && gFurnitureLifecycleComplete)
        {
            gOutput << "{\"schema\":" << sSchemaJson
                    << ",\"event\":\"furniture-lifecycle-complete\""
                    << ",\"frame\":" << gFrame
                    << ",\"releaseStableSamples\":" << gFurnitureReleaseStableSamples << "}\n";
            finishCapture();
            return;
        }
        if (gExitAfterFurnitureSettledSamples > 0
            && gFurnitureSettledStableSamples >= gExitAfterFurnitureSettledSamples)
        {
            gOutput << "{\"schema\":" << sSchemaJson
                    << ",\"event\":\"furniture-settled-complete\""
                    << ",\"frame\":" << gFrame
                    << ",\"settledStableSamples\":" << gFurnitureSettledStableSamples << "}\n";
            finishCapture();
            return;
        }
        if (gFrame >= gMaxFrames)
            finishCapture();
    }

    void messageHandler(NVSEMessagingInterface::Message* message)
    {
        if (message == nullptr)
            return;
        if (message->type == NVSEMessagingInterface::kMessage_MainGameLoop)
        {
            ++gGameLoopFrame;
            openOutput();
            if (hookImageSpaceDrawPrimitive() && !gImageSpaceShaderHookLogged)
            {
                gImageSpaceShaderHookLogged = true;
                gOutput << "{\"schema\":" << sSchemaJson
                        << ",\"event\":\"image-space-shader-hook\",\"installed\":true}\n";
                gOutput.flush();
            }
            writeImageSpaceShaderCapture();
            if (!gSaveName.empty() && !gLoadRequested && gGameLoopFrame >= 30)
                requestLoad();
            if (gWorldReady)
            {
                ++gWorldLoopFrame;
                if (gCloseMenusDuringCapture && gConsole != nullptr && gWorldLoopFrame % 15 == 1)
                {
                    const bool accepted = gConsole->RunScriptLine2("CloseAllMenus", nullptr, true);
                    if (!gCloseMenusLogged)
                    {
                        gCloseMenusLogged = true;
                        gOutput << "{\"schema\":" << sSchemaJson
                                << ",\"event\":\"background-game-mode\""
                                << ",\"frame\":" << gFrame
                                << ",\"closeAllMenusAccepted\":" << (accepted ? "true" : "false") << "}\n";
                        gOutput.flush();
                    }
                }
                driveObserverApproach();
                driveBatchWeaponState();
                drivePortraitCamera();
                const bool passiveBatchCapture = gSidecarPlanActive || !gBatchTargetForms.empty();
                if (gCaptureAnimation && !passiveBatchCapture && !gPrepareRequested
                    && gWorldLoopFrame >= gPrepareActorFrame)
                    prepareActor();
                if (gCaptureAnimation && !passiveBatchCapture && !gEquipRequested
                    && gWorldLoopFrame >= gEquipActorFrame)
                    equipActor();
                if (gCaptureAnimation && !passiveBatchCapture
                    && (!gPlayGroup.empty() || !gDriveCommand.empty()) && !gDriveRequested
                    && gWorldLoopFrame >= gDriveActorFrame)
                    driveActor();
                if (gCaptureAnimation && !passiveBatchCapture && !gFootIkToggleRequested && gFootIkToggleFrame > 0
                    && gWorldLoopFrame >= gFootIkToggleFrame)
                    toggleActorFootIk();
            }
            captureFrame();
        }
        else if (message->type == NVSEMessagingInterface::kMessage_PostLoadGame)
        {
            const bool succeeded = message->data != nullptr;
            gWorldReady = succeeded;
            gWorldLoopFrame = 0;
            gFrame = 0;
            openOutput();
            gOutput << "{\"schema\":" << jsonString(sSchema) << ",\"event\":\"load-result\","
                       "\"succeeded\":" << (succeeded ? "true" : "false") << "}\n";
            gOutput.flush();
            if (!succeeded && gExitWhenDone && gConsole != nullptr)
                gConsole->RunScriptLine2("QuitGame", nullptr, true);
        }
        else if (message->type == NVSEMessagingInterface::kMessage_ExitGame
            || message->type == NVSEMessagingInterface::kMessage_ExitToMainMenu)
        {
            if (gOutput)
            {
                gOutput << "{\"schema\":" << jsonString(sSchema) << ",\"event\":\"stop\","
                           "\"frames\":" << gFrame << "}\n";
                gOutput.flush();
                gOutput.close();
            }
            closeSidecarSharedMemory();
        }
    }
}

extern "C" __declspec(dllexport) bool NVSEPlugin_Query(const NVSEInterface* nvse, PluginInfo* info)
{
    info->infoVersion = PluginInfo::kInfoVersion;
    info->name = "NikamiRetailOracle";
    info->version = 4;
    return nvse != nullptr && !nvse->isEditor && !nvse->isNogore
        && nvse->runtimeVersion >= RUNTIME_VERSION_1_4_0_525;
}

extern "C" __declspec(dllexport) bool NVSEPlugin_Load(NVSEInterface* nvse)
{
    if (nvse == nullptr)
        return false;
    gPluginHandle = nvse->GetPluginHandle();
    gMessaging = static_cast<NVSEMessagingInterface*>(nvse->QueryInterface(kInterface_Messaging));
    gConsole = static_cast<NVSEConsoleInterface*>(nvse->QueryInterface(kInterface_Console));
    if (gMessaging == nullptr || gConsole == nullptr)
        return false;

    gSampleEvery = (std::max)(1u, envUInt("NIKAMI_ORACLE_SAMPLE_EVERY", 1));
    gMaxFrames = (std::max)(1u, envUInt("NIKAMI_ORACLE_MAX_FRAMES", 3600));
    gTargetForm = envUInt("NIKAMI_ORACLE_TARGET_FORM", 0);
    gEquipForm = envUInt("NIKAMI_ORACLE_EQUIP_FORM", 0);
    gObserverApproachForm = envUInt("NIKAMI_ORACLE_OBSERVER_APPROACH_FORM", 0);
    gObserverWaypoints = envObserverWaypoints("NIKAMI_ORACLE_OBSERVER_WAYPOINTS");
    gObserverApproachStopDistance
        = (std::max)(64.f, envFloat("NIKAMI_ORACLE_OBSERVER_APPROACH_STOP_DISTANCE", 1400.f));
    gObserverApproachStepDistance
        = (std::max)(1.f, envFloat("NIKAMI_ORACLE_OBSERVER_APPROACH_STEP_DISTANCE", 64.f));
    gAllHighActors = envUInt("NIKAMI_ORACLE_ALL_HIGH_ACTORS", 1) != 0;
    gCaptureAnimation = envUInt("NIKAMI_ORACLE_CAPTURE_ANIMATION", 1) != 0;
    gFurnitureOnly = envUInt("NIKAMI_ORACLE_FURNITURE_ONLY", 0) != 0;
    gExitAfterFurnitureRelease = envUInt("NIKAMI_ORACLE_EXIT_AFTER_FURNITURE_RELEASE", 0) != 0;
    gExitAfterFurnitureSettledSamples
        = envUInt("NIKAMI_ORACLE_EXIT_AFTER_FURNITURE_SETTLED_SAMPLES", 0);
    gFurnitureReleaseSamples = (std::max)(1u, envUInt("NIKAMI_ORACLE_FURNITURE_RELEASE_SAMPLES", 3));
    gCloseMenusDuringCapture = envUInt("NIKAMI_ORACLE_CLOSE_MENUS", 0) != 0;
    gPortraitCamera = envUInt("NIKAMI_ORACLE_PORTRAIT_CAMERA", 0) != 0;
    gPortraitDistance = (std::max)(32.f, envFloat("NIKAMI_ORACLE_PORTRAIT_DISTANCE", 110.f));
    gCameraShotKind = envString("NIKAMI_ORACLE_CAMERA_SHOT_KIND");
    if (gCameraShotKind.empty())
        gCameraShotKind = "front-portrait";
    if (gCameraShotKind != "front-portrait" && gCameraShotKind != "front-full-body")
        return false;
    gFullBodyCamera = gCameraShotKind == "front-full-body";
    gFullBodyDistanceScale
        = (std::max)(1.25f, envFloat("NIKAMI_ORACLE_FULL_BODY_DISTANCE_SCALE", 1.6f));
    gBatchForceWeaponOut = envUInt("NIKAMI_ORACLE_BATCH_FORCE_WEAPON_OUT", 0) != 0;
    gBatchWeaponProbeFrames
        = (std::max)(1u, envUInt("NIKAMI_ORACLE_BATCH_WEAPON_PROBE_FRAMES", 12));
    gSaveName = envString("NIKAMI_ORACLE_SAVE");
    gPlayGroup = envString("NIKAMI_ORACLE_PLAY_GROUP");
    gDriveCommand = envString("NIKAMI_ORACLE_DRIVE_COMMAND");
    gQuestForms = envUIntList("NIKAMI_ORACLE_QUEST_FORMS");
    gGlobalForms = envUIntList("NIKAMI_ORACLE_GLOBAL_FORMS");
    gGameSettingEditorIds = envEditorIdList("NIKAMI_ORACLE_GAME_SETTINGS");
    if (!gGameSettingEditorIds.empty() && nvse->runtimeVersion != RUNTIME_VERSION_1_4_0_525)
        return false;
    gBehaviorCommands = envCommandList("NIKAMI_ORACLE_COMMANDS");
    gActorCommands = envCommandList("NIKAMI_ORACLE_ACTOR_COMMANDS");
    gFurnitureSettledCommands = envCommandList("NIKAMI_ORACLE_FURNITURE_SETTLED_COMMANDS");
    gScreenshotFrames = envUIntList("NIKAMI_ORACLE_SCREENSHOT_FRAMES");
    std::sort(gScreenshotFrames.begin(), gScreenshotFrames.end());
    gScreenshotFrames.erase(
        std::unique(gScreenshotFrames.begin(), gScreenshotFrames.end()), gScreenshotFrames.end());
    gBatchTargetForms = envUIntList("NIKAMI_ORACLE_BATCH_TARGET_FORMS");
    gBatchTargetForms.erase(
        std::remove(gBatchTargetForms.begin(), gBatchTargetForms.end(), 0), gBatchTargetForms.end());
    gBatchSettleFrames = (std::max)(1u, envUInt("NIKAMI_ORACLE_BATCH_SETTLE_FRAMES", 20));
    gBatchAdvanceFrames = (std::max)(1u, envUInt("NIKAMI_ORACLE_BATCH_ADVANCE_FRAMES", 3));
    gBatchMoveToTargets = envUInt("NIKAMI_ORACLE_BATCH_MOVE_TO_TARGETS", 0) != 0;
    gBatchEnableTargets = envUInt("NIKAMI_ORACLE_BATCH_ENABLE_TARGETS", 0) != 0;
    gBatchEnableParentForms = envUIntList("NIKAMI_ORACLE_BATCH_ENABLE_PARENT_FORMS");
    gBatchProofStaging = envUInt("NIKAMI_ORACLE_BATCH_PROOF_STAGING", 0) != 0;
    gBatchProofAnchorForm = envUInt("NIKAMI_ORACLE_BATCH_PROOF_ANCHOR_FORM", 0);
    gBatchProofTargetX = envFloat("NIKAMI_ORACLE_BATCH_PROOF_TARGET_X", 0.f);
    gBatchProofTargetY = envFloat("NIKAMI_ORACLE_BATCH_PROOF_TARGET_Y", 0.f);
    gBatchProofTargetZ = envFloat("NIKAMI_ORACLE_BATCH_PROOF_TARGET_Z", 0.f);
    gBatchProofTargetYaw = envFloat("NIKAMI_ORACLE_BATCH_PROOF_TARGET_YAW", 0.f);
    gBatchProofPlayerX = envFloat("NIKAMI_ORACLE_BATCH_PROOF_PLAYER_X", 0.f);
    gBatchProofPlayerY = envFloat("NIKAMI_ORACLE_BATCH_PROOF_PLAYER_Y", 0.f);
    gBatchProofPlayerZ = envFloat("NIKAMI_ORACLE_BATCH_PROOF_PLAYER_Z", 0.f);
    gBatchProofMinimumCameraHeight = envFloat(
        "NIKAMI_ORACLE_BATCH_PROOF_MINIMUM_CAMERA_HEIGHT", 48.f);
    gBatchProofMinimumAimHeight = envFloat(
        "NIKAMI_ORACLE_BATCH_PROOF_MINIMUM_AIM_HEIGHT", 16.f);
    gBatchProofInitializationFrames = (std::max)(
        1u, envUInt("NIKAMI_ORACLE_BATCH_PROOF_INITIALIZATION_FRAMES", 30));
    gBatchProofTargetSettleFrames = (std::max)(
        1u, envUInt("NIKAMI_ORACLE_BATCH_PROOF_TARGET_SETTLE_FRAMES", 15));
    if (gBatchProofStaging
        && (gBatchTargetForms.empty() || gBatchProofAnchorForm == 0 || !gBatchEnableTargets
            || !gFullBodyCamera
            || !std::isfinite(gBatchProofTargetX) || !std::isfinite(gBatchProofTargetY)
            || !std::isfinite(gBatchProofTargetZ) || !std::isfinite(gBatchProofTargetYaw)
            || !std::isfinite(gBatchProofPlayerX) || !std::isfinite(gBatchProofPlayerY)
            || !std::isfinite(gBatchProofPlayerZ)
            || !std::isfinite(gBatchProofMinimumCameraHeight)
            || !std::isfinite(gBatchProofMinimumAimHeight)
            || gBatchProofMinimumCameraHeight < 0.f
            || gBatchProofMinimumAimHeight < 0.f
            || gBatchProofMinimumCameraHeight < gBatchProofMinimumAimHeight))
        return false;
    if (!gBatchTargetForms.empty())
    {
        gTargetForm = gBatchTargetForms.front();
        gPortraitCamera = true;
    }
    gBehaviorBeforeFrame = envUInt("NIKAMI_ORACLE_BEFORE_FRAME", 60);
    gBehaviorCommandFrame = envUInt("NIKAMI_ORACLE_COMMAND_FRAME", 90);
    gBehaviorAfterFrame = envUInt("NIKAMI_ORACLE_AFTER_FRAME", 150);
    gPrepareActorFrame = (std::max)(1u, envUInt("NIKAMI_ORACLE_PREPARE_ACTOR_FRAME", 60));
    gEquipActorFrame
        = (std::max)(gPrepareActorFrame, envUInt("NIKAMI_ORACLE_EQUIP_ACTOR_FRAME", gPrepareActorFrame));
    gDriveActorFrame = (std::max)(gEquipActorFrame, envUInt("NIKAMI_ORACLE_DRIVE_ACTOR_FRAME", 180));
    gFootIkToggleFrame = envUInt("NIKAMI_ORACLE_FOOT_IK_TOGGLE_FRAME", 0);
    gFootIkToggleEnabled = envUInt("NIKAMI_ORACLE_FOOT_IK_TOGGLE_ENABLED", 0) != 0;
    gSetStageQuestForm = envUInt("NIKAMI_ORACLE_SET_STAGE_QUEST", 0);
    gSetStageIndex = envUInt("NIKAMI_ORACLE_SET_STAGE_INDEX", 0xffff);
    gExitWhenDone = envUInt("NIKAMI_ORACLE_EXIT_WHEN_DONE", gSaveName.empty() ? 0 : 1) != 0;
    gWorldReady = gSaveName.empty();

    gSidecarPlanPath = envString("NIKAMI_ORACLE_PLAN_PATH");
    if (!gSidecarPlanPath.empty())
    {
        std::string planError;
        if (!loadSidecarPlan(gSidecarPlanPath, gSidecarPlan, planError))
            return false;
        gSidecarSharedMemoryName = envString("NIKAMI_ORACLE_SHARED_MEMORY_NAME");
        gSidecarBarrierTimeoutMs = (std::max)(1000u,
            envUInt("NIKAMI_ORACLE_BARRIER_TIMEOUT_MS", 30000));
        if (!initializeSidecarSharedMemory(planError))
            return false;

        gBatchTargetForms.clear();
        gBatchEnableParentForms.clear();
        gScreenshotFrames.clear();
        gTargetForm = 0;
        gEquipForm = 0;
        gAllHighActors = false;
        gCaptureAnimation = true;
        gPortraitCamera = true;
        gCameraShotKind = "front-full-body";
        gFullBodyCamera = true;
        gFullBodyDistanceScale = gSidecarPlan.fullBodyDistanceScale;
        gBatchProofStaging = true;
        gBatchProofAnchorForm = gSidecarPlan.anchorForm;
        gBatchProofTargetX = gSidecarPlan.targetX;
        gBatchProofTargetY = gSidecarPlan.targetY;
        gBatchProofTargetZ = gSidecarPlan.targetZ;
        gBatchProofTargetYaw = gSidecarPlan.targetYaw;
        gBatchProofPlayerX = gSidecarPlan.playerX;
        gBatchProofPlayerY = gSidecarPlan.playerY;
        gBatchProofPlayerZ = gSidecarPlan.playerZ;
        gBatchProofMinimumCameraHeight = gSidecarPlan.minimumCameraHeight;
        gBatchProofMinimumAimHeight = gSidecarPlan.minimumAimHeight;
        gBatchProofInitializationFrames = gSidecarPlan.initializationFrames;
        gBatchProofTargetSettleFrames = gSidecarPlan.targetSettleFrames;
        gBatchProofVolumeReady = false;
        gMaxFrames = (std::max)(gMaxFrames, 1000000000u);
        gSidecarActorIndex = 0;
        gSidecarActionIndex = 0;
        gSidecarPhase = SidecarPhase::LoadProofVolume;
        gSidecarPlanActive = true;

        std::ostringstream planPayload;
        planPayload << "{\"schema\":\"nikami-fnv-sidecar-retail/v1\""
                    << ",\"event\":\"plan-loaded\""
                    << ",\"sequenceId\":" << jsonString(gSidecarPlan.sequenceId.c_str())
                    << ",\"actors\":" << gSidecarPlan.actors.size()
                    << ",\"actions\":" << gSidecarPlan.actions.size() << '}';
        if (!publishSidecarRetailPlanPayload(planPayload.str(), planError))
        {
            setSidecarSharedError(NikamiFNVSidecar::ErrorCode::SharedMemoryFault,
                planError);
            return false;
        }
    }
    // The lockstep sidecar reads the actor state it needs at its explicit
    // barriers.  The legacy bone-LOD probes execute inside hot retail engine
    // paths and synchronously call back into the engine/CRT, so they must not
    // perturb a sidecar run before its first barrier.  Keep them available for
    // the dedicated legacy telemetry mode only.
    if (!gSidecarPlanActive)
    {
        gBoneLodWriterCallsHooked = hookBoneLodWriterCalls();
        gHighProcessBoneLodPathHooked = hookHighProcessBoneLodPath();
        if (!gBoneLodWriterCallsHooked || !gHighProcessBoneLodPathHooked)
            return false;
    }
    gMessaging->RegisterListener(gPluginHandle, "NVSE", messageHandler);
    return true;
}
