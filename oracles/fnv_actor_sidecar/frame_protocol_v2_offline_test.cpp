#include "frame_protocol_v2.hpp"

#include <array>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <memory>
#include <string>

namespace Frames = NikamiFNVSidecar::FramesV2;

namespace
{
    struct TestContext
    {
        int checks = 0;
        int failures = 0;

        void expect(bool condition, const std::string& message)
        {
            ++checks;
            if (!condition)
            {
                ++failures;
                std::cerr << "FAIL: " << message << '\n';
            }
        }

        void expectStatus(Frames::Status actual, Frames::Status expected, const std::string& message)
        {
            expect(
                actual == expected,
                message + " (expected " + Frames::StatusName(expected) + ", got "
                    + Frames::StatusName(actual) + ")");
        }
    };

    Frames::MappingIdentity mappingIdentity()
    {
        Frames::MappingIdentity value{};
        for (std::size_t index = 0; index < 32; ++index)
        {
            value.protocolHash[index] = static_cast<std::uint8_t>(0x20u + index);
            value.planHash[index] = static_cast<std::uint8_t>(0xE0u - index);
        }
        return value;
    }

    struct Fixture
    {
        std::unique_ptr<Frames::FrameMapping> mapping = std::make_unique<Frames::FrameMapping>();
        std::unique_ptr<Frames::FrameSlot> snapshot = std::make_unique<Frames::FrameSlot>();
        Frames::MappingIdentity expectedIdentity = mappingIdentity();

        Frames::Status reset(std::uint64_t generation = 7)
        {
            std::memset(snapshot.get(), 0, sizeof(*snapshot));
            return Frames::InitializeMapping(
                mapping.get(),
                0x0123456789ABCDEFull,
                0xFEDCBA9876543210ull,
                generation,
                expectedIdentity);
        }
    };

    Frames::FrameIdentity identity(std::uint32_t actorOrdinal, std::uint32_t actionOrdinal)
    {
        Frames::FrameIdentity value{};
        value.simulationTick = 48000 + actionOrdinal;
        value.captureOrdinal = 200 + actionOrdinal;
        value.actorReferenceId = 0x00104C6Eu;
        value.actorBaseId = 0x00104C6Fu;
        value.actorOrdinal = actorOrdinal;
        value.actionOrdinal = actionOrdinal;
        value.fixedStepOrdinal = actionOrdinal * 3u;
        value.stateKeyHash = 0xAABBCCDD00000000ull | actionOrdinal;
        value.engineFrame = 900000u + actionOrdinal;
        const float dt = 1.0f / 60.0f;
        std::memcpy(&value.dtBits, &dt, sizeof(dt));
        for (std::size_t index = 0; index < 32; ++index)
        {
            value.skeletonManifestHash[index] = static_cast<std::uint8_t>(0x40u + index);
            value.assemblyManifestHash[index] = static_cast<std::uint8_t>(0x90u + index);
        }
        return value;
    }

    Frames::PublishInput oneBlobInput(
        Frames::FrameIdentity frameIdentity,
        const void* bytes,
        std::uint32_t byteLength,
        Frames::SectionInput& section)
    {
        section = {};
        section.type = Frames::SectionType::Diagnostics;
        section.version = 1;
        section.flags = Frames::SectionRequired;
        section.data = bytes;
        section.byteLength = byteLength;

        Frames::PublishInput input{};
        input.identity = frameIdentity;
        input.frameFlags = Frames::FrameFixedStep;
        input.monotonicTimeNs = 123456789u;
        input.sections = &section;
        input.sectionCount = 1;
        return input;
    }

