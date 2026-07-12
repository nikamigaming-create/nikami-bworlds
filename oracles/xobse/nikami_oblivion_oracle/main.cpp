#include "obse/PluginAPI.h"
#include "obse/GameForms.h"
#include "obse/GameObjects.h"
#include "obse/GameProcess.h"
#include "obse/NiNodes.h"
#include "obse/NiObjects.h"

#include <Windows.h>

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>

namespace
{
    PluginHandle gPluginHandle = kPluginHandle_Invalid;
    OBSEMessagingInterface* gMessaging = nullptr;
    OBSEConsoleInterface* gConsole = nullptr;
    OBSETasks2Interface* gTasks = nullptr;
    Task<bool>* gCaptureTask = nullptr;
    std::ofstream gOutput;
    std::string gOutputPath;
    std::string gSaveName;
    std::string gStartCell;
    UInt32 gTargetForm = 0x00132A9B;
    unsigned int gFrame = 0;
    unsigned int gWorldFrame = 0;
    unsigned int gSampleEvery = 5;
    unsigned int gSettleFrames = 90;
    unsigned int gMaxWorldFrames = 150;
    bool gLoadRequested = false;
    bool gWorldReady = false;
    bool gMoveRequested = false;
    bool gComplete = false;

    constexpr const char* sSchema = "nikami-oblivion-retail-oracle/v1";
    const auto sLookupFormById = reinterpret_cast<TESForm*(__cdecl*)(UInt32)>(0x0046B250);
    auto sPlayer = reinterpret_cast<PlayerCharacter**>(0x00B333C4);

    unsigned int envUInt(const char* name, unsigned int fallback)
    {
        const char* value = std::getenv(name);
        if (value == nullptr || *value == '\0')
            return fallback;
        char* end = nullptr;
        const unsigned long parsed = std::strtoul(value, &end, 0);
        return end != value && *end == '\0' ? static_cast<unsigned int>(parsed) : fallback;
    }

    std::string envString(const char* name)
    {
        const char* value = std::getenv(name);
        return value != nullptr ? value : "";
    }

    std::string safeRuntimeString(const char* address, std::size_t maximumLength = 512)
    {
        if (address == nullptr)
            return {};
        std::string value;
        value.reserve((std::min)(maximumLength, std::size_t(64)));
        for (std::size_t i = 0; i < maximumLength; ++i)
        {
            char character = '\0';
            SIZE_T bytesRead = 0;
            if (ReadProcessMemory(GetCurrentProcess(), address + i, &character, 1, &bytesRead) == FALSE
                || bytesRead != 1 || character == '\0')
                break;
            value.push_back(character);
        }
        return value;
    }

    std::string jsonString(std::string_view value)
    {
        std::ostringstream out;
        out << '"';
        for (const unsigned char character : value)
        {
            switch (character)
            {
                case '\\': out << "\\\\"; break;
                case '"': out << "\\\""; break;
                case '\n': out << "\\n"; break;
                case '\r': out << "\\r"; break;
                case '\t': out << "\\t"; break;
                default:
                    if (character < 0x20)
                        out << "\\u" << std::hex << std::setw(4) << std::setfill('0')
                            << static_cast<unsigned int>(character) << std::dec;
                    else
                        out << character;
            }
        }
        out << '"';
        return out.str();
    }

    void openOutput()
    {
        if (!gOutput.is_open() && !gOutputPath.empty())
            gOutput.open(gOutputPath, std::ios::out | std::ios::trunc);
    }

    void writeVector(std::ostream& out, const NiVector3& value)
    {
        out << '[' << value.x << ',' << value.y << ',' << value.z << ']';
    }

    void writeMatrix(std::ostream& out, const NiMatrix33& value)
    {
        out << '[';
        for (unsigned int index = 0; index < 9; ++index)
        {
            if (index != 0)
                out << ',';
            out << value.data[index];
        }
        out << ']';
    }

