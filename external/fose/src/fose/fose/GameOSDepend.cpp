#include "GameOSDepend.h"

#if FALLOUT_VERSION == FALLOUT_VERSION_1_0_15

OSInputGlobals** g_OSInputGlobals = (OSInputGlobals**)0x01176524;

#elif FALLOUT_VERSION == FALLOUT_VERSION_1_1_35

OSInputGlobals** g_OSInputGlobals = (OSInputGlobals**)0x011762C4;

#elif FALLOUT_VERSION == FALLOUT_VERSION_1_4_6

OSInputGlobals** g_OSInputGlobals = (OSInputGlobals**)0x011763C4;

#elif FALLOUT_VERSION == FALLOUT_VERSION_1_4_6b

OSInputGlobals** g_OSInputGlobals = (OSInputGlobals**)0x011763C4;

#elif FALLOUT_VERSION == FALLOUT_VERSION_1_5_22

OSInputGlobals** g_OSInputGlobals = (OSInputGlobals**)0x011795C4;

#elif FALLOUT_VERSION == FALLOUT_VERSION_1_6

OSInputGlobals** g_OSInputGlobals = (OSInputGlobals**)0x011795C4;

#elif FALLOUT_VERSION == FALLOUT_VERSION_1_7

OSInputGlobals** g_OSInputGlobals = (OSInputGlobals**)0x011795C4;

#elif FALLOUT_VERSION == FALLOUT_VERSION_1_7ng

OSInputGlobals** g_OSInputGlobals = (OSInputGlobals**)0x011765C4;

#else

#error unsupported version of fallout

#endif
