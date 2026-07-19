#include "PluginManager.h"
#include "CommandTable.h"
#include "common/IDirectoryIterator.h"
#include "Commands_Console.h"
#include "ParamInfos.h"
#include "GameAPI.h"
#include "Utilities.h"

#ifdef RUNTIME
#include "Serialization.h"
//#include "StringVar.h"
#include "Hooks_DirectInput8Create.h"
#endif

PluginManager	g_pluginManager;

PluginManager::LoadedPlugin *	PluginManager::s_currentLoadingPlugin = NULL;
PluginHandle					PluginManager::s_currentPluginHandle = 0;

#ifdef RUNTIME

#if 0		// not yet supported
static FOSEConsoleInterface g_FOSEConsoleInterface =
{
	FOSEConsoleInterface::kVersion,
	RunScriptLine
};

static FOSEStringVarInterface g_FOSEStringVarInterface =
{
	FOSEStringVarInterface::kVersion,
	GetString,
	SetString,
	CreateString,
	RegisterStringVarInterface,
	AssignToStringVar
};

static FOSEIOInterface g_FOSEIOInterface = 
{
	FOSEIOInterface::kVersion,
	Plugin_IsKeyPressed
};
#endif

#endif

static const FOSEInterface g_FOSEInterface =
{
	PACKED_FOSE_VERSION,

#ifdef RUNTIME
	FALLOUT_VERSION,
	0,
	0,
#else
	0,
	CS_VERSION,
	1,
#endif
	PluginManager::RegisterCommand,
	PluginManager::SetOpcodeBase,
	PluginManager::QueryInterface,
	PluginManager::GetPluginHandle
};

PluginManager::PluginManager()
{
	//
}

PluginManager::~PluginManager()
{
	DeInit();
}

bool PluginManager::Init(void)
{
	bool	result = false;

	if(FindPluginDirectory())
	{
		_MESSAGE("plugin directory = %s", m_pluginDirectory.c_str());

		__try
		{
			InstallPlugins();

			result = true;
		}
		__except(EXCEPTION_EXECUTE_HANDLER)
		{
			// something very bad happened
			_ERROR("exception occurred while loading plugins");
		}
	}

	return result;
}

void PluginManager::DeInit(void)
{
	for(LoadedPluginList::iterator iter = m_plugins.begin(); iter != m_plugins.end(); ++iter)
	{
		LoadedPlugin	* plugin = &(*iter);

		if(plugin->handle)
		{
			FreeLibrary(plugin->handle);
		}
	}

	m_plugins.clear();
}

UInt32 PluginManager::GetNumPlugins(void)
{
	UInt32	numPlugins = m_plugins.size();

	// is one currently loading?
	if(s_currentLoadingPlugin) numPlugins++;

	return numPlugins;
}

UInt32 PluginManager::GetBaseOpcode(UInt32 idx)
{
	return m_plugins[idx].baseOpcode;
}

PluginHandle PluginManager::LookupHandleFromBaseOpcode(UInt32 baseOpcode)
{
	UInt32	idx = 1;

	for(LoadedPluginList::iterator iter = m_plugins.begin(); iter != m_plugins.end(); ++iter)
	{
		LoadedPlugin	* plugin = &(*iter);

		if(plugin->baseOpcode == baseOpcode)
			return idx;

		idx++;
	}

	return kPluginHandle_Invalid;
}

PluginInfo * PluginManager::GetInfoByName(const char * name)
{
	for(LoadedPluginList::iterator iter = m_plugins.begin(); iter != m_plugins.end(); ++iter)
	{
		LoadedPlugin	* plugin = &(*iter);

		if(plugin->info.name && !strcmp(name, plugin->info.name))
			return &plugin->info;
	}

	return NULL;
}

bool PluginManager::RegisterCommand(CommandInfo * _info)
{
	ASSERT(_info);
	ASSERT_STR(s_currentLoadingPlugin, "PluginManager::RegisterCommand: called outside of plugin load");

	CommandInfo	info = *_info;

#ifndef RUNTIME
	// modify callbacks for editor

	info.execute = Cmd_Default_Execute;
	info.eval = NULL;	// not supporting this yet
#endif

	if(!info.parse) info.parse = Cmd_Default_Parse;
	if(!info.shortName) info.shortName = "";
	if(!info.helpText) info.helpText = "";

	_MESSAGE("RegisterCommand %s (%04X)", info.longName, g_scriptCommands.GetCurID());

	g_scriptCommands.Add(&info);

	return true;
}