    void testLayoutAndRoundTrip(TestContext& test, Fixture& fixture)
    {
        test.expectStatus(fixture.reset(), Frames::Status::Ok, "mapping initializes");
        test.expectStatus(Frames::ValidateMapping(fixture.mapping.get()), Frames::Status::Ok, "mapping validates");
        test.expectStatus(
            Frames::ValidateMapping(fixture.mapping.get(), &fixture.expectedIdentity),
            Frames::Status::Ok,
            "mapping validates against its protocol and plan hashes");
        test.expect(
            std::memcmp(
                &fixture.mapping->header.identity,
                &fixture.expectedIdentity,
                sizeof(fixture.expectedIdentity)) == 0,
            "mapping preserves both 256-bit identities exactly");

        Frames::MappingIdentity mismatchedIdentity = fixture.expectedIdentity;
        mismatchedIdentity.planHash[17] ^= 0x80u;
        test.expectStatus(
            Frames::ValidateMapping(fixture.mapping.get(), &mismatchedIdentity),
            Frames::Status::InvalidMapping,
            "plan hash mismatch is rejected");
        mismatchedIdentity = fixture.expectedIdentity;
        mismatchedIdentity.protocolHash[9] ^= 0x40u;
        test.expectStatus(
            Frames::ValidateMapping(fixture.mapping.get(), &mismatchedIdentity),
            Frames::Status::InvalidMapping,
            "protocol hash mismatch is rejected");

        fixture.mapping->header.identity.planHash[5] ^= 0x01u;
        test.expectStatus(
            Frames::ValidateMapping(fixture.mapping.get(), &fixture.expectedIdentity),
            Frames::Status::InvalidMapping,
            "mutation of the sealed mapping identity is rejected");
        fixture.mapping->header.identity = fixture.expectedIdentity;

        Frames::MappingIdentity zeroIdentity{};
        test.expectStatus(
            Frames::InitializeMapping(
                fixture.mapping.get(), 1, 2, 7, zeroIdentity),
            Frames::Status::InvalidArgument,
            "an unbound mapping identity is rejected");
        test.expectStatus(
            Frames::ValidateMapping(fixture.mapping.get(), &fixture.expectedIdentity),
            Frames::Status::Ok,
            "rejected reinitialization leaves the bound mapping intact");
        test.expect(std::string(Frames::MappingNameSuffix) == ".frames", "mapping suffix is canonical");
        test.expect(sizeof(Frames::FrameMapping) == Frames::MappingBytes, "mapping size is fixed");
        test.expect(
            Frames::Crc32c("123456789", 9) == 0xE3069283u,
            "CRC32C matches the Castagnoli check vector");

        Frames::SequenceStateRecord sequence{};
        sequence.sequenceKey = 0x101u;
        sequence.sequenceNameHash = 0x102u;
        sequence.animationGroupHash = 0x103u;
        sequence.phase = static_cast<std::uint32_t>(Frames::SequencePhase::Active);
        sequence.cycle = static_cast<std::uint32_t>(Frames::SequenceCycle::Loop);
        sequence.localTime = 0.25f;
        sequence.duration = 1.0f;
        sequence.normalizedTime = 0.25f;
        sequence.weight = 1.0f;
        sequence.playbackRate = 1.0f;

        std::array<Frames::NodeTransformRecord, 2> transforms{};
        transforms[0].nodeKey = 0x201u;
        transforms[0].flags = Frames::TransformHasLocal | Frames::TransformHasWorld | Frames::TransformIsRoot;
        transforms[0].recordVersion = 1;
        transforms[0].rawMatrixLayout = static_cast<std::uint32_t>(Frames::RawMatrixLayout::NetImmerseFloat32V1);
        transforms[0].canonicalMatrixVersion =
            static_cast<std::uint32_t>(Frames::CanonicalMatrixVersion::RowMajorColumnVectorFloat32V1);
        transforms[1].nodeKey = 0x202u;
        transforms[1].parentNodeKey = transforms[0].nodeKey;
        transforms[1].nodeIndex = 1;
        transforms[1].flags = Frames::TransformHasLocal | Frames::TransformHasWorld | Frames::TransformIsBone;
        transforms[1].recordVersion = 1;
        transforms[1].rawMatrixLayout = static_cast<std::uint32_t>(Frames::RawMatrixLayout::NetImmerseFloat32V1);
        transforms[1].canonicalMatrixVersion =
            static_cast<std::uint32_t>(Frames::CanonicalMatrixVersion::RowMajorColumnVectorFloat32V1);
        for (Frames::NodeTransformRecord& transform : transforms)
        {
            transform.rawLocalMatrix.value[0] = 1.0f;
            transform.rawLocalMatrix.value[5] = 1.0f;
            transform.rawLocalMatrix.value[10] = 1.0f;
            transform.rawLocalMatrix.value[15] = 1.0f;
            transform.rawWorldMatrix = transform.rawLocalMatrix;
            transform.canonicalLocalMatrix = transform.rawLocalMatrix;
            transform.canonicalWorldMatrix = transform.rawLocalMatrix;
            transform.decomposedCanonicalLocal.rotationQuaternion[3] = 1.0f;
            transform.decomposedCanonicalLocal.scale[0] = 1.0f;
            transform.decomposedCanonicalLocal.scale[1] = 1.0f;
            transform.decomposedCanonicalLocal.scale[2] = 1.0f;
            transform.decomposedCanonicalWorld = transform.decomposedCanonicalLocal;
        }
        transforms[0].rawWorldMatrix.value[3] = 11.5f;
        transforms[0].canonicalWorldMatrix.value[3] = 11.5f;
        transforms[0].decomposedCanonicalWorld.translation[0] = 11.5f;

        Frames::EquipmentRecord equipment{};
        equipment.itemFormId = 0x00004322u;
        equipment.baseFormId = 0x00004322u;
        equipment.slotMask = 1ull << 5u;
        equipment.modelPathHash = 0x303u;
        equipment.attachNodeHash = 0x304u;
        equipment.count = 1;
        equipment.condition = 0.75f;
        equipment.flags = Frames::EquipmentWorn | Frames::EquipmentWeapon;
        equipment.hand = static_cast<std::uint32_t>(Frames::Hand::Right);

        Frames::FaceChannelRecord face{};
        face.channelKey = 0x401u;
        face.kind = static_cast<std::uint32_t>(Frames::FaceChannelKind::Phoneme);
        face.value = 0.33f;
        face.targetValue = 0.5f;

        std::array<Frames::SectionInput, 4> sections{};
        sections[0] = {
            Frames::SectionType::SequenceStates,
            1,
            Frames::SectionRequired | Frames::SectionCanonicalOrder,
            1,
            static_cast<std::uint32_t>(sizeof(sequence)),
            &sequence,
            static_cast<std::uint32_t>(sizeof(sequence))};
        sections[1] = {
            Frames::SectionType::NodeTransforms,
            1,
            Frames::SectionRequired | Frames::SectionCanonicalOrder,
            static_cast<std::uint32_t>(transforms.size()),
            static_cast<std::uint32_t>(sizeof(transforms[0])),
            transforms.data(),
            static_cast<std::uint32_t>(sizeof(transforms))};
        sections[2] = {
            Frames::SectionType::Equipment,
            1,
            Frames::SectionRequired,
            1,
            static_cast<std::uint32_t>(sizeof(equipment)),
            &equipment,
            static_cast<std::uint32_t>(sizeof(equipment))};
        sections[3] = {
            Frames::SectionType::FaceChannels,
            1,
            Frames::SectionRequired,
            1,
            static_cast<std::uint32_t>(sizeof(face)),
            &face,
            static_cast<std::uint32_t>(sizeof(face))};

        Frames::PublishInput input{};
        input.identity = identity(3, 4);
        input.frameFlags = Frames::FrameFixedStep | Frames::FrameDialogueActive;
        input.monotonicTimeNs = 999999u;
        input.sections = sections.data();
        input.sectionCount = static_cast<std::uint32_t>(sections.size());

        std::uint64_t sequenceNumber = 0;
        test.expectStatus(
            Frames::Publish(fixture.mapping.get(), Frames::Source::Retail, input, &sequenceNumber),
            Frames::Status::Ok,
            "retail frame publishes");
        test.expect(sequenceNumber == 1, "first retail sequence is one");
        test.expect(
            Frames::AtomicLoadAcquire(&fixture.mapping->header.rings[0].publishedSequence) == 1,
            "retail cursor publishes after the slot commit");

        const Frames::ReadResult read =
            Frames::ReadNext(fixture.mapping.get(), Frames::Source::Retail, fixture.snapshot.get());
        test.expectStatus(read.status, Frames::Status::Ok, "retail frame round-trips");
        test.expect(read.frame.identity != nullptr && read.frame.identity->sequence == 1, "frame identity round-trips");
        test.expect(
            read.frame.identity != nullptr && read.frame.identity->previousSequence == 0,
            "first frame identifies its contiguous predecessor");
        test.expect(
            read.frame.identity != nullptr && read.frame.identity->engineFrame == 900004u,
            "engine frame is part of frame identity");
        test.expect(
            read.frame.identity != nullptr
                && read.frame.identity->dtBits == input.identity.dtBits,
            "dt is preserved as exact IEEE-754 bits");
        test.expect(
            read.frame.identity != nullptr
                && std::memcmp(
                    read.frame.identity->skeletonManifestHash,
                    input.identity.skeletonManifestHash,
                    sizeof(input.identity.skeletonManifestHash)) == 0,
            "skeleton manifest identity round-trips exactly");
        test.expect(
            read.frame.identity != nullptr
                && std::memcmp(
                    read.frame.identity->assemblyManifestHash,
                    input.identity.assemblyManifestHash,
                    sizeof(input.identity.assemblyManifestHash)) == 0,
            "assembly manifest identity round-trips exactly");

        const Frames::SectionDescriptor* sequenceSection = read.frame.find(Frames::SectionType::SequenceStates);
        const Frames::SectionDescriptor* transformSection = read.frame.find(Frames::SectionType::NodeTransforms);
        const Frames::SectionDescriptor* equipmentSection = read.frame.find(Frames::SectionType::Equipment);
        const Frames::SectionDescriptor* faceSection = read.frame.find(Frames::SectionType::FaceChannels);
        test.expect(sequenceSection != nullptr, "sequence section is indexed");
        test.expect(transformSection != nullptr, "transform section is indexed");
        test.expect(equipmentSection != nullptr, "equipment section is indexed");
        test.expect(faceSection != nullptr, "face section is indexed");
        if (sequenceSection != nullptr)
        {
            test.expect(
                std::memcmp(read.frame.sectionData(*sequenceSection), &sequence, sizeof(sequence)) == 0,
                "sequence bytes round-trip exactly");
        }
        if (transformSection != nullptr)
        {
            test.expect(
                std::memcmp(read.frame.sectionData(*transformSection), transforms.data(), sizeof(transforms)) == 0,
                "transform bytes round-trip exactly");
        }
        if (equipmentSection != nullptr)
        {
            test.expect(
                std::memcmp(read.frame.sectionData(*equipmentSection), &equipment, sizeof(equipment)) == 0,
                "equipment bytes round-trip exactly");
        }
        if (faceSection != nullptr)
        {
            test.expect(
                std::memcmp(read.frame.sectionData(*faceSection), &face, sizeof(face)) == 0,
                "face bytes round-trip exactly");
        }

        test.expectStatus(
            Frames::Acknowledge(fixture.mapping.get(), Frames::Source::Retail, sequenceNumber),
            Frames::Status::Ok,
            "retail frame acknowledges contiguously");
        test.expectStatus(
            Frames::ReadNext(fixture.mapping.get(), Frames::Source::Retail, fixture.snapshot.get()).status,
            Frames::Status::NotReady,
            "acknowledged retail ring is empty");

        input.identity = identity(9, 2);
        test.expectStatus(
            Frames::Publish(fixture.mapping.get(), Frames::Source::OpenMw, input),
            Frames::Status::Ok,
            "OpenMW ring publishes independently");
        test.expect(
            Frames::AtomicLoadAcquire(&fixture.mapping->header.rings[0].publishedSequence) == 1
                && Frames::AtomicLoadAcquire(&fixture.mapping->header.rings[1].publishedSequence) == 1,
            "retail and OpenMW cursors remain independent");
        test.expectStatus(
            Frames::ReadNext(fixture.mapping.get(), Frames::Source::OpenMw, fixture.snapshot.get()).status,
            Frames::Status::Ok,
            "OpenMW frame round-trips");
    }

