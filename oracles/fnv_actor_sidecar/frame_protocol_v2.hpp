#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <type_traits>

#if defined(_MSC_VER)
#include <intrin.h>
#endif

// Binary, allocation-free wire contract for the secondary
// "<NKSC mapping>.frames" mapping.  The structures intentionally contain no
// pointers, STL containers, bools, compiler enums, or process-local handles.
// Both endpoints must use the atomic helpers below for commit/cursor words.
namespace NikamiFNVSidecar::FramesV2
{
    inline constexpr char MappingNameSuffix[] = ".frames";

    inline constexpr std::uint32_t MappingMagic = 0x46534B4Eu; // "NKSF" in little-endian memory.
    inline constexpr std::uint32_t FrameMagic = 0x32464B4Eu;   // "NKF2" in little-endian memory.
    inline constexpr std::uint32_t EndianTag = 0x01020304u;
    inline constexpr std::uint16_t ProtocolVersion = 2;
    inline constexpr std::uint64_t LayoutTag = 0x0002'0008'0004'0000ull;

    inline constexpr std::size_t MappingHeaderBytes = 4096;
    inline constexpr std::size_t RingCount = 2;
    inline constexpr std::size_t SlotsPerRing = 8;
    inline constexpr std::size_t SlotBytes = 256 * 1024;
    inline constexpr std::size_t SlotMetadataBytes = 4096;
    inline constexpr std::size_t FramePrefixBytes = 256;
    inline constexpr std::size_t MaxSections = 64;
    inline constexpr std::size_t SectionDirectoryBytes = MaxSections * 32;
    inline constexpr std::size_t SlotPayloadBytes = SlotBytes - SlotMetadataBytes;
    inline constexpr std::size_t RingBytes = SlotsPerRing * SlotBytes;
    inline constexpr std::size_t MappingBytes = MappingHeaderBytes + RingCount * RingBytes;

    enum class Source : std::uint32_t
    {
        Retail = 0,
        OpenMw = 1,
    };

    enum MappingFlag : std::uint32_t
    {
        // protocolHash and planHash are immutable for the mapping lifetime.
        MappingIdentitySealed = 1u << 0,
    };

    enum class Status : std::uint32_t
    {
        Ok = 0,
        NotReady,
        InvalidArgument,
        InvalidMapping,
        InvalidSource,
        InvalidFrame,
        TooManySections,
        PayloadTooLarge,
        InvalidSection,
        RingFull,
        SequenceOverflow,
        PartialCommit,
        TornRead,
        Overwritten,
        StaleFrame,
        NonContiguous,
        IdentityMismatch,
        CrcMismatch,
    };

    enum class SectionType : std::uint32_t
    {
        Invalid = 0,
        SequenceStates = 1,
        ControlledBlocks = 2,
        NodeTransforms = 3,
        SkinningPalette = 4,
        DrawState = 5,
        Equipment = 6,
        PartAssembly = 7,
        Materials = 8,
        FaceChannels = 9,
        DialogueState = 10,
        StringTable = 11,
        CameraState = 12,
        EnvironmentState = 13,
        Diagnostics = 14,
    };

    inline constexpr std::uint32_t SectionTypeCount =
        static_cast<std::uint32_t>(SectionType::Diagnostics) + 1u;

    enum SectionFlag : std::uint16_t
    {
        SectionRequired = 1u << 0,
        SectionCanonicalOrder = 1u << 1,
        SectionContainsRetailKeys = 1u << 2,
        SectionContainsOpenMwKeys = 1u << 3,
    };

    enum FrameFlag : std::uint32_t
    {
        FrameCaptureRequested = 1u << 0,
        FrameCaptureComplete = 1u << 1,
        FrameFixedStep = 1u << 2,
        FrameDialogueActive = 1u << 3,
        FrameCombatActive = 1u << 4,
        FrameTerminalState = 1u << 5,
    };

    enum class SequencePhase : std::uint32_t
    {
        Inactive = 0,
        EaseIn = 1,
        Active = 2,
        EaseOut = 3,
        Completed = 4,
    };

    enum class SequenceCycle : std::uint32_t
    {
        Clamp = 0,
        Loop = 1,
        Reverse = 2,
    };

    enum class ControlledBlockKind : std::uint32_t
    {
        Unknown = 0,
        Transform = 1,
        Float = 2,
        Bool = 3,
        Color = 4,
        Visibility = 5,
        Morph = 6,
        Texture = 7,
    };

    enum TransformFlag : std::uint32_t
    {
        TransformHasLocal = 1u << 0,
        TransformHasWorld = 1u << 1,
        TransformIsRoot = 1u << 2,
        TransformIsBone = 1u << 3,
        TransformIsAttachment = 1u << 4,
        TransformHidden = 1u << 5,
    };

    enum class RawMatrixLayout : std::uint32_t
    {
        Invalid = 0,
        NetImmerseFloat32V1 = 1,
        OsgFloat32V1 = 2,
        RowMajorColumnVectorFloat32V1 = 3,
        ColumnMajorColumnVectorFloat32V1 = 4,
    };

    enum class CanonicalMatrixVersion : std::uint32_t
    {
        Invalid = 0,
        // Sixteen IEEE-754 floats in row-major memory order. Translation is
        // in elements [3], [7], [11]; transforms evaluate as M * columnVector.
        RowMajorColumnVectorFloat32V1 = 1,
    };

    enum class WeaponDrawState : std::uint32_t
    {
        Sheathed = 0,
        Drawing = 1,
        Drawn = 2,
        Sheathing = 3,
    };