void PluginManager::SetOpcodeBase(UInt32 opcode)
{
	_MESSAGE("SetOpcodeBase %08X", opcode);

	ASSERT(opcode < 0x8000);	// arbitrary maximum for samity check
	ASSERT(opcode >= 0x2000);	// beginning of plugin opcode space
	ASSERT_STR(s_currentLoadingPlugin, "PluginManager::SetOpcodeBase: called outside of plugin load");

	if(opcode == 0x2000)
	{
		const char	* pluginName = "<unknown name>";

		if(s_currentLoadingPlugin && s_currentLoadingPlugin->info.name)
			pluginName = s_currentLoadingPlugin->info.name;

		_ERROR("You have a plugin installed that is using the default opcode base. (%s)", pluginName);
		_ERROR("This is acceptable for temporary development, but not for plugins released to the public.");
		_ERROR("As multiple plugins using the same opcode base create compatibility issues, plugins triggering this message may not load in future versions of FOSE.");
		_ERROR("Please contact the authors of the plugin and have them request and begin using an opcode range assigned by the FOSE team.");

#ifdef _DEBUG
		_ERROR("WARNING: serialization is being allowed for this plugin as this is a debug build of FOSE. It will not work in release builds.");
#endif
	}
#ifndef _DEBUG
	else	// disallow plugins using default opcode base from using it as a unique id
#endif
	{
		// record the first opcode registered for this plugin
		if(!s_currentLoadingPlugin->baseOpcode)
			s_currentLoadingPlugin->baseOpcode = opcode;
	}

	g_scriptCommands.PadTo(opcode);
	g_scriptCommands.SetCurID(opcode);
}

void * PluginManager::QueryInterface(UInt32 id)
{
	void	* result = NULL;

#ifdef RUNTIME
	switch(id)
	{
		case kInterface_Serialization:
			result = (void *)&g_FOSESerializationInterface;
			break;
#if 0		// not yet supported
		case kInterface_Console:
			result = (void *)&g_FOSEConsoleInterface;
			break;
		case kInterface_StringVar:
			result = (void *)&g_FOSEStringVarInterface;
			break;
		case kInterface_IO:
			result = (void *)&g_FOSEIOInterface;
			break;
#endif
		default:
			_WARNING("unknown QueryInterface %08X", id);
			break;
	}
#else
	_WARNING("unknown QueryInterface %08X", id);
#endif
	
	return result;
}

PluginHandle PluginManager::GetPluginHandle(void)
{
	ASSERT_STR(s_currentPluginHandle, "A plugin has called FOSEInterface::GetPluginHandle outside of its Query/Load handlers");

	return s_currentPluginHandle;
}

bool PluginManager::FindPluginDirectory(void)
{
	bool	result = false;

	// find the path <fallout directory>/data/fose/
	std::string	falloutDirectory = GetFalloutDirectory();
	
	if(!falloutDirectory.empty())
	{
		m_pluginDirectory = falloutDirectory + "Data\\FOSE\\Plugins\\";
		result = true;
	}

	return result;
}

void PluginManager::InstallPlugins(void)
{
	// avoid realloc
	m_plugins.reserve(5);

	for(IDirectoryIterator iter(m_pluginDirectory.c_str(), "*.dll"); !iter.Done(); iter.Next())
	{
		std::string	pluginPath = iter.GetFullPath();

		_MESSAGE("checking plugin %s", pluginPath.c_str());

		LoadedPlugin	plugin;
		memset(&plugin, 0, sizeof(plugin));

		s_currentLoadingPlugin = &plugin;
		s_currentPluginHandle = m_plugins.size() + 1;	// +1 because 0 is reserved for internal use

		plugin.handle = (HMODULE)LoadLibrary(pluginPath.c_str());
		if(plugin.handle)
		{
			bool		success = false;

			plugin.query = (_FOSEPlugin_Query)GetProcAddress(plugin.handle, "FOSEPlugin_Query");
			plugin.load = (_FOSEPlugin_Load)GetProcAddress(plugin.handle, "FOSEPlugin_Load");

			if(plugin.query && plugin.load)
			{
				const char	* loadStatus = NULL;

				loadStatus = SafeCallQueryPlugin(&plugin, &g_FOSEInterface);

				if(!loadStatus)
				{
					loadStatus = CheckPluginCompatibility(&plugin);

					if(!loadStatus)
					{
						loadStatus = SafeCallLoadPlugin(&plugin, &g_FOSEInterface);

						if(!loadStatus)
						{
							loadStatus = "loaded correctly";
							success = true;
						}
					}
				}
				else
				{
					loadStatus = "reported as incompatible during query";
				}

				ASSERT(loadStatus);

				_MESSAGE("plugin %s (%08X %s %08X) %s",
						pluginPath.c_str(),
						plugin.info.infoVersion,
						plugin.info.name ? plugin.info.name : "<NULL>",
						plugin.info.version,
						loadStatus);
			}
			else
			{
				_MESSAGE("plugin %s does not appear to be an FOSE plugin", pluginPath.c_str());
			}
			
			if(success)
			{
				// succeeded, add it to the list
				m_plugins.push_back(plugin);
			}
			else
			{
				// failed, unload the library
				FreeLibrary(plugin.handle);
			}
		}
		else
		{
			_ERROR("couldn't load plugin %s", pluginPath.c_str());
		}
	}

	s_currentLoadingPlugin = NULL;
	s_currentPluginHandle = 0;
}