    void writeNode(std::ostream& out, const NiAVObject* node)
    {
        if (node == nullptr)
        {
            out << "null";
            return;
        }
        const NiRTTI* type = const_cast<NiAVObject*>(node)->GetType();
        out << "{\"name\":" << jsonString(safeRuntimeString(node->m_pcName))
            << ",\"type\":" << jsonString(type != nullptr ? safeRuntimeString(type->name) : std::string())
            << ",\"flags\":" << node->m_flags
            << ",\"local\":";
        writeVector(out, node->m_localTranslate);
        out << ",\"world\":";
        writeVector(out, node->m_worldTranslate);
        out << ",\"localRotate\":";
        writeMatrix(out, node->m_localRotate);
        out << ",\"worldRotate\":";
        writeMatrix(out, node->m_worldRotate);
        out << ",\"localScale\":" << node->m_fLocalScale
            << ",\"worldScale\":" << node->m_worldScale
            << ",\"worldBound\":[" << node->m_kWorldBound.x << ',' << node->m_kWorldBound.y << ','
            << node->m_kWorldBound.z << ',' << node->m_kWorldBound.radius << "]}";
    }

    bool derivesFrom(NiObject* object, std::string_view baseName)
    {
        const NiRTTI* type = object != nullptr ? object->GetType() : nullptr;
        for (; type != nullptr; type = type->parent)
        {
            if (safeRuntimeString(type->name, 128) == baseName)
                return true;
        }
        return false;
    }

    bool isHeadCompositionName(std::string name)
    {
        std::transform(name.begin(), name.end(), name.begin(), [](unsigned char value) {
            return static_cast<char>(std::tolower(value));
        });
        constexpr std::string_view needles[] = {
            "head", "face", "hair", "style", "helmet", "eye", "ear", "mouth", "teeth", "tongue"
        };
        for (const std::string_view needle : needles)
            if (name.find(needle) != std::string::npos)
                return true;
        return false;
    }

    struct SceneNodeSample
    {
        NiAVObject* node = nullptr;
        unsigned int depth = 0;
        std::string parent;
    };

    void collectHeadCompositionNodes(NiAVObject* object, unsigned int depth, std::vector<SceneNodeSample>& result)
    {
        if (object == nullptr || depth > 48 || result.size() >= 256)
            return;

        const std::string name = safeRuntimeString(object->m_pcName);
        if (isHeadCompositionName(name))
        {
            std::string parentName;
            if (object->m_parent != nullptr && derivesFrom(object->m_parent, "NiObjectNET"))
                parentName = safeRuntimeString(reinterpret_cast<NiObjectNET*>(object->m_parent)->m_pcName);
            result.push_back({ object, depth, std::move(parentName) });
        }

        if (!derivesFrom(object, "NiNode"))
            return;
        NiNode* node = reinterpret_cast<NiNode*>(object);
        const unsigned int limit = (std::min)(static_cast<unsigned int>(node->m_children.firstFreeEntry),
            static_cast<unsigned int>(node->m_children.capacity));
        if (node->m_children.data == nullptr)
            return;
        for (unsigned int index = 0; index < limit; ++index)
            collectHeadCompositionNodes(node->m_children.data[index], depth + 1, result);
    }

    void writeHeadComposition(std::ostream& out, NiNode* root)
    {
        std::vector<SceneNodeSample> nodes;
        collectHeadCompositionNodes(root, 0, nodes);
        out << '[';
        for (std::size_t index = 0; index < nodes.size(); ++index)
        {
            if (index != 0)
                out << ',';
            out << "{\"depth\":" << nodes[index].depth << ",\"parent\":"
                << jsonString(nodes[index].parent) << ",\"node\":";
            writeNode(out, nodes[index].node);
            out << '}';
        }
        out << ']';
    }

    void writeBone(std::ostream& out, NiNode* root, const char* name)
    {
        out << jsonString(name) << ':';
        NiObjectNET* object = root != nullptr ? root->GetObject(name) : nullptr;
        writeNode(out, reinterpret_cast<NiAVObject*>(object));
    }