    enum class Stance : std::uint32_t
    {
        Standing = 0,
        Crouched = 1,
        Sitting = 2,
        Prone = 3,
        Ragdoll = 4,
        Dead = 5,
    };

    enum class Hand : std::uint32_t
    {
        None = 0,
        Right = 1,
        Left = 2,
        Both = 3,
    };

    enum EquipmentFlag : std::uint32_t
    {
        EquipmentWorn = 1u << 0,
        EquipmentWornLeft = 1u << 1,
        EquipmentWeapon = 1u << 2,
        EquipmentArmor = 1u << 3,
        EquipmentClothing = 1u << 4,
        EquipmentHeadPart = 1u << 5,
        EquipmentRuntimeSpawned = 1u << 6,
    };

    enum class FaceChannelKind : std::uint32_t
    {
        Morph = 0,
        Phoneme = 1,
        Modifier = 2,
        Emotion = 3,
        Blink = 4,
        EyeLook = 5,
        Jaw = 6,
    };

    enum class DialoguePhase : std::uint32_t
    {
        Inactive = 0,
        Starting = 1,
        Speaking = 2,
        Paused = 3,
        Ending = 4,
        Complete = 5,
    };

    struct alignas(8) MappingIdentity
    {
        std::uint8_t protocolHash[32];
        std::uint8_t planHash[32];
    };

    struct alignas(8) FrameIdentity
    {
        std::uint64_t sequence;
        std::uint64_t previousSequence;
        std::uint64_t simulationTick;
        std::uint64_t captureOrdinal;
        std::uint32_t actorReferenceId;
        std::uint32_t actorBaseId;
        std::uint32_t actorOrdinal;
        std::uint32_t actionOrdinal;
        std::uint32_t fixedStepOrdinal;
        std::uint32_t identityFlags;
        std::uint64_t stateKeyHash;
        std::uint64_t engineFrame;
        std::uint32_t dtBits;
        std::uint32_t reserved;
        std::uint8_t skeletonManifestHash[32];
        std::uint8_t assemblyManifestHash[32];
    };

    struct alignas(8) SectionDescriptor
    {
        std::uint32_t type;
        std::uint16_t version;
        std::uint16_t flags;
        std::uint32_t offset;
        std::uint32_t byteLength;
        std::uint32_t recordCount;
        std::uint32_t recordStride;
        std::uint32_t crc32c;
        std::uint32_t reserved;
    };

    struct alignas(8) Transform3f
    {
        float translation[3];
        float rotationQuaternion[4];
        float scale[3];
        float reserved[2];
    };

    struct alignas(8) Matrix4f
    {
        float value[16];
    };

    struct alignas(8) SequenceStateRecord
    {
        std::uint64_t sequenceKey;
        std::uint64_t sequenceNameHash;
        std::uint64_t animationGroupHash;
        std::uint64_t sourceAssetHash;
        std::uint32_t sequenceOrdinal;
        std::uint32_t phase;
        std::uint32_t cycle;
        std::uint32_t flags;
        float localTime;
        float duration;
        float normalizedTime;
        float weight;
        float playbackRate;
        float easeValue;
        std::uint64_t controlledBlockSetHash;
    };

    struct alignas(8) ControlledBlockRecord
    {
        std::uint64_t sequenceKey;
        std::uint64_t blockKey;
        std::uint64_t targetNodeKey;
        std::uint64_t controllerTypeHash;
        std::uint64_t interpolatorTypeHash;
        std::uint32_t blockIndex;
        std::uint32_t kind;
        std::uint32_t priority;
        std::uint32_t flags;
        float blendWeight;
        float localTime;
        float targetTime;
        float reserved;
    };

    struct alignas(8) NodeTransformRecord
    {
        std::uint64_t nodeKey;
        std::uint64_t parentNodeKey;
        std::uint32_t nodeIndex;
        std::uint32_t parentNodeIndex;
        std::uint32_t flags;
        std::uint32_t recordVersion;
        std::uint32_t rawMatrixLayout;
        std::uint32_t canonicalMatrixVersion;
        std::uint32_t reserved[2];
        Matrix4f rawLocalMatrix;
        Matrix4f rawWorldMatrix;
        Matrix4f canonicalLocalMatrix;
        Matrix4f canonicalWorldMatrix;
        Transform3f decomposedCanonicalLocal;
        Transform3f decomposedCanonicalWorld;
    };

    struct alignas(8) SkinningPaletteRecord
    {
        std::uint64_t meshNodeKey;
        std::uint64_t boneNodeKey;
        std::uint32_t paletteIndex;
        std::uint32_t boneIndex;
        std::uint32_t flags;
        std::uint32_t reserved;
        Matrix4f bindPose;
        Matrix4f skinMatrix;
    };

    struct alignas(8) DrawStateRecord
    {
        std::uint32_t actorReferenceId;
        std::uint32_t actorBaseId;
        std::uint32_t weaponFormId;
        std::uint32_t ammoFormId;
        std::uint32_t drawState;
        std::uint32_t stance;
        std::uint32_t hand;
        std::uint32_t flags;
        std::uint64_t attackSequenceHash;
        float aimPitch;
        float aimYaw;
        float recoil;
        float blendWeight;
        std::uint32_t reserved[2];
    };

