#include "nvse/PluginAPI.h"
#include "nvse/GameForms.h"
#include "nvse/GameObjects.h"
#include "nvse/NiObjects.h"

#include <Windows.h>
#include <d3d9.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <fstream>
#include <iomanip>
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
    std::vector<UInt32> gBatchEnableParentForms;
    bool gBatchEnableParentsRequested = false;
    bool gPortraitCamera = false;
    bool gPortraitCameraRequested = false;
    bool gPortraitCameraLogged = false;
    bool gAppearanceLogged = false;
    bool gRenderEnvironmentLogged = false;
    bool gImageSpaceShaderHookLogged = false;
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
    constexpr std::size_t sNiAVObjectLocalTransformOffset = 0x34;
    constexpr std::size_t sNiAVObjectWorldTransformOffset = 0x68;

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
            mov eax, dword ptr [ebp + 8]
            push eax
            mov eax, dword ptr [ebp - 4]
            push eax
            call recordBoneLodWriterCall
            add esp, 8
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
                    << "\"niAvObjectTransformLayout\":\"local@0x34/world@0x68/NiTransform@0x34\"}\n";
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

    void drivePortraitCamera()
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
                    << ",\"tfcAccepted\":" << (tfcAccepted ? "true" : "false")
                    << ",\"toggleMenusAccepted\":" << (menusAccepted ? "true" : "false") << "}\n";
            gOutput.flush();
            return;
        }

        __try
        {
            NiNode* root = actor->GetNiNode();
            NiAVObject* head = findNodeRecursive(root, "Bip01 Head");
            if (head == nullptr)
                return;
            const NiTransform headTransform = runtimeTransform(*head, sNiAVObjectWorldTransformOffset);
            const NiVector3 headWorld = headTransform.translate;
            const float headDx = headWorld.x - actor->posX;
            const float headDy = headWorld.y - actor->posY;
            const float headDz = headWorld.z - actor->posZ;
            if (headDx * headDx + headDy * headDy + headDz * headDz < 400.f)
                return;
            const float aimX = headWorld.x;
            const float aimY = headWorld.y;
            const float aimZ = headWorld.z + 20.f;
            // Bethesda bipeds use local X along the neck/head bone and local Y as the
            // face-forward axis.  Follow the rendered head rather than the actor root:
            // seated idles can turn the head far enough to turn an actor-root camera
            // into an accidental profile shot.
            float forwardX = headTransform.rotate.data[1];
            float forwardY = headTransform.rotate.data[4];
            const float forwardLength = std::sqrt(forwardX * forwardX + forwardY * forwardY);
            if (forwardLength < 0.25f)
                return;
            forwardX /= forwardLength;
            forwardY /= forwardLength;
            const float cameraX = aimX + forwardX * gPortraitDistance;
            const float cameraY = aimY + forwardY * gPortraitDistance;
            const float cameraZ = aimZ;
            const float cameraYaw = std::atan2(aimX - cameraX, aimY - cameraY);
            const float cameraPitch = 0.f;
            *reinterpret_cast<float*>(reinterpret_cast<UInt8*>(player) + 0x7E0) = cameraYaw;
            *reinterpret_cast<float*>(reinterpret_cast<UInt8*>(player) + 0x7E4) = cameraPitch;
            *reinterpret_cast<float*>(reinterpret_cast<UInt8*>(player) + 0x7E8) = cameraX;
            *reinterpret_cast<float*>(reinterpret_cast<UInt8*>(player) + 0x7EC) = cameraY;
            *reinterpret_cast<float*>(reinterpret_cast<UInt8*>(player) + 0x7F0) = cameraZ;
            if (!gPortraitCameraLogged)
            {
                gPortraitCameraLogged = true;
                gOutput << std::setprecision(9)
                        << "{\"schema\":" << sSchemaJson
                        << ",\"event\":\"portrait-camera-set\""
                        << ",\"frame\":" << gFrame
                        << ",\"refForm\":" << actor->refID
                        << ",\"headWorld\":[" << headWorld.x << ',' << headWorld.y << ',' << headWorld.z << ']'
                        << ",\"headForwardXY\":[" << forwardX << ',' << forwardY << ']'
                        << ",\"aim\":[" << aimX << ',' << aimY << ',' << aimZ << ']'
                        << ",\"camera\":[" << cameraX << ',' << cameraY << ',' << cameraZ << ']'
                        << ",\"rotation\":[" << cameraPitch << ',' << cameraYaw << "]}\n";
                gOutput.flush();
            }
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
        gOutput << "{\"schema\":" << jsonString(sSchema) << ",\"event\":\"capture-complete\","
                   "\"frames\":" << gFrame << "}\n";
        gOutput.flush();
        if (gExitWhenDone && gConsole != nullptr)
            gConsole->RunScriptLine2("QuitGame", nullptr, true);
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
        gBatchTargetLoadRequested = true;
        TESForm* targetForm = lookupForm(gTargetForm);
        TESObjectREFR* target = targetForm != nullptr && targetForm->GetIsReference()
            ? static_cast<TESObjectREFR*>(targetForm)
            : nullptr;
        bool enableAccepted = !gBatchEnableTargets;
        if (gBatchEnableTargets && target != nullptr)
            enableAccepted = gConsole->RunScriptLine2("Enable", target, true);
        bool moveAccepted = !gBatchMoveToTargets;
        if (gBatchMoveToTargets)
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
                << ",\"moveRequested\":" << (gBatchMoveToTargets ? "true" : "false")
                << ",\"moveAccepted\":" << (moveAccepted ? "true" : "false") << "}\n";
        gOutput.flush();
    }

    void captureAppearanceBatch()
    {
        if (gBatchTargetForms.empty() || gFinishRequested)
            return;
        if (!gPortraitCameraLogged || !gAppearanceLogged)
            return;
        if (gBatchTargetReadyFrame == 0)
        {
            gBatchTargetReadyFrame = gFrame;
            gOutput << "{\"schema\":" << sSchemaJson << ",\"event\":\"batch-target-ready\""
                    << ",\"frame\":" << gFrame
                    << ",\"targetIndex\":" << gBatchTargetIndex
                    << ",\"targetForm\":" << gTargetForm << "}\n";
            gOutput.flush();
        }
        const UInt32 screenshotFrame = gBatchTargetReadyFrame + gBatchSettleFrames;
        if (!gBatchScreenshotRequested && gFrame >= screenshotFrame)
        {
            gBatchScreenshotRequested = true;
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
        gBatchTargetReadyFrame = 0;
        gBatchScreenshotRequested = false;
        gBatchTargetLoadRequested = false;
    }

    void captureFrame()
    {
        openOutput();
        if (!gOutput || !gWorldReady || gFrame >= gMaxFrames)
            return;
        ++gFrame;
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
                drivePortraitCamera();
                if (gCaptureAnimation && !gPrepareRequested && gWorldLoopFrame >= gPrepareActorFrame)
                    prepareActor();
                if (gCaptureAnimation && !gEquipRequested && gWorldLoopFrame >= gEquipActorFrame)
                    equipActor();
                if (gCaptureAnimation && (!gPlayGroup.empty() || !gDriveCommand.empty()) && !gDriveRequested
                    && gWorldLoopFrame >= gDriveActorFrame)
                    driveActor();
                if (gCaptureAnimation && !gFootIkToggleRequested && gFootIkToggleFrame > 0
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
    gSaveName = envString("NIKAMI_ORACLE_SAVE");
    gPlayGroup = envString("NIKAMI_ORACLE_PLAY_GROUP");
    gDriveCommand = envString("NIKAMI_ORACLE_DRIVE_COMMAND");
    gQuestForms = envUIntList("NIKAMI_ORACLE_QUEST_FORMS");
    gGlobalForms = envUIntList("NIKAMI_ORACLE_GLOBAL_FORMS");
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
    gBoneLodWriterCallsHooked = hookBoneLodWriterCalls();
    gHighProcessBoneLodPathHooked = hookHighProcessBoneLodPath();
    if (!gBoneLodWriterCallsHooked || !gHighProcessBoneLodPathHooked)
        return false;
    gMessaging->RegisterListener(gPluginHandle, "NVSE", messageHandler);
    return true;
}