    void writeAnimationData(std::ostream& out, ActorAnimData* data)
    {
        if (data == nullptr)
        {
            out << "null";
            return;
        }
        out << "{\"sequences\":[";
        for (unsigned int index = 0; index < 5; ++index)
        {
            if (index != 0)
                out << ',';
            BSAnimGroupSequence* sequence = data->animSequences[index];
            if (sequence == nullptr)
            {
                out << "null";
                continue;
            }
            out << "{\"slot\":" << index
                << ",\"file\":" << jsonString(safeRuntimeString(sequence->filePath))
                << ",\"group\":" << (sequence->animGroup != nullptr
                        ? static_cast<unsigned int>(sequence->animGroup->animGroup) : 0xFFFFFFFFu)
                << ",\"state\":" << sequence->state
                << ",\"cycle\":" << sequence->cycleType
                << ",\"weight\":" << sequence->weight
                << ",\"frequency\":" << sequence->freq
                << ",\"begin\":" << sequence->begin
                << ",\"end\":" << sequence->end
                << ",\"last\":" << sequence->last << '}';
        }
        out << "]}";
    }

    Actor* findTargetActor()
    {
        TESForm* form = gTargetForm != 0 ? sLookupFormById(gTargetForm) : nullptr;
        if (form == nullptr)
            return nullptr;
        auto* reference = reinterpret_cast<TESObjectREFR*>(form);
        return reference->IsActor() ? reinterpret_cast<Actor*>(reference) : nullptr;
    }

    void writeActor(std::ostream& out, const char* role, Actor* actor, bool player)
    {
        out << jsonString(role) << ':';
        if (actor == nullptr)
        {
            out << "null";
            return;
        }
        BaseProcess* process = actor->process;
        TESPackage* package = process != nullptr ? process->GetCurrentPackage() : nullptr;
        TESForm* combatTarget = actor->GetCombatTarget();
        auto* base = reinterpret_cast<TESActorBase*>(actor->baseForm);
        NiNode* root = actor->GetNiNode();
        out << "{\"ref\":" << actor->refID
            << ",\"base\":" << (actor->baseForm != nullptr ? actor->baseForm->refID : 0)
            << ",\"level\":" << (base != nullptr ? base->actorBaseData.level : -1)
            << ",\"position\":[" << actor->posX << ',' << actor->posY << ',' << actor->posZ << ']'
            << ",\"rotation\":[" << actor->rotX << ',' << actor->rotY << ',' << actor->rotZ << ']'
            << ",\"processLevel\":" << (process != nullptr ? process->GetProcessLevel() : 0xFFFFFFFFu)
            << ",\"package\":" << (package != nullptr ? package->refID : 0)
            << ",\"procedure\":" << (process != nullptr
                    ? static_cast<unsigned int>(process->GetCurrentPackProcedure()) : 0xFFFFFFFFu)
            << ",\"movementFlags\":" << (process != nullptr ? process->GetMovementFlags() : 0)
            << ",\"currentAction\":" << (process != nullptr ? process->GetCurrentAction() : -1)
            << ",\"sitSleepState\":" << static_cast<unsigned int>(actor->GetSitSleepState())
            << ",\"inCombat\":" << (actor->IsInCombat(false) ? "true" : "false")
            << ",\"combatTarget\":" << (combatTarget != nullptr ? combatTarget->refID : 0)
            << ",\"root\":";
        writeNode(out, root);
        out << ",\"bones\":{";
        writeBone(out, root, "Bip01"); out << ',';
        writeBone(out, root, "Bip01 Pelvis"); out << ',';
        writeBone(out, root, "Bip01 Spine"); out << ',';
        writeBone(out, root, "Bip01 Spine1"); out << ',';
        writeBone(out, root, "Bip01 Neck1"); out << ',';
        writeBone(out, root, "Bip01 Head"); out << ',';
        writeBone(out, root, "Bip01 L UpperArm"); out << ',';
        writeBone(out, root, "Bip01 R UpperArm"); out << ',';
        writeBone(out, root, "Bip01 L Thigh"); out << ',';
        writeBone(out, root, "Bip01 R Thigh");
        out << "},\"headComposition\":";
        writeHeadComposition(out, root);
        out << ",\"thirdPersonAnimation\":";
        writeAnimationData(out, actor->GetAnimData());
        if (player)
        {
            auto* playerCharacter = reinterpret_cast<PlayerCharacter*>(actor);
            out << ",\"isThirdPerson\":" << (playerCharacter->isThirdPerson ? "true" : "false")
                << ",\"firstPersonAnimation\":";
            writeAnimationData(out, playerCharacter->firstPersonAnimData);
        }
        out << '}';
    }