    struct alignas(8) EquipmentRecord
    {
        std::uint32_t itemFormId;
        std::uint32_t baseFormId;
        std::uint64_t instanceKey;
        std::uint64_t slotMask;
        std::uint64_t modelPathHash;
        std::uint64_t attachNodeHash;
        std::uint64_t materialSetHash;
        std::uint32_t count;
        float condition;
        std::uint32_t flags;
        std::uint32_t hand;
    };

    struct alignas(8) PartAssemblyRecord
    {
        std::uint64_t partKey;
        std::uint64_t nodeKey;
        std::uint64_t parentNodeKey;
        std::uint64_t modelPathHash;
        std::uint64_t materialSetHash;
        std::uint32_t partType;
        std::uint32_t equipmentSlot;
        std::uint32_t flags;
        float alpha;
        std::uint64_t reserved;
    };

    struct alignas(8) MaterialRecord
    {
        std::uint64_t nodeKey;
        std::uint64_t materialKey;
        std::uint64_t diffuseTextureHash;
        std::uint64_t normalTextureHash;
        std::uint64_t glowTextureHash;
        std::uint32_t shaderType;
        std::uint32_t flags;
        float alpha;
        float specularStrength;
        float emissiveScale;
        float reserved;
    };

    struct alignas(8) FaceChannelRecord
    {
        std::uint64_t channelKey;
        std::uint64_t sourceKey;
        std::uint32_t kind;
        std::uint32_t flags;
        float value;
        float targetValue;
    };

    struct alignas(8) DialogueStateRecord
    {
        std::uint32_t speakerReferenceId;
        std::uint32_t listenerReferenceId;
        std::uint32_t topicFormId;
        std::uint32_t infoFormId;
        std::uint32_t flags;
        std::uint32_t phase;
        std::uint64_t lineHash;
        std::uint64_t audioPathHash;
        std::uint64_t lipPathHash;
        std::uint64_t startSimulationTick;
        float localTime;
        float duration;
        float mouthOpen;
        float emotionValue;
        std::uint32_t emotionId;
        std::uint32_t phonemeId;
    };

    struct alignas(8) RingControl
    {
        std::uint32_t source;
        std::uint32_t flags;
        std::uint64_t generation;
        std::uint8_t reserved0[48];
        volatile std::uint64_t publishedSequence;
        std::uint8_t reserved1[56];
        volatile std::uint64_t consumedSequence;
        std::uint8_t reserved2[56];
        std::uint32_t faultCode;
        std::uint32_t faultDetail;
        std::uint64_t rejectedPublishCount;
        std::uint8_t reserved3[48];
    };

    struct alignas(8) MappingHeader
    {
        std::uint32_t magic;
        std::uint16_t version;
        std::uint16_t headerBytes;
        std::uint32_t totalBytes;
        std::uint32_t ringCount;
        std::uint32_t slotCount;
        std::uint32_t slotBytes;
        std::uint32_t slotMetadataBytes;
        std::uint32_t maxSections;
        std::uint32_t mappingFlags;
        std::uint32_t endianTag;
        std::uint64_t sessionIdLow;
        std::uint64_t sessionIdHigh;
        std::uint64_t layoutTag;
        MappingIdentity identity;
        std::uint8_t reservedPrefix[128];
        RingControl rings[RingCount];
        std::uint8_t reserved[3328];
    };

    struct alignas(8) FrameSlotPrefix
    {
        volatile std::uint64_t commitSequence;
        std::uint32_t frameMagic;
        std::uint16_t version;
        std::uint16_t headerBytes;
        std::uint32_t source;
        std::uint32_t frameFlags;
        std::uint64_t generation;
        FrameIdentity identity;
        std::uint32_t sectionCount;
        std::uint32_t directoryBytes;
        std::uint32_t payloadOffset;
        std::uint32_t payloadLength;
        std::uint32_t frameBytes;
        std::uint32_t contentCrc32c;
        std::uint32_t producerStatus;
        std::uint32_t producerDetail;
        std::uint64_t monotonicTimeNs;
        std::uint8_t reserved[40];
    };

    struct alignas(8) FrameSlot
    {
        FrameSlotPrefix prefix;
        SectionDescriptor sections[MaxSections];
        std::uint8_t reservedMetadata[SlotMetadataBytes - FramePrefixBytes - SectionDirectoryBytes];
        std::uint8_t payload[SlotPayloadBytes];
    };

    struct alignas(8) RingStorage
    {
        FrameSlot slots[SlotsPerRing];
    };

    struct alignas(8) FrameMapping
    {
        MappingHeader header;
        RingStorage rings[RingCount];
    };

    struct SectionInput
    {
        SectionType type = SectionType::Invalid;
        std::uint16_t version = 1;
        std::uint16_t flags = 0;
        std::uint32_t recordCount = 0;
        std::uint32_t recordStride = 0;
        const void* data = nullptr;
        std::uint32_t byteLength = 0;
    };

    struct PublishInput
    {
        FrameIdentity identity{};
        std::uint32_t frameFlags = 0;
        std::uint64_t monotonicTimeNs = 0;
        std::uint32_t producerStatus = 0;
        std::uint32_t producerDetail = 0;
        const SectionInput* sections = nullptr;
        std::uint32_t sectionCount = 0;
    };

    struct FrameView
    {
        const FrameSlot* slot = nullptr;
        const FrameIdentity* identity = nullptr;
        const SectionDescriptor* sections = nullptr;
        std::uint32_t sectionCount = 0;
        const std::uint8_t* payload = nullptr;
        std::uint32_t payloadLength = 0;