// SEH-wrapped calls to plugin API functions to avoid bugs from bringing down the core
const char * PluginManager::SafeCallQueryPlugin(LoadedPlugin * plugin, const FOSEInterface * fose)
{
	__try
	{
		if(!plugin->query(fose, &plugin->info))
		{
			return "reported as incompatible during query";
		}
	}
	__except(EXCEPTION_EXECUTE_HANDLER)
	{
		// something very bad happened
		return "disabled, fatal error occurred while querying plugin";
	}

	return NULL;
}

const char * PluginManager::SafeCallLoadPlugin(LoadedPlugin * plugin, const FOSEInterface * fose)
{
	__try
	{
		if(!plugin->load(fose))
		{
			return "reported as incompatible during load";
		}
	}
	__except(EXCEPTION_EXECUTE_HANDLER)
	{
		// something very bad happened
		return "disabled, fatal error occurred while loading plugin";
	}

	return NULL;
}

struct MinVersionEntry
{
	const char	* name;
	UInt32		minVersion;
	const char	* reason;
};

static const MinVersionEntry	kMinVersionList[] =
{
	{	NULL, 0, NULL }
};

// see if we have a plugin that we know causes problems
const char * PluginManager::CheckPluginCompatibility(LoadedPlugin * plugin)
{
	__try
	{
		// stupid plugin check
		if(!plugin->info.name)
		{
			return "disabled, no name specified";
		}

		// check for 'known bad' versions of plugins
		for(const MinVersionEntry * iter = kMinVersionList; iter->name; ++iter)
		{
			if(!strcmp(iter->name, plugin->info.name))
			{
				if(plugin->info.version < iter->minVersion)
				{
					return iter->reason;
				}
				
				break;
			}
		}
	}
	__except(EXCEPTION_EXECUTE_HANDLER)
	{
		// paranoia
		return "disabled, fatal error occurred while checking plugin compatibility";
	}

	return NULL;
}

#ifdef RUNTIME

bool Cmd_IsPluginInstalled_Execute(COMMAND_ARGS)
{
	char	pluginName[256];

	*result = 0;

	if(!ExtractArgs(EXTRACT_ARGS, &pluginName)) return true;

	*result = (g_pluginManager.GetInfoByName(pluginName) != NULL) ? 1 : 0;

	return true;
}

bool Cmd_GetPluginVersion_Execute(COMMAND_ARGS)
{
	char	pluginName[256];

	*result = -1;

	if(!ExtractArgs(EXTRACT_ARGS, &pluginName)) return true;

	PluginInfo	* info = g_pluginManager.GetInfoByName(pluginName);
	
	if(info) *result = info->version;

	return true;
}

#endif

CommandInfo kCommandInfo_IsPluginInstalled =
{
	"IsPluginInstalled",
	"",
	0,
	"returns 1 if the specified plugin is installed, else 0",
	0,
	1,
	kParams_OneString,

	HANDLER(Cmd_IsPluginInstalled_Execute),
	Cmd_Default_Parse,
	NULL,
	NULL
};

CommandInfo kCommandInfo_GetPluginVersion =
{
	"GetPluginVersion",
	"",
	0,
	"returns the version of the specified plugin, or -1 if the plugin is not installed",
	0,
	1,
	kParams_OneString,

	HANDLER(Cmd_GetPluginVersion_Execute),
	Cmd_Default_Parse,
	NULL,
	NULL
};
