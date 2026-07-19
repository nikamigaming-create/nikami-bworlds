#pragma once

#include "CommandTable.h"
#include "ParamInfos.h"

DEFINE_COMMAND(GetUIFloat, returns the value of a float UI trait, 0, 1, kParams_OneString);
DEFINE_COMMAND(SetUIFloat, sets the value of a float UI trait, 0, 2, kParams_OneString_OneFloat);
DEFINE_COMMAND(SetUIString, sets the value of a string UI trait, 0, 2, kParams_TwoStrings);
DEFINE_COMMAND(PrintActiveTile, prints name of highlighted UI component for debug purposes, 0, 0, NULL);