        [[nodiscard]] const SectionDescriptor* find(SectionType type) const noexcept
        {
            for (std::uint32_t index = 0; index < sectionCount; ++index)
            {
                if (sections[index].type == static_cast<std::uint32_t>(type))
                    return &sections[index];
            }
            return nullptr;
        }

        [[nodiscard]] const void* sectionData(const SectionDescriptor& section) const noexcept
        {
            if (slot == nullptr)
                return nullptr;
            return reinterpret_cast<const std::uint8_t*>(slot) + section.offset;
        }
    };

    struct ReadResult
    {
        Status status = Status::InvalidArgument;
        std::uint64_t expectedSequence = 0;
        std::uint64_t observedSequence = 0;
        FrameView frame{};
    };

    using ReadCopyHook = void (*)(void* context);

    static_assert(sizeof(float) == 4);
    static_assert(std::numeric_limits<float>::is_iec559);
    static_assert(sizeof(MappingIdentity) == 64);
    static_assert(std::is_standard_layout_v<MappingIdentity>);
    static_assert(std::is_trivially_copyable_v<MappingIdentity>);
    static_assert(std::is_standard_layout_v<FrameIdentity>);
    static_assert(std::is_trivially_copyable_v<FrameIdentity>);
    static_assert(sizeof(FrameIdentity) == 144);
    static_assert(offsetof(FrameIdentity, engineFrame) == 64);
    static_assert(offsetof(FrameIdentity, dtBits) == 72);
    static_assert(offsetof(FrameIdentity, skeletonManifestHash) == 80);
    static_assert(offsetof(FrameIdentity, assemblyManifestHash) == 112);
    static_assert(sizeof(SectionDescriptor) == 32);
    static_assert(sizeof(Transform3f) == 48);
    static_assert(sizeof(Matrix4f) == 64);
    static_assert(sizeof(SequenceStateRecord) == 80);
    static_assert(sizeof(ControlledBlockRecord) == 72);
    static_assert(sizeof(NodeTransformRecord) == 400);
    static_assert(offsetof(NodeTransformRecord, rawLocalMatrix) == 48);
    static_assert(offsetof(NodeTransformRecord, rawWorldMatrix) == 112);
    static_assert(offsetof(NodeTransformRecord, canonicalLocalMatrix) == 176);
    static_assert(offsetof(NodeTransformRecord, canonicalWorldMatrix) == 240);
    static_assert(offsetof(NodeTransformRecord, decomposedCanonicalLocal) == 304);
    static_assert(offsetof(NodeTransformRecord, decomposedCanonicalWorld) == 352);
    static_assert(sizeof(SkinningPaletteRecord) == 160);
    static_assert(sizeof(DrawStateRecord) == 64);
    static_assert(sizeof(EquipmentRecord) == 64);
    static_assert(sizeof(PartAssemblyRecord) == 64);
    static_assert(sizeof(MaterialRecord) == 64);
    static_assert(sizeof(FaceChannelRecord) == 32);
    static_assert(sizeof(DialogueStateRecord) == 80);
    static_assert(sizeof(RingControl) == 256);
    static_assert(offsetof(RingControl, publishedSequence) == 64);
    static_assert(offsetof(RingControl, consumedSequence) == 128);
    static_assert(offsetof(RingControl, faultCode) == 192);
    static_assert(sizeof(MappingHeader) == MappingHeaderBytes);
    static_assert(offsetof(MappingHeader, identity) == 64);
    static_assert(offsetof(MappingHeader, rings) == 256);
    static_assert(sizeof(FrameSlotPrefix) == FramePrefixBytes);
    static_assert(offsetof(FrameSlotPrefix, commitSequence) == 0);
    static_assert(offsetof(FrameSlotPrefix, generation) == 24);
    static_assert(offsetof(FrameSlotPrefix, identity) == 32);
    static_assert(offsetof(FrameSlotPrefix, sectionCount) == 176);
    static_assert(offsetof(FrameSlotPrefix, contentCrc32c) == 196);
    static_assert(offsetof(FrameSlotPrefix, monotonicTimeNs) == 208);
    static_assert(offsetof(FrameSlot, sections) == FramePrefixBytes);
    static_assert(offsetof(FrameSlot, payload) == SlotMetadataBytes);
    static_assert(sizeof(FrameSlot) == SlotBytes);
    static_assert(sizeof(RingStorage) == RingBytes);
    static_assert(offsetof(FrameMapping, rings) == MappingHeaderBytes);
    static_assert(sizeof(FrameMapping) == MappingBytes);
    static_assert((offsetof(RingControl, publishedSequence) % alignof(std::uint64_t)) == 0);
    static_assert((offsetof(RingControl, consumedSequence) % alignof(std::uint64_t)) == 0);
    static_assert((offsetof(FrameSlotPrefix, commitSequence) % alignof(std::uint64_t)) == 0);

    [[nodiscard]] inline constexpr bool IsValidSource(Source source) noexcept
    {
        return source == Source::Retail || source == Source::OpenMw;
    }

    [[nodiscard]] inline constexpr bool IsValidSectionType(SectionType type) noexcept
    {
        const std::uint32_t value = static_cast<std::uint32_t>(type);
        return value > static_cast<std::uint32_t>(SectionType::Invalid)
            && value < SectionTypeCount;
    }

    [[nodiscard]] inline bool HashIsNonzero(const std::uint8_t hash[32]) noexcept
    {
        std::uint8_t combined = 0;
        for (std::size_t index = 0; index < 32; ++index)
            combined = static_cast<std::uint8_t>(combined | hash[index]);
        return combined != 0;
    }