    void writeSnapshot()
    {
        openOutput();
        if (!gOutput)
            return;
        PlayerCharacter* player = sPlayer != nullptr ? *sPlayer : nullptr;
        Actor* target = findTargetActor();
        const float dx = player != nullptr && target != nullptr ? target->posX - player->posX : 0.f;
        const float dy = player != nullptr && target != nullptr ? target->posY - player->posY : 0.f;
        const float dz = player != nullptr && target != nullptr ? target->posZ - player->posZ : 0.f;
        const float distance = std::sqrt(dx * dx + dy * dy + dz * dz);
        gOutput << "{\"schema\":" << jsonString(sSchema)
                << ",\"event\":\"snapshot\",\"frame\":" << gFrame
                << ",\"worldFrame\":" << gWorldFrame
                << ",\"distance\":" << distance << ',';
        writeActor(gOutput, "player", reinterpret_cast<Actor*>(player), true);
        gOutput << ',';
        writeActor(gOutput, "target", target, false);
        gOutput << "}\n";
        gOutput.flush();
    }

    void finishCapture()
    {
        if (gComplete)
            return;
        gComplete = true;
        openOutput();
        if (gOutput)
        {
            gOutput << "{\"schema\":" << jsonString(sSchema)
                    << ",\"event\":\"capture-complete\",\"frames\":" << gFrame
                    << ",\"worldFrames\":" << gWorldFrame << "}\n";
            gOutput.flush();
        }
        if (gConsole != nullptr)
            gConsole->RunScriptLine2("qqq", nullptr, true);
    }

    bool captureTask()
    {
        ++gFrame;
        openOutput();
        if (!gLoadRequested && (!gSaveName.empty() || !gStartCell.empty()) && gFrame >= 15 && gConsole != nullptr)
        {
            gLoadRequested = true;
            const std::string command = !gSaveName.empty()
                ? "LoadGameEx \"" + gSaveName + "\"" : "coc " + gStartCell;
            if (gOutput)
            {
                gOutput << "{\"schema\":" << jsonString(sSchema)
                        << ",\"event\":\"world-request-begin\",\"mode\":"
                        << jsonString(!gSaveName.empty() ? "save" : "coc") << "}\n";
                gOutput.flush();
            }
            const bool accepted = gConsole->RunScriptLine2(command.c_str(), nullptr, true);
            if (gOutput)
            {
                gOutput << "{\"schema\":" << jsonString(sSchema)
                        << ",\"event\":\"world-request-end\",\"accepted\":"
                        << (accepted ? "true" : "false") << "}\n";
                gOutput.flush();
            }
        }

        PlayerCharacter* player = sPlayer != nullptr ? *sPlayer : nullptr;
        if (!gWorldReady && gSaveName.empty() && gLoadRequested && player != nullptr && player->parentCell != nullptr)
            gWorldReady = true;
        if (gWorldReady && player != nullptr && player->parentCell != nullptr)
        {
            ++gWorldFrame;
            if (!gMoveRequested && gWorldFrame >= 30 && gTargetForm != 0 && gConsole != nullptr)
            {
                gMoveRequested = true;
                std::ostringstream command;
                command << "player.moveto " << std::hex << std::uppercase << std::setw(8)
                        << std::setfill('0') << gTargetForm;
                const bool accepted = gConsole->RunScriptLine2(command.str().c_str(), nullptr, true);
                if (gOutput)
                {
                    gOutput << "{\"schema\":" << jsonString(sSchema)
                            << ",\"event\":\"move-request\",\"target\":" << gTargetForm
                            << ",\"accepted\":" << (accepted ? "true" : "false") << "}\n";
                    gOutput.flush();
                }
            }
            if (gWorldFrame >= gSettleFrames && gWorldFrame % gSampleEvery == 0)
                writeSnapshot();
            if (gWorldFrame >= gMaxWorldFrames)
                finishCapture();
        }
        return gComplete;
    }

