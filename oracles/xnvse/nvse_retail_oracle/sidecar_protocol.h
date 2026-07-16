#pragma once

#include <cstddef>
#include <cstdint>

namespace NikamiFNVSidecar
{
    constexpr std::uint32_t Magic = 0x43534B4Eu; // "NKSC" in little-endian memory.
    constexpr std::uint16_t Version = 1;
    constexpr std::size_t SharedBlockBytes = 65536;
    constexpr std::size_t SharedHeaderBytes = 512;
    constexpr std::size_t PayloadBytes = (SharedBlockBytes - SharedHeaderBytes) / 2;

    enum class State : std::uint32_t
    {
        Empty = 0,
        PlanLoaded = 1,
        RetailPreparing = 2,
        RetailReady = 3,
        BothReady = 4,
        CaptureIssued = 5,
        WaitingCaptureAck = 6,
        Advancing = 7,
        Complete = 8,
        Error = 0xFFFFFFFFu,
    };

    enum Flag : std::uint32_t
    {
        RetailReadyFlag = 1u << 0,
        OpenMwReadyFlag = 1u << 1,
        RetailCapturedFlag = 1u << 2,
        OpenMwCapturedFlag = 1u << 3,
        CaptureAckFlag = 1u << 4,
        RetailCompleteFlag = 1u << 5,
        OpenMwCompleteFlag = 1u << 6,
        ErrorFlag = 1u << 31,
    };

    enum class ErrorCode : std::uint32_t
    {
        None = 0,
        InvalidPlan = 1,
        ActorUnavailable = 2,
        ActorSpawnFailed = 3,
        WeaponPolicyFailed = 4,
        ActionRejected = 5,
        RetailReadyTimeout = 6,
        OpenMwReadyTimeout = 7,
        ScreenshotTimeout = 8,
        CaptureAckTimeout = 9,
        SharedMemoryFault = 10,
        InternalFault = 11,
    };

#pragma pack(push, 8)
    struct alignas(8) SharedHeader
    {
        std::uint32_t magic;
        std::uint16_t version;
        std::uint16_t headerBytes;
        std::uint32_t totalBytes;
        volatile std::int32_t mutex;
        volatile std::uint32_t state;
        volatile std::uint32_t flags;
        volatile std::uint32_t errorCode;
        volatile std::uint32_t actorIndex;
        volatile std::uint32_t actionIndex;
        volatile std::uint32_t actionCount;
        std::uint32_t reserved0;
        std::uint32_t reserved1;
        volatile std::uint64_t generation;
        volatile std::uint64_t retailFrame;
        volatile std::uint64_t openmwFrame;
        volatile std::uint64_t captureOrdinal;
        volatile std::uint64_t deadlineTickMs;
        volatile std::uint32_t retailPayloadLength;
        volatile std::uint32_t retailPayloadCrc32;
        volatile std::uint32_t openmwPayloadLength;
        volatile std::uint32_t openmwPayloadCrc32;
        char sequenceId[128];
        char errorMessage[256];
        std::uint8_t reserved[24];
    };

    struct alignas(8) SharedBlock
    {
        SharedHeader header;
        char retailPayload[PayloadBytes];
        char openmwPayload[PayloadBytes];
    };
#pragma pack(pop)

    static_assert(sizeof(SharedHeader) == SharedHeaderBytes);
    static_assert(offsetof(SharedHeader, magic) == 0);
    static_assert(offsetof(SharedHeader, version) == 4);
    static_assert(offsetof(SharedHeader, headerBytes) == 6);
    static_assert(offsetof(SharedHeader, totalBytes) == 8);
    static_assert(offsetof(SharedHeader, mutex) == 12);
    static_assert(offsetof(SharedHeader, state) == 16);
    static_assert(offsetof(SharedHeader, flags) == 20);
    static_assert(offsetof(SharedHeader, errorCode) == 24);
    static_assert(offsetof(SharedHeader, actorIndex) == 28);
    static_assert(offsetof(SharedHeader, actionIndex) == 32);
    static_assert(offsetof(SharedHeader, actionCount) == 36);
    static_assert(offsetof(SharedHeader, reserved0) == 40);
    static_assert(offsetof(SharedHeader, reserved1) == 44);
    static_assert(offsetof(SharedHeader, generation) == 48);
    static_assert(offsetof(SharedHeader, retailFrame) == 56);
    static_assert(offsetof(SharedHeader, openmwFrame) == 64);
    static_assert(offsetof(SharedHeader, captureOrdinal) == 72);
    static_assert(offsetof(SharedHeader, deadlineTickMs) == 80);
    static_assert(offsetof(SharedHeader, retailPayloadLength) == 88);
    static_assert(offsetof(SharedHeader, retailPayloadCrc32) == 92);
    static_assert(offsetof(SharedHeader, openmwPayloadLength) == 96);
    static_assert(offsetof(SharedHeader, openmwPayloadCrc32) == 100);
    static_assert(offsetof(SharedHeader, sequenceId) == 104);
    static_assert(offsetof(SharedHeader, errorMessage) == 232);
    static_assert(offsetof(SharedHeader, reserved) == 488);
    static_assert(offsetof(SharedBlock, retailPayload) == SharedHeaderBytes);
    static_assert(offsetof(SharedBlock, openmwPayload) == SharedHeaderBytes + PayloadBytes);
    static_assert(sizeof(SharedBlock) == SharedBlockBytes);
}