    [[nodiscard]] inline bool IdentityIsBound(const MappingIdentity& identity) noexcept
    {
        return HashIsNonzero(identity.protocolHash) && HashIsNonzero(identity.planHash);
    }

    [[nodiscard]] inline bool MappingIdentityMatches(
        const MappingIdentity& actual,
        const MappingIdentity& expected) noexcept
    {
        return std::memcmp(actual.protocolHash, expected.protocolHash, sizeof(actual.protocolHash)) == 0
            && std::memcmp(actual.planHash, expected.planHash, sizeof(actual.planHash)) == 0;
    }

    [[nodiscard]] inline constexpr std::size_t SourceIndex(Source source) noexcept
    {
        return static_cast<std::size_t>(source);
    }

    [[nodiscard]] inline constexpr std::size_t SlotIndex(std::uint64_t sequence) noexcept
    {
        return static_cast<std::size_t>((sequence - 1u) % SlotsPerRing);
    }

    [[nodiscard]] inline constexpr std::uint32_t Align8(std::uint32_t value) noexcept
    {
        return (value + 7u) & ~7u;
    }

    [[nodiscard]] inline bool HostIsLittleEndian() noexcept
    {
        const std::uint32_t value = EndianTag;
        return *reinterpret_cast<const std::uint8_t*>(&value) == 0x04u;
    }

    [[nodiscard]] inline std::uint64_t AtomicLoadAcquire(const volatile std::uint64_t* word) noexcept
    {
#if defined(_MSC_VER)
        auto* mutableWord = const_cast<volatile std::uint64_t*>(word);
        return static_cast<std::uint64_t>(_InterlockedCompareExchange64(
            reinterpret_cast<volatile __int64*>(mutableWord), 0, 0));
#elif defined(__clang__) || defined(__GNUC__)
        return __atomic_load_n(word, __ATOMIC_ACQUIRE);
#else
#error "FramesV2 needs an acquire/release implementation for this compiler"
#endif
    }

    inline void AtomicStoreRelease(volatile std::uint64_t* word, std::uint64_t value) noexcept
    {
#if defined(_MSC_VER)
#if defined(_M_IX86)
        auto* destination = reinterpret_cast<volatile __int64*>(word);
        __int64 observed = _InterlockedCompareExchange64(destination, 0, 0);
        const __int64 desired = static_cast<__int64>(value);
        while (_InterlockedCompareExchange64(destination, desired, observed) != observed)
            observed = _InterlockedCompareExchange64(destination, 0, 0);
#else
        _InterlockedExchange64(reinterpret_cast<volatile __int64*>(word), static_cast<__int64>(value));
#endif
#elif defined(__clang__) || defined(__GNUC__)
        __atomic_store_n(word, value, __ATOMIC_RELEASE);
#else
#error "FramesV2 needs an acquire/release implementation for this compiler"
#endif
    }

    [[nodiscard]] inline std::uint32_t Crc32c(const void* data, std::size_t length) noexcept
    {
        const auto* bytes = static_cast<const std::uint8_t*>(data);
        std::uint32_t crc = 0xFFFFFFFFu;
        for (std::size_t byteIndex = 0; byteIndex < length; ++byteIndex)
        {
            crc ^= bytes[byteIndex];
            for (unsigned bit = 0; bit < 8; ++bit)
            {
                const std::uint32_t mask = 0u - (crc & 1u);
                crc = (crc >> 1u) ^ (0x82F63B78u & mask);
            }
        }
        return ~crc;
    }

    [[nodiscard]] inline const char* StatusName(Status status) noexcept
    {
        switch (status)
        {
            case Status::Ok: return "ok";
            case Status::NotReady: return "not-ready";
            case Status::InvalidArgument: return "invalid-argument";
            case Status::InvalidMapping: return "invalid-mapping";
            case Status::InvalidSource: return "invalid-source";
            case Status::InvalidFrame: return "invalid-frame";
            case Status::TooManySections: return "too-many-sections";
            case Status::PayloadTooLarge: return "payload-too-large";
            case Status::InvalidSection: return "invalid-section";
            case Status::RingFull: return "ring-full";
            case Status::SequenceOverflow: return "sequence-overflow";
            case Status::PartialCommit: return "partial-commit";
            case Status::TornRead: return "torn-read";
            case Status::Overwritten: return "overwritten";
            case Status::StaleFrame: return "stale-frame";
            case Status::NonContiguous: return "noncontiguous";
            case Status::IdentityMismatch: return "identity-mismatch";
            case Status::CrcMismatch: return "crc-mismatch";
        }
        return "unknown";
    }

    [[nodiscard]] inline Status ValidateMapping(
        const FrameMapping* mapping,
        const MappingIdentity* expectedIdentity = nullptr) noexcept
    {
        if (mapping == nullptr || !HostIsLittleEndian())
            return Status::InvalidMapping;

        const MappingHeader& header = mapping->header;
        if (header.magic != MappingMagic || header.version != ProtocolVersion
            || header.headerBytes != MappingHeaderBytes || header.totalBytes != MappingBytes
            || header.ringCount != RingCount || header.slotCount != SlotsPerRing
            || header.slotBytes != SlotBytes || header.slotMetadataBytes != SlotMetadataBytes
            || header.maxSections != MaxSections || header.endianTag != EndianTag
            || header.layoutTag != LayoutTag || header.mappingFlags != MappingIdentitySealed
            || !IdentityIsBound(header.identity))
            return Status::InvalidMapping;

        if (expectedIdentity != nullptr
            && (!IdentityIsBound(*expectedIdentity)
                || !MappingIdentityMatches(header.identity, *expectedIdentity)))
            return Status::InvalidMapping;

        for (std::size_t index = 0; index < RingCount; ++index)
        {
            if (header.rings[index].source != index)
                return Status::InvalidMapping;
        }
        return Status::Ok;
    }

