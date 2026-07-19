#include "fose.h"
#include "CommandTable.h"
#include "Hooks_DirectInput8Create.h"
#include "Hooks_Gameplay.h"
#include "Hooks_SaveLoad.h"
#include "Hooks_Script.h"
#include "Core_Serialization.h"
#include "Utilities.h"

IDebugLog	gLog("fose.log");

extern "C" {

void FOSE_Initialize(void)
{
#ifndef _DEBUG
	__try {
#endif
		_MESSAGE("FOSE: initialize (version = %d.%d.%d %08X)", FOSE_VERSION_INTEGER, FOSE_VERSION_INTEGER_MINOR, FOSE_VERSION_INTEGER_BETA, FALLOUT_VERSION);

#ifdef _DEBUG
		SetPriorityClass(GetCurrentProcess(), IDLE_PRIORITY_CLASS);
#endif

#if 0
		while(!IsDebuggerPresent())
		{
			Sleep(10);
		}

		Sleep(1000 * 5);
#endif

		MersenneTwister::init_genrand(GetTickCount());

		CommandTable::Init();

		Hook_DirectInput8Create_Init();
		Hook_Gameplay_Init();
		Hook_SaveLoad_Init();
		Hook_Script_Init();

#if _DEBUG
		// waits for v0002
		// ### can't be enabled without initing the plugin mgr
//		Init_CoreSerialization_Callbacks();
#endif

		FlushInstructionCache(GetCurrentProcess(), NULL, 0);

#ifndef _DEBUG
	}
	__except(EXCEPTION_EXECUTE_HANDLER)
	{
		_ERROR("exception");
	}
#endif
}

void FOSE_DeInitialize(void)
{
	_MESSAGE("FOSE: deinitialize");
}

};
