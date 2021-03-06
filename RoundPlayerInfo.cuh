#ifndef __RoundPlayerInfo__
#define __RoundPlayerInfo__

#include "BucketFunction.cuh"
#include "BlueprintHandler.cuh"

class RoundPlayerInfo {
public:
    int startPointTemplate;
    int elementSize;
    BucketFunction* bucketFunction;
    BlueprintHandler* blueprintHandler;

    RoundPlayerInfo(std::string folder, std::string fileName, int startPointTemplate, int elementSize, BucketFunction* bucketFunction, int round, int player);
};
#endif