    [[nodiscard]] inline Status InitializeMapping(
        FrameMapping* mapping,
        std::uint64_t sessionIdLow,
        std::uint64_t sessionIdHigh,
        std::uint64_t generation,
        const MappingIdentity& mappingIdentity) noexcept
    {
        if (mapping == nullptr || generation == 0 || !HostIsLittleEndian()
            || !IdentityIsBound(mappingIdentity))
            return Status::InvalidArgument;

        std::memset(mapping, 0, sizeof(*mapping));
        MappingHeader& header = mapping->header;
        header.magic = MappingMagic;
        header.version = ProtocolVersion;
        header.headerBytes = static_cast<std::uint16_t>(MappingHeaderBytes);
        header.totalBytes = static_cast<std::uint32_t>(MappingBytes);
        header.ringCount = static_cast<std::uint32_t>(RingCount);
        header.slotCount = static_cast<std::uint32_t>(SlotsPerRing);
        header.slotBytes = static_cast<std::uint32_t>(SlotBytes);
        header.slotMetadataBytes = static_cast<std::uint32_t>(SlotMetadataBytes);
        header.maxSections = static_cast<std::uint32_t>(MaxSections);
        header.mappingFlags = MappingIdentitySealed;
        header.endianTag = EndianTag;
        header.sessionIdLow = sessionIdLow;
        header.sessionIdHigh = sessionIdHigh;
        header.layoutTag = LayoutTag;
        header.identity = mappingIdentity;
        for (std::size_t index = 0; index < RingCount; ++index)
        {
            header.rings[index].source = static_cast<std::uint32_t>(index);
            header.rings[index].generation = generation;
        }
        return Status::Ok;
    }

    [[nodiscard]] inline Status ValidateSectionInput(const SectionInput& input) noexcept
    {
        if (!IsValidSectionType(input.type) || input.data == nullptr || input.byteLength == 0)
            return Status::InvalidSection;
        if ((input.recordCount == 0) != (input.recordStride == 0))
            return Status::InvalidSection;
        if (input.recordCount != 0)
        {
            const std::uint64_t recordsBytes =
                static_cast<std::uint64_t>(input.recordCount) * input.recordStride;
            if (recordsBytes != input.byteLength)
                return Status::InvalidSection;
        }
        return Status::Ok;
    }

    [[nodiscard]] inline std::uint32_t ComputeFrameContentCrc(FrameSlot& slot) noexcept
    {
        const std::uint32_t saved = slot.prefix.contentCrc32c;
        slot.prefix.contentCrc32c = 0;
        const std::uint32_t crc = Crc32c(
            reinterpret_cast<const std::uint8_t*>(&slot) + sizeof(slot.prefix.commitSequence),
            slot.prefix.frameBytes - static_cast<std::uint32_t>(sizeof(slot.prefix.commitSequence)));
        slot.prefix.contentCrc32c = saved;
        return crc;
    }

