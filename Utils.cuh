#ifndef __Utils__
#define __Utils__

#include <memory>
#include <chrono>

#include "Template.cuh"
#include "BucketFunction.cuh"

typedef struct trainingInitStruct {
    int policyPointer;
    int numChildren;
    int childrenWorklistPointer;
    int currentPlayer;
    float* policy;
    float* cumulativeRegrets;
    float* reachProbabilitiesLocal;
    int* children;
    int otherPlayer;
} TrainingInitStruct;

void normalizeStrategy(float* policy, int size);
TrainingInitStruct* initTrainingInitStruct(Template* schablone, int i);
bool roundEnd(vector<char> history, char action);
bool roundEnd(vector<pair<char, float>> history, pair<char, float> action);
vector<string> getCards();
vector<string> mapCardsToVisibility(vector<string> cards, int player, int round);
std::pair<int, GameState*> getCurrentNode(Template* schablone, std::vector<std::pair<char, float>> actionHistory);

#endif