    void testCrcCorruption(TestContext& test, Fixture& fixture)
    {
        test.expectStatus(fixture.reset(), Frames::Status::Ok, "CRC fixture resets");
        std::array<std::uint8_t, 31> bytes{};
        for (std::size_t index = 0; index < bytes.size(); ++index)
            bytes[index] = static_cast<std::uint8_t>(index * 7u);

        Frames::SectionInput section{};
        const Frames::PublishInput input = oneBlobInput(
            identity(1, 1), bytes.data(), static_cast<std::uint32_t>(bytes.size()), section);
        test.expectStatus(
            Frames::Publish(fixture.mapping.get(), Frames::Source::Retail, input),
            Frames::Status::Ok,
            "CRC frame publishes");

        Frames::FrameSlot& live = fixture.mapping->rings[0].slots[0];
        live.payload[3] ^= 0x80u;
        test.expectStatus(
            Frames::ReadNext(fixture.mapping.get(), Frames::Source::Retail, fixture.snapshot.get()).status,
            Frames::Status::CrcMismatch,
            "payload corruption is rejected by CRC32C");
    }

    void testPartialAndTornCommit(TestContext& test, Fixture& fixture)
    {
        std::array<std::uint8_t, 64> bytes{};
        Frames::SectionInput section{};
        Frames::PublishInput input = oneBlobInput(
            identity(2, 1), bytes.data(), static_cast<std::uint32_t>(bytes.size()), section);

        test.expectStatus(fixture.reset(), Frames::Status::Ok, "partial-commit fixture resets");
        test.expectStatus(
            Frames::Publish(fixture.mapping.get(), Frames::Source::Retail, input),
            Frames::Status::Ok,
            "partial-commit frame publishes");
        Frames::AtomicStoreRelease(&fixture.mapping->rings[0].slots[0].prefix.commitSequence, 0);
        test.expectStatus(
            Frames::ReadNext(fixture.mapping.get(), Frames::Source::Retail, fixture.snapshot.get()).status,
            Frames::Status::PartialCommit,
            "published cursor with no slot commit fails closed");

        test.expectStatus(fixture.reset(), Frames::Status::Ok, "torn-read fixture resets");
        test.expectStatus(
            Frames::Publish(fixture.mapping.get(), Frames::Source::Retail, input),
            Frames::Status::Ok,
            "torn-read frame publishes");

        struct HookContext
        {
            volatile std::uint64_t* commit = nullptr;
        } hookContext{&fixture.mapping->rings[0].slots[0].prefix.commitSequence};
        const auto mutateCommit = [](void* opaque) {
            auto* context = static_cast<HookContext*>(opaque);
            Frames::AtomicStoreRelease(context->commit, 2);
        };
        test.expectStatus(
            Frames::ReadNextObserved(
                fixture.mapping.get(),
                Frames::Source::Retail,
                fixture.snapshot.get(),
                mutateCommit,
                &hookContext)
                .status,
            Frames::Status::TornRead,
            "reader double-read rejects a commit changed during copy");
    }