    [[nodiscard]] inline Status Publish(
        FrameMapping* mapping,
        Source source,
        const PublishInput& input,
        std::uint64_t* publishedSequence = nullptr) noexcept
    {
        const Status mappingStatus = ValidateMapping(mapping);
        if (mappingStatus != Status::Ok)
            return mappingStatus;
        if (!IsValidSource(source))
            return Status::InvalidSource;
        if (input.sectionCount > MaxSections)
            return Status::TooManySections;
        if (input.sectionCount != 0 && input.sections == nullptr)
            return Status::InvalidArgument;

        std::uint32_t frameBytes = static_cast<std::uint32_t>(SlotMetadataBytes);
        bool seenSectionTypes[SectionTypeCount]{};
        for (std::uint32_t index = 0; index < input.sectionCount; ++index)
        {
            const Status sectionStatus = ValidateSectionInput(input.sections[index]);
            if (sectionStatus != Status::Ok)
                return sectionStatus;
            const std::uint32_t typeIndex = static_cast<std::uint32_t>(input.sections[index].type);
            if (seenSectionTypes[typeIndex])
                return Status::InvalidSection;
            seenSectionTypes[typeIndex] = true;
            if (frameBytes > std::numeric_limits<std::uint32_t>::max() - 7u)
                return Status::PayloadTooLarge;
            frameBytes = Align8(frameBytes);
            if (input.sections[index].byteLength > SlotBytes - frameBytes)
                return Status::PayloadTooLarge;
            frameBytes += input.sections[index].byteLength;
        }

        RingControl& control = mapping->header.rings[SourceIndex(source)];
        const std::uint64_t produced = AtomicLoadAcquire(&control.publishedSequence);
        const std::uint64_t consumed = AtomicLoadAcquire(&control.consumedSequence);
        if (produced < consumed)
            return Status::StaleFrame;
        if (produced == std::numeric_limits<std::uint64_t>::max())
            return Status::SequenceOverflow;
        if (produced - consumed >= SlotsPerRing)
        {
            ++control.rejectedPublishCount;
            return Status::RingFull;
        }

        const std::uint64_t sequence = produced + 1u;
        FrameSlot& slot = mapping->rings[SourceIndex(source)].slots[SlotIndex(sequence)];

        // Invalidate before touching any byte that belongs to this slot.  The
        // release store of the real sequence below is the slot's final write.
        AtomicStoreRelease(&slot.prefix.commitSequence, 0);
        std::memset(
            reinterpret_cast<std::uint8_t*>(&slot) + sizeof(slot.prefix.commitSequence),
            0,
            frameBytes - sizeof(slot.prefix.commitSequence));

        slot.prefix.frameMagic = FrameMagic;
        slot.prefix.version = ProtocolVersion;
        slot.prefix.headerBytes = static_cast<std::uint16_t>(FramePrefixBytes);
        slot.prefix.source = static_cast<std::uint32_t>(source);
        slot.prefix.frameFlags = input.frameFlags;
        slot.prefix.generation = control.generation;
        slot.prefix.identity = input.identity;
        slot.prefix.identity.sequence = sequence;
        slot.prefix.identity.previousSequence = produced;
        slot.prefix.sectionCount = input.sectionCount;
        slot.prefix.directoryBytes = input.sectionCount * static_cast<std::uint32_t>(sizeof(SectionDescriptor));
        slot.prefix.payloadOffset = static_cast<std::uint32_t>(SlotMetadataBytes);
        slot.prefix.payloadLength = frameBytes - static_cast<std::uint32_t>(SlotMetadataBytes);
        slot.prefix.frameBytes = frameBytes;
        slot.prefix.monotonicTimeNs = input.monotonicTimeNs;
        slot.prefix.producerStatus = input.producerStatus;
        slot.prefix.producerDetail = input.producerDetail;

        std::uint32_t writeOffset = static_cast<std::uint32_t>(SlotMetadataBytes);
        for (std::uint32_t index = 0; index < input.sectionCount; ++index)
        {
            const SectionInput& sourceSection = input.sections[index];
            writeOffset = Align8(writeOffset);
            std::memcpy(
                reinterpret_cast<std::uint8_t*>(&slot) + writeOffset,
                sourceSection.data,
                sourceSection.byteLength);

            SectionDescriptor& destination = slot.sections[index];
            destination.type = static_cast<std::uint32_t>(sourceSection.type);
            destination.version = sourceSection.version;
            destination.flags = sourceSection.flags;
            destination.offset = writeOffset;
            destination.byteLength = sourceSection.byteLength;
            destination.recordCount = sourceSection.recordCount;
            destination.recordStride = sourceSection.recordStride;
            destination.crc32c = Crc32c(sourceSection.data, sourceSection.byteLength);
            writeOffset += sourceSection.byteLength;
        }

        slot.prefix.contentCrc32c = 0;
        slot.prefix.contentCrc32c = ComputeFrameContentCrc(slot);
        AtomicStoreRelease(&slot.prefix.commitSequence, sequence);
        AtomicStoreRelease(&control.publishedSequence, sequence);
        if (publishedSequence != nullptr)
            *publishedSequence = sequence;
        return Status::Ok;
    }

    [[nodiscard]] inline Status ValidateCopiedFrame(
        const FrameMapping& mapping,
        Source source,
        std::uint64_t expectedSequence,
        FrameSlot& slot) noexcept
    {
        const FrameSlotPrefix& prefix = slot.prefix;
        const RingControl& control = mapping.header.rings[SourceIndex(source)];
        if (prefix.frameMagic != FrameMagic || prefix.version != ProtocolVersion
            || prefix.headerBytes != FramePrefixBytes
            || prefix.source != static_cast<std::uint32_t>(source))
            return Status::InvalidFrame;
        if (prefix.generation != control.generation)
            return Status::StaleFrame;
        if (prefix.identity.sequence != expectedSequence)
            return Status::IdentityMismatch;
        if (prefix.identity.previousSequence != expectedSequence - 1u)
            return Status::NonContiguous;
        if (prefix.sectionCount > MaxSections
            || prefix.directoryBytes != prefix.sectionCount * sizeof(SectionDescriptor)
            || prefix.payloadOffset != SlotMetadataBytes
            || prefix.payloadLength > SlotPayloadBytes
            || prefix.frameBytes != SlotMetadataBytes + prefix.payloadLength
            || prefix.frameBytes > SlotBytes)
            return Status::InvalidFrame;

        std::uint32_t previousEnd = static_cast<std::uint32_t>(SlotMetadataBytes);
        bool seenSectionTypes[SectionTypeCount]{};
        for (std::uint32_t index = 0; index < prefix.sectionCount; ++index)
        {
            const SectionDescriptor& section = slot.sections[index];
            if (section.type == static_cast<std::uint32_t>(SectionType::Invalid)
                || section.type >= SectionTypeCount || seenSectionTypes[section.type]
                || section.reserved != 0 || section.byteLength == 0
                || (section.offset & 7u) != 0 || section.offset < previousEnd
                || section.offset < SlotMetadataBytes || section.offset > prefix.frameBytes
                || section.byteLength > prefix.frameBytes - section.offset
                || ((section.recordCount == 0) != (section.recordStride == 0)))
                return Status::InvalidSection;
            seenSectionTypes[section.type] = true;
            if (section.recordCount != 0)
            {
                const std::uint64_t recordsBytes =
                    static_cast<std::uint64_t>(section.recordCount) * section.recordStride;
                if (recordsBytes != section.byteLength)
                    return Status::InvalidSection;
            }
            const void* sectionData = reinterpret_cast<const std::uint8_t*>(&slot) + section.offset;
            if (Crc32c(sectionData, section.byteLength) != section.crc32c)
                return Status::CrcMismatch;
            previousEnd = section.offset + section.byteLength;
        }

        const std::uint32_t expectedCrc = prefix.contentCrc32c;
        if (ComputeFrameContentCrc(slot) != expectedCrc)
            return Status::CrcMismatch;
        return Status::Ok;
    }