    void messageHandler(OBSEMessagingInterface::Message* message)
    {
        if (message == nullptr)
            return;
        if (message->type == OBSEMessagingInterface::kMessage_GameInitialized)
        {
            openOutput();
            if (gOutput)
            {
                gOutput << "{\"schema\":" << jsonString(sSchema)
                        << ",\"event\":\"game-initialized\"}\n";
                gOutput.flush();
            }
            if (gCaptureTask == nullptr && gTasks != nullptr)
                gCaptureTask = gTasks->EnqueueTaskRemovable(captureTask);
        }
        else if (message->type == OBSEMessagingInterface::kMessage_PostLoadGame)
        {
            gWorldReady = message->data != nullptr;
            gWorldFrame = 0;
            gMoveRequested = false;
            openOutput();
            if (gOutput)
            {
                gOutput << "{\"schema\":" << jsonString(sSchema)
                        << ",\"event\":\"load-result\",\"succeeded\":"
                        << (gWorldReady ? "true" : "false") << "}\n";
                gOutput.flush();
            }
            if (!gWorldReady)
                finishCapture();
        }
        else if (message->type == OBSEMessagingInterface::kMessage_ExitGame
            || message->type == OBSEMessagingInterface::kMessage_ExitGame_Console
            || message->type == OBSEMessagingInterface::kMessage_ExitToMainMenu)
        {
            if (gOutput)
            {
                gOutput << "{\"schema\":" << jsonString(sSchema)
                        << ",\"event\":\"stop\",\"frames\":" << gFrame << "}\n";
                gOutput.flush();
                gOutput.close();
            }
        }
    }
}

extern "C" __declspec(dllexport) bool OBSEPlugin_Query(const OBSEInterface* obse, PluginInfo* info)
{
    if (info == nullptr)
        return false;
    info->infoVersion = PluginInfo::kInfoVersion;
    info->name = "NikamiOblivionRetailOracle";
    info->version = 1;
    return obse != nullptr && !obse->isEditor && obse->oblivionVersion == OBLIVION_VERSION;
}

extern "C" __declspec(dllexport) bool OBSEPlugin_Load(const OBSEInterface* obse)
{
    if (obse == nullptr || obse->isEditor)
        return false;
    gPluginHandle = obse->GetPluginHandle();
    gMessaging = static_cast<OBSEMessagingInterface*>(obse->QueryInterface(kInterface_Messaging));
    gConsole = static_cast<OBSEConsoleInterface*>(obse->QueryInterface(kInterface_Console));
    gTasks = static_cast<OBSETasks2Interface*>(obse->QueryInterface(kInterface_Tasks2));
    if (gMessaging == nullptr || gConsole == nullptr || gTasks == nullptr
        || gTasks->version < OBSETasks2Interface::kVersion)
        return false;

    gOutputPath = envString("NIKAMI_OBLIVION_ORACLE_OUTPUT");
    gSaveName = envString("NIKAMI_OBLIVION_ORACLE_SAVE");
    gStartCell = envString("NIKAMI_OBLIVION_ORACLE_START_CELL");
    gTargetForm = envUInt("NIKAMI_OBLIVION_ORACLE_TARGET_FORM", gTargetForm);
    gSampleEvery = (std::max)(1u, envUInt("NIKAMI_OBLIVION_ORACLE_SAMPLE_EVERY", 5));
    gSettleFrames = (std::max)(30u, envUInt("NIKAMI_OBLIVION_ORACLE_SETTLE_FRAMES", 90));
    gMaxWorldFrames = (std::max)(gSettleFrames, envUInt("NIKAMI_OBLIVION_ORACLE_MAX_FRAMES", 150));
    gWorldReady = false;
    if (gOutputPath.empty())
        return false;
    openOutput();
    if (gOutput)
    {
        gOutput << "{\"schema\":" << jsonString(sSchema)
                << ",\"event\":\"plugin-load\"}\n";
        gOutput.flush();
    }
    if (!gMessaging->RegisterListener(gPluginHandle, "OBSE", messageHandler))
        return false;
    // xOBSE 22.10 exposes Tasks2 but does not reliably emit the later
    // GameInitialized message. Queueing here is safe: Tasks2 executes the
    // callback only when the native main-loop task pump begins.
    gCaptureTask = gTasks->EnqueueTaskRemovable(captureTask);
    return gCaptureTask != nullptr;
}