    void testSectionTypeValidation(TestContext& test, Fixture& fixture)
    {
        std::array<std::uint8_t, 8> firstBytes{1, 2, 3, 4, 5, 6, 7, 8};
        std::array<std::uint8_t, 8> secondBytes{8, 7, 6, 5, 4, 3, 2, 1};
        std::array<Frames::SectionInput, 2> sections{};
        sections[0].type = Frames::SectionType::Diagnostics;
        sections[0].data = firstBytes.data();
        sections[0].byteLength = static_cast<std::uint32_t>(firstBytes.size());
        sections[1].type = Frames::SectionType::StringTable;
        sections[1].data = secondBytes.data();
        sections[1].byteLength = static_cast<std::uint32_t>(secondBytes.size());

        Frames::PublishInput input{};
        input.identity = identity(7, 1);
        input.sections = sections.data();
        input.sectionCount = static_cast<std::uint32_t>(sections.size());

        test.expectStatus(fixture.reset(), Frames::Status::Ok, "duplicate-publish fixture resets");
        sections[1].type = Frames::SectionType::Diagnostics;
        test.expectStatus(
            Frames::Publish(fixture.mapping.get(), Frames::Source::Retail, input),
            Frames::Status::InvalidSection,
            "publisher rejects duplicate section types");

        sections[1].type = static_cast<Frames::SectionType>(Frames::SectionTypeCount + 10u);
        test.expectStatus(
            Frames::Publish(fixture.mapping.get(), Frames::Source::Retail, input),
            Frames::Status::InvalidSection,
            "publisher rejects an out-of-range section type");

        sections[1].type = Frames::SectionType::StringTable;
        test.expectStatus(fixture.reset(), Frames::Status::Ok, "duplicate-read fixture resets");
        test.expectStatus(
            Frames::Publish(fixture.mapping.get(), Frames::Source::Retail, input),
            Frames::Status::Ok,
            "valid distinct sections publish before duplicate fault injection");
        Frames::FrameSlot& duplicate = fixture.mapping->rings[0].slots[0];
        duplicate.sections[1].type = duplicate.sections[0].type;
        duplicate.prefix.contentCrc32c = 0;
        duplicate.prefix.contentCrc32c = Frames::ComputeFrameContentCrc(duplicate);
        test.expectStatus(
            Frames::ReadNext(fixture.mapping.get(), Frames::Source::Retail, fixture.snapshot.get()).status,
            Frames::Status::InvalidSection,
            "reader rejects duplicate section types even with a valid frame CRC");

        test.expectStatus(fixture.reset(), Frames::Status::Ok, "unknown-read fixture resets");
        test.expectStatus(
            Frames::Publish(fixture.mapping.get(), Frames::Source::Retail, input),
            Frames::Status::Ok,
            "valid sections publish before unknown-type fault injection");
        Frames::FrameSlot& unknown = fixture.mapping->rings[0].slots[0];
        unknown.sections[0].type = Frames::SectionTypeCount;
        unknown.prefix.contentCrc32c = 0;
        unknown.prefix.contentCrc32c = Frames::ComputeFrameContentCrc(unknown);
        test.expectStatus(
            Frames::ReadNext(fixture.mapping.get(), Frames::Source::Retail, fixture.snapshot.get()).status,
            Frames::Status::InvalidSection,
            "reader rejects an out-of-range section type even with a valid frame CRC");
    }