    [[nodiscard]] inline ReadResult ReadNextObserved(
        const FrameMapping* mapping,
        Source source,
        FrameSlot* snapshot,
        ReadCopyHook afterCopy,
        void* hookContext) noexcept
    {
        ReadResult result{};
        result.status = ValidateMapping(mapping);
        if (result.status != Status::Ok)
            return result;
        if (!IsValidSource(source))
        {
            result.status = Status::InvalidSource;
            return result;
        }
        if (snapshot == nullptr)
        {
            result.status = Status::InvalidArgument;
            return result;
        }

        const RingControl& control = mapping->header.rings[SourceIndex(source)];
        const std::uint64_t consumed = AtomicLoadAcquire(&control.consumedSequence);
        const std::uint64_t published = AtomicLoadAcquire(&control.publishedSequence);
        if (published < consumed)
        {
            result.status = Status::StaleFrame;
            return result;
        }
        if (published == consumed)
        {
            result.status = Status::NotReady;
            return result;
        }
        if (published - consumed > SlotsPerRing)
        {
            result.status = Status::Overwritten;
            return result;
        }
        if (consumed == std::numeric_limits<std::uint64_t>::max())
        {
            result.status = Status::SequenceOverflow;
            return result;
        }

        const std::uint64_t expected = consumed + 1u;
        result.expectedSequence = expected;
        const FrameSlot& liveSlot = mapping->rings[SourceIndex(source)].slots[SlotIndex(expected)];
        const std::uint64_t before = AtomicLoadAcquire(&liveSlot.prefix.commitSequence);
        result.observedSequence = before;
        if (before == 0)
        {
            result.status = Status::PartialCommit;
            return result;
        }
        if (before < expected)
        {
            result.status = Status::StaleFrame;
            return result;
        }
        if (before > expected)
        {
            result.status = ((before - expected) >= SlotsPerRing)
                ? Status::Overwritten
                : Status::NonContiguous;
            return result;
        }

        std::memcpy(snapshot, &liveSlot, SlotMetadataBytes);
        const std::uint64_t afterMetadata = AtomicLoadAcquire(&liveSlot.prefix.commitSequence);
        if (afterMetadata != before)
        {
            result.observedSequence = afterMetadata;
            result.status = Status::TornRead;
            return result;
        }
        if (snapshot->prefix.payloadLength > SlotPayloadBytes
            || snapshot->prefix.frameBytes != SlotMetadataBytes + snapshot->prefix.payloadLength
            || snapshot->prefix.frameBytes > SlotBytes)
        {
            result.status = Status::InvalidFrame;
            return result;
        }

        if (snapshot->prefix.payloadLength != 0)
        {
            std::memcpy(
                snapshot->payload,
                liveSlot.payload,
                snapshot->prefix.payloadLength);
        }
        if (afterCopy != nullptr)
            afterCopy(hookContext);

        const std::uint64_t after = AtomicLoadAcquire(&liveSlot.prefix.commitSequence);
        if (after != before)
        {
            result.observedSequence = after;
            result.status = Status::TornRead;
            return result;
        }
        snapshot->prefix.commitSequence = before;

        result.status = ValidateCopiedFrame(*mapping, source, expected, *snapshot);
        if (result.status != Status::Ok)
            return result;

        result.frame.slot = snapshot;
        result.frame.identity = &snapshot->prefix.identity;
        result.frame.sections = snapshot->sections;
        result.frame.sectionCount = snapshot->prefix.sectionCount;
        result.frame.payload = snapshot->payload;
        result.frame.payloadLength = snapshot->prefix.payloadLength;
        return result;
    }

    [[nodiscard]] inline ReadResult ReadNext(
        const FrameMapping* mapping,
        Source source,
        FrameSlot* snapshot) noexcept
    {
        return ReadNextObserved(mapping, source, snapshot, nullptr, nullptr);
    }

    [[nodiscard]] inline Status Acknowledge(
        FrameMapping* mapping,
        Source source,
        std::uint64_t sequence) noexcept
    {
        const Status mappingStatus = ValidateMapping(mapping);
        if (mappingStatus != Status::Ok)
            return mappingStatus;
        if (!IsValidSource(source))
            return Status::InvalidSource;

        RingControl& control = mapping->header.rings[SourceIndex(source)];
        const std::uint64_t consumed = AtomicLoadAcquire(&control.consumedSequence);
        const std::uint64_t published = AtomicLoadAcquire(&control.publishedSequence);
        if (consumed == std::numeric_limits<std::uint64_t>::max())
            return Status::SequenceOverflow;
        if (sequence != consumed + 1u)
            return sequence <= consumed ? Status::StaleFrame : Status::NonContiguous;
        if (sequence > published)
            return Status::NotReady;

        const FrameSlot& slot = mapping->rings[SourceIndex(source)].slots[SlotIndex(sequence)];
        const std::uint64_t committed = AtomicLoadAcquire(&slot.prefix.commitSequence);
        if (committed == 0)
            return Status::PartialCommit;
        if (committed < sequence)
            return Status::StaleFrame;
        if (committed > sequence)
            return Status::Overwritten;
        AtomicStoreRelease(&control.consumedSequence, sequence);
        return Status::Ok;
    }
}