    void testOverflowAndOverwrite(TestContext& test, Fixture& fixture)
    {
        test.expectStatus(fixture.reset(), Frames::Status::Ok, "ring-full fixture resets");
        std::array<std::uint8_t, 8> bytes{};
        Frames::SectionInput section{};
        Frames::PublishInput input = oneBlobInput(
            identity(4, 0), bytes.data(), static_cast<std::uint32_t>(bytes.size()), section);
        for (std::size_t index = 0; index < Frames::SlotsPerRing; ++index)
        {
            input.identity.actionOrdinal = static_cast<std::uint32_t>(index);
            test.expectStatus(
                Frames::Publish(fixture.mapping.get(), Frames::Source::Retail, input),
                Frames::Status::Ok,
                "ring accepts frame before capacity");
        }
        test.expectStatus(
            Frames::Publish(fixture.mapping.get(), Frames::Source::Retail, input),
            Frames::Status::RingFull,
            "writer refuses to overwrite an unacknowledged slot");
        test.expect(
            fixture.mapping->header.rings[0].rejectedPublishCount == 1,
            "ring-full rejection is counted");

        test.expectStatus(fixture.reset(), Frames::Status::Ok, "overwrite fixture resets");
        Frames::AtomicStoreRelease(
            &fixture.mapping->header.rings[0].publishedSequence,
            static_cast<std::uint64_t>(Frames::SlotsPerRing + 1));
        test.expectStatus(
            Frames::ReadNext(fixture.mapping.get(), Frames::Source::Retail, fixture.snapshot.get()).status,
            Frames::Status::Overwritten,
            "reader rejects producer cursor that has overwritten unread history");

        test.expectStatus(fixture.reset(), Frames::Status::Ok, "numeric-overflow fixture resets");
        Frames::AtomicStoreRelease(
            &fixture.mapping->header.rings[0].publishedSequence,
            std::numeric_limits<std::uint64_t>::max());
        Frames::AtomicStoreRelease(
            &fixture.mapping->header.rings[0].consumedSequence,
            std::numeric_limits<std::uint64_t>::max() - 1u);
        test.expectStatus(
            Frames::Publish(fixture.mapping.get(), Frames::Source::Retail, input),
            Frames::Status::SequenceOverflow,
            "sequence arithmetic overflow fails closed");
    }

    void testStaleAndNoncontiguous(TestContext& test, Fixture& fixture)
    {
        std::array<std::uint8_t, 8> bytes{};
        Frames::SectionInput section{};
        Frames::PublishInput input = oneBlobInput(
            identity(5, 1), bytes.data(), static_cast<std::uint32_t>(bytes.size()), section);

        test.expectStatus(fixture.reset(), Frames::Status::Ok, "stale fixture resets");
        Frames::RingControl& control = fixture.mapping->header.rings[0];
        Frames::AtomicStoreRelease(&control.consumedSequence, 5);
        Frames::AtomicStoreRelease(&control.publishedSequence, 6);
        Frames::FrameSlot& staleSlot = fixture.mapping->rings[0].slots[Frames::SlotIndex(6)];
        Frames::AtomicStoreRelease(&staleSlot.prefix.commitSequence, 5);
        test.expectStatus(
            Frames::ReadNext(fixture.mapping.get(), Frames::Source::Retail, fixture.snapshot.get()).status,
            Frames::Status::StaleFrame,
            "reader rejects a stale slot commit");

        test.expectStatus(fixture.reset(), Frames::Status::Ok, "noncontiguous fixture resets");
        test.expectStatus(
            Frames::Publish(fixture.mapping.get(), Frames::Source::Retail, input),
            Frames::Status::Ok,
            "noncontiguous frame publishes before fault injection");
        Frames::FrameSlot& noncontiguous = fixture.mapping->rings[0].slots[0];
        noncontiguous.prefix.identity.previousSequence = 77;
        noncontiguous.prefix.contentCrc32c = 0;
        noncontiguous.prefix.contentCrc32c = Frames::ComputeFrameContentCrc(noncontiguous);
        test.expectStatus(
            Frames::ReadNext(fixture.mapping.get(), Frames::Source::Retail, fixture.snapshot.get()).status,
            Frames::Status::NonContiguous,
            "reader rejects a frame whose identity skips its predecessor");

        test.expectStatus(fixture.reset(8), Frames::Status::Ok, "generation fixture resets");
        test.expectStatus(
            Frames::Publish(fixture.mapping.get(), Frames::Source::Retail, input),
            Frames::Status::Ok,
            "generation frame publishes");
        fixture.mapping->header.rings[0].generation = 9;
        test.expectStatus(
            Frames::ReadNext(fixture.mapping.get(), Frames::Source::Retail, fixture.snapshot.get()).status,
            Frames::Status::StaleFrame,
            "reader rejects a stale-generation frame");
    }
}

int main()
{
    TestContext test{};
    Fixture fixture{};

    testLayoutAndRoundTrip(test, fixture);
    testCrcCorruption(test, fixture);
    testPartialAndTornCommit(test, fixture);
    testSectionTypeValidation(test, fixture);
    testOverflowAndOverwrite(test, fixture);
    testStaleAndNoncontiguous(test, fixture);

    if (test.failures != 0)
    {
        std::cerr << "frame_protocol_v2_offline_test: " << test.failures << " of "
                  << test.checks << " checks failed\n";
        return 1;
    }

    std::cout << "frame_protocol_v2_offline_test: PASS (" << test.checks << " checks)\n";
    return 0;
}
