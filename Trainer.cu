#include "Trainer.cuh"
#include "Logger.cuh"
#include "Cards.cuh"

#include "SolverA.cuh"

#include "cuda_runtime.h"
#include "device_launch_parameters.h"

#include <numeric>
#include <cstring>
#include <chrono>
#include <algorithm>

using std::memcpy;
using std::inner_product;

TexasHoldemTrainer::~TexasHoldemTrainer() {
	delete schablone;
}

TexasHoldemTrainer::TexasHoldemTrainer(string folder, string fileName) {
	blueprintHandler = nullptr;
	schablone = Template::createDefaultTemplate(folder, fileName);
}

#define gpuErrchk(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, const char* file, int line, bool abort = true)
{
	if (code != cudaSuccess)
	{
		fprintf(stderr, "GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
		if (abort) exit(code);
	}
}

DeviceStructureList* prepareDevice(Template* schablone) {
	int numStateNodes = schablone->structureList->numStateNodes;
	int numLeafNodes = schablone->structureList->numLeafNodes;
	int worklistSize = numStateNodes + numLeafNodes;

	DeviceStructureList* dsl = new DeviceStructureList();
	size_t size = 0;

	size = sizeof(int) * numStateNodes;
	gpuErrchk(cudaMalloc((void**)&dsl->childrenWorklistPointers, size));
	gpuErrchk(cudaMemcpy(dsl->childrenWorklistPointers, schablone->structureList->childrenWorklistPointers, size, cudaMemcpyHostToDevice));

	size = sizeof(bool) * numLeafNodes;
	gpuErrchk(cudaMalloc((void**)&dsl->folded, size));
	gpuErrchk(cudaMemcpy(dsl->folded, schablone->structureList->folded, size, cudaMemcpyHostToDevice));

	size = sizeof(int) * numStateNodes;
	gpuErrchk(cudaMalloc((void**)&dsl->numChildren, size));
	gpuErrchk(cudaMemcpy(dsl->numChildren, schablone->structureList->numChildren, size, cudaMemcpyHostToDevice));

	size = sizeof(int);
	gpuErrchk(cudaMalloc((void**)&dsl->numLeafNodes, size));
	gpuErrchk(cudaMemcpy(dsl->numLeafNodes, &schablone->structureList->numLeafNodes, size, cudaMemcpyHostToDevice));

	size = sizeof(int);
	gpuErrchk(cudaMalloc((void**)&dsl->numStateNodes, size));
	gpuErrchk(cudaMemcpy(dsl->numStateNodes, &schablone->structureList->numStateNodes, size, cudaMemcpyHostToDevice));

	size = sizeof(float) * worklistSize;
	gpuErrchk(cudaMalloc((void**)&dsl->payoff, size));

	size = sizeof(bool) * worklistSize;
	gpuErrchk(cudaMalloc((void**)&dsl->player0, size));
	gpuErrchk(cudaMemcpy(dsl->player0, schablone->structureList->player0, size, cudaMemcpyHostToDevice));

	size = sizeof(int) * numStateNodes;
	gpuErrchk(cudaMalloc((void**)&dsl->policyPointers, size));
	gpuErrchk(cudaMemcpy(dsl->policyPointers, schablone->structureList->policyPointers, size, cudaMemcpyHostToDevice));

	size = sizeof(float) * numLeafNodes * 2;
	gpuErrchk(cudaMalloc((void**)&dsl->pots, size));
	gpuErrchk(cudaMemcpy(dsl->pots, schablone->structureList->pots, size, cudaMemcpyHostToDevice));

	size = sizeof(float) * numStateNodes * 2;
	gpuErrchk(cudaMalloc((void**)&dsl->reachProbabilities, size));

	size = sizeof(int) * worklistSize;
	gpuErrchk(cudaMalloc((void**)&dsl->worklist, size));
	gpuErrchk(cudaMemcpy(dsl->worklist, schablone->structureList->worklist, size, cudaMemcpyHostToDevice));

	size = sizeof(bool);
	gpuErrchk(cudaMalloc((void**)&dsl->playerWon, size));

	size = sizeof(bool);
	gpuErrchk(cudaMalloc((void**)&dsl->draw, size));

	size = sizeof(int);
	gpuErrchk(cudaMalloc((void**)&dsl->levelStart, size));

	size = sizeof(int);
	gpuErrchk(cudaMalloc((void**)&dsl->numElements, size));

	size = schablone->roundInfos.at(3).at(0).startPointTemplate + schablone->roundInfos.at(3).at(0).elementSize;
	size = size * sizeof(float);
	gpuErrchk(cudaMalloc((void**)&dsl->cumulativeRegrets0, size));
	gpuErrchk(cudaMalloc((void**)&dsl->policy0, size));

	size = schablone->roundInfos.at(3).at(1).startPointTemplate + schablone->roundInfos.at(3).at(1).elementSize;
	size = size * sizeof(float);
	gpuErrchk(cudaMalloc((void**)&dsl->cumulativeRegrets1, size));
	gpuErrchk(cudaMalloc((void**)&dsl->policy1, size));

	size = sizeof(DeviceStructureList);
	gpuErrchk(cudaMalloc((void**)&dsl->Dself, size));
	gpuErrchk(cudaMemcpy(dsl->Dself, dsl, size, cudaMemcpyHostToDevice));

	return dsl;
}

void TexasHoldemTrainer::loadStrategyCpu(vector<vector<string>>* playerCards) {
	//c_1) prepare strategie laden
	for (int round = 0; round < 4; round++) {
		for (int player = 0; player < 2; player++) {
			RoundPlayerInfo info = schablone->roundInfos.at(round).at(player);
			vector<char> bucket = info.bucketFunction->getBucket(playerCards->at(player));
			int pos = info.bucketFunction->getBucketPosition(bucket);
			int size = info.elementSize;

			int max = (info.bucketFunction->bucketList.size()) / (info.bucketFunction->size * 2);
			bool newBucket = pos >= max;

			if (newBucket) {
				info.bucketFunction->bucketList.insert(info.bucketFunction->bucketList.end(), bucket.begin(), bucket.end());
				float* zeroArray = new float[size] {0.f};
				info.blueprintHandler->writePolicies(pos, size * sizeof(float), zeroArray);
				delete[](zeroArray);

				int otherPlayer = (player + 1) % 2;
				RoundPlayerInfo otherInfo = schablone->roundInfos.at(round).at(otherPlayer);
				int otherSize = otherInfo.elementSize;
				float* otherZeroArray = new float[otherSize] {0.f};
				otherInfo.blueprintHandler->writePolicies(pos, otherSize * sizeof(float), otherZeroArray);
				delete[](otherZeroArray);
			}
			float* reads = info.blueprintHandler->readPolicies(pos, size * sizeof(float));
			memcpy(schablone->cumulativeRegrets.at(player) + info.startPointTemplate, reads, size * sizeof(float));
			delete[] reads;
		}
	}
}

void TexasHoldemTrainer::setReachProbabilitiesCpu() {
	schablone->structureList->reachProbabilities[0] = 1.f;
	schablone->structureList->reachProbabilities[1] = 1.f;

	for (int i = 0; i < schablone->structureList->numStateNodes; i++) {
		TrainingInitStruct* trainingInitStruct = initTrainingInitStruct(schablone, i);

		int numChildren = trainingInitStruct->numChildren;
		int* children = trainingInitStruct->children;
		int otherPlayer = trainingInitStruct->otherPlayer;
		int currentPlayer = trainingInitStruct->currentPlayer;
		float* policy = trainingInitStruct->policy;
		float* reachProbabilitiesLocal = trainingInitStruct->reachProbabilitiesLocal;

		for (int j = 0; j < numChildren; j++) {
			if (children[j] < schablone->structureList->numStateNodes) {
				schablone->structureList->reachProbabilities[2 * children[j] + currentPlayer] = policy[j] * reachProbabilitiesLocal[currentPlayer];
				schablone->structureList->reachProbabilities[2 * children[j] + otherPlayer] = reachProbabilitiesLocal[otherPlayer];
			}
		}
		free(trainingInitStruct->policy);
		delete trainingInitStruct;
	}
}

void TexasHoldemTrainer::setRegretsCpu() {
	for (int i = schablone->structureList->numStateNodes - 1; i >= 0; i--) {
		TrainingInitStruct* trainingInitStruct = initTrainingInitStruct(schablone, i);

		int* children = trainingInitStruct->children;
		int numChildren = trainingInitStruct->numChildren;

		vector<float> upstreamPayoffs;
		upstreamPayoffs.reserve(numChildren);

		for (int j = 0; j < numChildren; j++) {
			schablone->structureList->player0[i] == schablone->structureList->player0[children[j]] ? upstreamPayoffs.push_back(1 * schablone->structureList->payoff[children[j]]) : upstreamPayoffs.push_back(-1 * schablone->structureList->payoff[children[j]]);
		}

		float* policy = trainingInitStruct->policy;

		float* cumulativeRegrets = trainingInitStruct->cumulativeRegrets;

		float nodeUtility = inner_product(policy, policy + numChildren, upstreamPayoffs.begin(), 0.f);
		schablone->structureList->payoff[i] = nodeUtility;

		float* reachProbabilitiesLocal = trainingInitStruct->reachProbabilitiesLocal;
		int currentPlayer = trainingInitStruct->currentPlayer;
		int otherPlayer = trainingInitStruct->otherPlayer;

		float counterValue = reachProbabilitiesLocal[currentPlayer] * nodeUtility;

		vector<float> counterActionValues;
		counterActionValues.reserve(numChildren);

		for (int j = 0; j < numChildren; j++) {
			counterActionValues.push_back(1 * upstreamPayoffs[j]);
		}

		vector<float> counterRegrets;
		counterRegrets.reserve(numChildren);

		for (int j = 0; j < numChildren; j++) {
			counterRegrets.push_back(reachProbabilitiesLocal[otherPlayer] * (counterActionValues[j] - counterValue));

			cumulativeRegrets[j] = cumulativeRegrets[j] + std::max(0.f, counterRegrets[j]);
		}
		free(trainingInitStruct->policy);
		delete trainingInitStruct;
	}
}

void TexasHoldemTrainer::writeStrategyCpu(vector<vector<string>>* playerCards) {
	for (int round = 0; round < 4; round++) {
		for (int player = 0; player < 2; player++) {
			RoundPlayerInfo info = schablone->roundInfos.at(round).at(player);
			int pos = info.bucketFunction->getBucketPosition(info.bucketFunction->getBucket(playerCards->at(player)));

			int size = info.elementSize;

			info.blueprintHandler->writePolicies(pos, size * sizeof(float), schablone->cumulativeRegrets.at(player) + info.startPointTemplate);
		}
	}
}

void freeDeviceStructureList(DeviceStructureList* dsl) {
	gpuErrchk(cudaFree(dsl->childrenWorklistPointers));
	gpuErrchk(cudaFree(dsl->folded));
	gpuErrchk(cudaFree(dsl->numChildren));
	gpuErrchk(cudaFree(dsl->numLeafNodes));
	gpuErrchk(cudaFree(dsl->numStateNodes));
	gpuErrchk(cudaFree(dsl->payoff));
	gpuErrchk(cudaFree(dsl->player0));
	gpuErrchk(cudaFree(dsl->policyPointers));
	gpuErrchk(cudaFree(dsl->pots));
	gpuErrchk(cudaFree(dsl->reachProbabilities));
	gpuErrchk(cudaFree(dsl->worklist));

	gpuErrchk(cudaFree(dsl->playerWon));
	gpuErrchk(cudaFree(dsl->draw));

	gpuErrchk(cudaFree(dsl->levelStart));
	gpuErrchk(cudaFree(dsl->numElements));

	gpuErrchk(cudaFree(dsl->cumulativeRegrets0));
	gpuErrchk(cudaFree(dsl->cumulativeRegrets1));
	gpuErrchk(cudaFree(dsl->policy0));
	gpuErrchk(cudaFree(dsl->policy1));

	gpuErrchk(cudaFree(dsl->Dself));
	free(dsl);
}

std::pair<bool, bool> evaluate(vector<vector<string>>* playerCards) {
	int player0Eval, player1Eval;
	player0Eval = test7(playerCards->at(0));
	player1Eval = test7(playerCards->at(1));

	//draw, playerWon
	return std::pair<bool, bool>(player0Eval == player1Eval, player0Eval > player1Eval);
}

void TexasHoldemTrainer::setLeafPayoffsCpu(std::pair<bool, bool> drawPlayerWonPair) {
	for (int i = 0; i < schablone->structureList->numLeafNodes; i++) {
		float* potPointer = schablone->structureList->pots + i * (size_t)2;
		bool folded = schablone->structureList->folded[i];
		bool player0 = schablone->structureList->player0[schablone->structureList->numStateNodes + i];
		bool currentPlayer = player0 ? 0 : 1;

		bool localePlayerWon = drawPlayerWonPair.second;
		if (folded) {
			localePlayerWon = currentPlayer;
		}

		float payoff = 0.f;
		if (!drawPlayerWonPair.first) {
			payoff = potPointer[(currentPlayer + 1) % 2];
		}

		schablone->structureList->payoff[schablone->structureList->numStateNodes + i] = (localePlayerWon == currentPlayer ? payoff : -payoff);
	}
}

void TexasHoldemTrainer::trainSequentiell(int numIterations, bool useGpu) {
	Logger::logToConsole("Training start");
	vector<string> cards;
	cards.reserve(52);
	vector<string> player0Cards;
	player0Cards.reserve(7);
	vector<string> player1Cards;
	player1Cards.reserve(7);
	vector<vector<string>> playerCards = { player0Cards, player1Cards };

	DeviceStructureList* deviceStructureListPtr = nullptr;
	if (useGpu) {
		deviceStructureListPtr = prepareDevice(this->schablone);
	}

	for (int i = 0; i < numIterations; i++) {
		cards = getCards();
		playerCards.at(0) = { cards.at(0), cards.at(1), cards.at(4), cards.at(5), cards.at(6), cards.at(7), cards.at(8) };
		playerCards.at(1) = { cards.at(2), cards.at(3), cards.at(4), cards.at(5), cards.at(6), cards.at(7), cards.at(8) };

		if (i % 1000 == 0) {
			Logger::logIteration(i);
		}

		if (useGpu) {
			trainGPU(&playerCards, deviceStructureListPtr);
		}
		else {
			trainCPU(&playerCards);
		}
	}

	if (useGpu) {
		freeDeviceStructureList(deviceStructureListPtr);
	}

	for (int round = 0; round < 4; round++) {
		schablone->roundInfos.at(round).at(0).bucketFunction->saveBucketFunction();
	}
}

void TexasHoldemTrainer::trainCPU(vector<vector<string>>* playerCards) {
	if (gDebug) {
		auto start = std::chrono::high_resolution_clock::now();
		std::pair<bool, bool> drawPlayerWonPair = evaluate(playerCards);
		cpuBenchmarkCpuTimes.at(0) += std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::high_resolution_clock::now() - start).count();

		start = std::chrono::high_resolution_clock::now();
		setLeafPayoffsCpu(drawPlayerWonPair);
		cpuBenchmarkCpuTimes.at(1) += std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::high_resolution_clock::now() - start).count();

		start = std::chrono::high_resolution_clock::now();
		loadStrategyCpu(playerCards);
		cpuBenchmarkCpuTimes.at(2) += std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::high_resolution_clock::now() - start).count();

		start = std::chrono::high_resolution_clock::now();
		setReachProbabilitiesCpu();
		cpuBenchmarkCpuTimes.at(3) += std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::high_resolution_clock::now() - start).count();

		start = std::chrono::high_resolution_clock::now();
		setRegretsCpu();
		cpuBenchmarkCpuTimes.at(4) += std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::high_resolution_clock::now() - start).count();

		start = std::chrono::high_resolution_clock::now();
		writeStrategyCpu(playerCards);
		cpuBenchmarkCpuTimes.at(5) += std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::high_resolution_clock::now() - start).count();
	}
	else {
		setLeafPayoffsCpu(evaluate(playerCards));
		loadStrategyCpu(playerCards);
		setReachProbabilitiesCpu();
		setRegretsCpu();
		writeStrategyCpu(playerCards);
	}

}

__global__ void setLeafPayoffs(DeviceStructureList* dsl) {

	int id = blockIdx.x * blockDim.x + threadIdx.x;

	if (id >= *dsl->numElements) {
		return;
	}

	float* potPointer = dsl->pots + id * 2;
	bool localFolded = dsl->folded[id];
	bool localPlayer0 = dsl->player0[*dsl->numStateNodes + id];
	bool currentPlayer = localPlayer0 ? 0 : 1;

	bool localPlayerWon = *dsl->playerWon;
	if (localFolded) {
		localPlayerWon = currentPlayer;
	}

	float localPayoff = 0.f;
	if (!*dsl->draw) {
		localPayoff = potPointer[1 - currentPlayer];
	}

	dsl->payoff[*dsl->numStateNodes + id] = (localPlayerWon == currentPlayer ? localPayoff : -localPayoff);
}

__global__ void setReachProbsAndPolicy(DeviceStructureList* dsl) {

	int id = blockIdx.x * blockDim.x + threadIdx.x;

	if (id >= *dsl->numElements) {
		return;
	}

	id += *dsl->levelStart;

	int policyPointer = dsl->policyPointers[id];
	int numChildren = dsl->numChildren[id];

	int currentPlayer = dsl->player0[id] ? 0 : 1;

	float* policy = dsl->player0[id] ? dsl->policy0 + policyPointer : dsl->policy1 + policyPointer;

	float* reachProbabilitiesLocal = dsl->reachProbabilities + (id * 2);
	int* children = dsl->worklist + dsl->childrenWorklistPointers[id];
	int otherPlayer = 1 - currentPlayer;

	for (int i = 0; i < numChildren; i++) {
		policy[i] = fmaxf(policy[i], 0.f);
	}

	float arraySum = 0;
	for (int i = 0; i < numChildren; i++) {
		arraySum += policy[i];
	}

	if (arraySum > 0) {
		for (int i = 0; i < numChildren; i++) {
			policy[i] /= arraySum;
		}
	}
	else {
		for (int i = 0; i < numChildren; i++) {
			policy[i] = 1.f / numChildren;
		}
	}

	for (int j = 0; j < numChildren; j++) {
		if (children[j] < *dsl->numStateNodes) {
			dsl->reachProbabilities[2 * children[j] + currentPlayer] = policy[j] * reachProbabilitiesLocal[currentPlayer];
			dsl->reachProbabilities[2 * children[j] + otherPlayer] = reachProbabilitiesLocal[otherPlayer];
		}
	}

}

__global__ void setRegrets(DeviceStructureList* dsl) {

	int id = blockIdx.x * blockDim.x + threadIdx.x;

	if (id >= *dsl->numElements) {
		return;
	}

	id += *dsl->levelStart;

	int policyPointer = dsl->policyPointers[id];
	int numChildren = dsl->numChildren[id];
	int childrenWorklistPointer = dsl->childrenWorklistPointers[id];

	float* policy = dsl->player0[id] ? dsl->policy0 : dsl->policy1;
	policy += policyPointer;

	int* children = dsl->worklist + childrenWorklistPointer;

	float nodeUtility = 0.f;
	for (int j = 0; j < numChildren; j++) {
		dsl->player0[id] == dsl->player0[children[j]] ? nodeUtility += policy[j] * dsl->payoff[children[j]] : nodeUtility += policy[j] * -dsl->payoff[children[j]];
	}

	dsl->payoff[id] = nodeUtility;

	float* reachProbabilitiesLocal = dsl->reachProbabilities + (id * 2);
	int currentPlayer = dsl->player0[id] ? 0 : 1;
	int otherPlayer = 1 - currentPlayer;

	float counterValue = reachProbabilitiesLocal[currentPlayer] * nodeUtility;

	float* cumulativeRegrets = dsl->player0[id] ? dsl->cumulativeRegrets0 : dsl->cumulativeRegrets1;
	cumulativeRegrets += policyPointer;

	for (int j = 0; j < numChildren; j++) {
		float counterActionValue = -dsl->payoff[children[j]];

		cumulativeRegrets[j] = cumulativeRegrets[j] + fmaxf(0.f, reachProbabilitiesLocal[otherPlayer] * (counterActionValue - counterValue));
	}
}

struct GetIndexReturnType {
	int levelStart = 0;
	int numElements = 0;
};

GetIndexReturnType getIndexList(Template* schablone, int levelIndex) {
	auto levelPointers = schablone->structureList->levelPointers;
	int levelStart = schablone->structureList->worklist[levelPointers.at(levelIndex)];
	int numElements;
	if (levelIndex == levelPointers.size() - 1) {
		numElements = schablone->structureList->numStateNodes - levelStart;
	}
	else {
		numElements = schablone->structureList->worklist[levelPointers.at(levelIndex + 1)] - levelStart;
	}

	return GetIndexReturnType{ levelStart, numElements };
}

void TexasHoldemTrainer::writeStrategyFromDevice(vector<vector<string>>* playerCards, DeviceStructureList* dsl) {
	int dArrSize = schablone->roundInfos.at(3).at(0).startPointTemplate + schablone->roundInfos.at(3).at(0).elementSize;
	dArrSize = dArrSize * sizeof(float);
	cudaMemcpy(schablone->cumulativeRegrets.at(0), dsl->cumulativeRegrets0, dArrSize, cudaMemcpyDeviceToHost);
	dArrSize = schablone->roundInfos.at(3).at(1).startPointTemplate + schablone->roundInfos.at(3).at(1).elementSize;
	dArrSize = dArrSize * sizeof(float);
	cudaMemcpy(schablone->cumulativeRegrets.at(1), dsl->cumulativeRegrets1, dArrSize, cudaMemcpyDeviceToHost);

	for (int round = 0; round < 4; round++) {
		for (int player = 0; player < 2; player++) {
			RoundPlayerInfo info = schablone->roundInfos.at(round).at(player);
			int pos = info.bucketFunction->getBucketPosition(info.bucketFunction->getBucket(playerCards->at(player)));

			int size = info.elementSize;

			info.blueprintHandler->writePolicies(pos, size * sizeof(float), schablone->cumulativeRegrets.at(player) + info.startPointTemplate);
		}
	}
}

void TexasHoldemTrainer::loadStrategyToDevice(vector<vector<string>>* playerCards, DeviceStructureList* dsl) {
	//c_1) prepare strategie laden
	for (int round = 0; round < 4; round++) {
		for (int player = 0; player < 2; player++) {
			RoundPlayerInfo info = schablone->roundInfos.at(round).at(player);
			vector<char> bucket = info.bucketFunction->getBucket(playerCards->at(player));
			int pos = info.bucketFunction->getBucketPosition(bucket);
			int size = info.elementSize;

			int max = (info.bucketFunction->bucketList.size()) / (info.bucketFunction->size * 2);
			bool newBucket = pos >= max;

			if (newBucket) {
				info.bucketFunction->bucketList.insert(info.bucketFunction->bucketList.end(), bucket.begin(), bucket.end());
				float* zeroArray = new float[size] {0.f};
				info.blueprintHandler->writePolicies(pos, size * sizeof(float), zeroArray);
				delete[](zeroArray);

				int otherPlayer = (player + 1) % 2;
				RoundPlayerInfo otherInfo = schablone->roundInfos.at(round).at(otherPlayer);
				int otherSize = otherInfo.elementSize;
				float* otherZeroArray = new float[otherSize] {0.f};
				otherInfo.blueprintHandler->writePolicies(pos, otherSize * sizeof(float), otherZeroArray);
				delete[](otherZeroArray);
			}
			float* reads = info.blueprintHandler->readPolicies(pos, size * sizeof(float));

			size = size * sizeof(float);
			if (player == 0) {
				gpuErrchk(cudaMemcpy(dsl->cumulativeRegrets0 + info.startPointTemplate, reads, size, cudaMemcpyHostToDevice));
				gpuErrchk(cudaMemcpy(dsl->policy0 + info.startPointTemplate, reads, size, cudaMemcpyHostToDevice));
			}
			else {
				gpuErrchk(cudaMemcpy(dsl->cumulativeRegrets1 + info.startPointTemplate, reads, size, cudaMemcpyHostToDevice));
				gpuErrchk(cudaMemcpy(dsl->policy1 + info.startPointTemplate, reads, size, cudaMemcpyHostToDevice));
			}

			delete[] reads;
		}
	}
}

void TexasHoldemTrainer::setLeafPayoffsGpu(DeviceStructureList* dsl) {
	//b) setze payoffs in leafs durch gewinner
	int numLeafNodes = schablone->structureList->numLeafNodes;

	int N = numLeafNodes;
	gpuErrchk(cudaMemcpy(dsl->numElements, &N, sizeof(int), cudaMemcpyHostToDevice));
	int blockSize = BLOCKSIZE;
	int numBlocks = (N + blockSize - 1) / blockSize;

	setLeafPayoffs << < numBlocks, blockSize >> > (dsl->Dself);
	gpuErrchk(cudaPeekAtLastError());
	gpuErrchk(cudaDeviceSynchronize());
}

void TexasHoldemTrainer::setReachProbabilitiesAndPoliciesGpu(DeviceStructureList* dsl) {
	schablone->structureList->reachProbabilities[0] = 1.f;
	schablone->structureList->reachProbabilities[1] = 1.f;

	gpuErrchk(cudaMemcpy(dsl->reachProbabilities, schablone->structureList->reachProbabilities, sizeof(float) * 2, cudaMemcpyHostToDevice));

	for (int i = 0; i < schablone->structureList->levelPointers.size(); i++) {
		GetIndexReturnType indexListData = getIndexList(schablone, i);

		int numElements = indexListData.numElements;
		cudaMemcpy(dsl->levelStart, &indexListData.levelStart, sizeof(int), cudaMemcpyHostToDevice);

		int N = numElements;
		cudaMemcpy(dsl->numElements, &N, sizeof(int), cudaMemcpyHostToDevice);
		int blockSize = BLOCKSIZE;
		int numBlocks = (N + blockSize - 1) / blockSize;


		setReachProbsAndPolicy << < numBlocks, blockSize >> > (dsl->Dself);
		gpuErrchk(cudaPeekAtLastError());
		gpuErrchk(cudaDeviceSynchronize());
	}
}

void TexasHoldemTrainer::setRegretsGpu(DeviceStructureList* dsl) {
	for (int i = schablone->structureList->levelPointers.size() - 1; i >= 0; i--) {
		GetIndexReturnType indexListData = getIndexList(schablone, i);

		int numElements = indexListData.numElements;
		cudaMemcpy(dsl->levelStart, &indexListData.levelStart, sizeof(int), cudaMemcpyHostToDevice);

		int N = numElements;
		cudaMemcpy(dsl->numElements, &N, sizeof(int), cudaMemcpyHostToDevice);
		int blockSize = BLOCKSIZE;
		int numBlocks = (N + blockSize - 1) / blockSize;

		setRegrets << < numBlocks, blockSize >> > (dsl->Dself);
		gpuErrchk(cudaPeekAtLastError());
		gpuErrchk(cudaDeviceSynchronize());
	}
}

void TexasHoldemTrainer::trainGPU(vector<vector<string>>* playerCards, DeviceStructureList* dsl) {
	if (gDebug) {
		auto start = std::chrono::high_resolution_clock::now();
		std::pair<bool, bool> drawPlayerWonPair = evaluate(playerCards);
		gpuBenchmarkCpuTimes.at(0) += std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::high_resolution_clock::now() - start).count();
		
		start = std::chrono::high_resolution_clock::now();
		gpuErrchk(cudaMemcpy(dsl->draw, &drawPlayerWonPair.first, sizeof(bool), cudaMemcpyHostToDevice));
		gpuErrchk(cudaMemcpy(dsl->playerWon, &drawPlayerWonPair.second, sizeof(bool), cudaMemcpyHostToDevice));
		gpuBenchmarkMemcpyTimes.at(0) += std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::high_resolution_clock::now() - start).count();

		start = std::chrono::high_resolution_clock::now();
		setLeafPayoffsGpu(dsl);
		gpuBenchmarkKernelTimes.at(0) += std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::high_resolution_clock::now() - start).count();

		start = std::chrono::high_resolution_clock::now();
		loadStrategyToDevice(playerCards, dsl);
		gpuBenchmarkCpuTimes.at(1) += std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::high_resolution_clock::now() - start).count();

		start = std::chrono::high_resolution_clock::now();
		setReachProbabilitiesAndPoliciesGpu(dsl);
		gpuBenchmarkKernelTimes.at(1) += std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::high_resolution_clock::now() - start).count();

		start = std::chrono::high_resolution_clock::now();
		setRegretsGpu(dsl);
		gpuBenchmarkKernelTimes.at(2) += std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::high_resolution_clock::now() - start).count();

		start = std::chrono::high_resolution_clock::now();
		writeStrategyFromDevice(playerCards, dsl);
		gpuBenchmarkCpuTimes.at(2) += std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::high_resolution_clock::now() - start).count();
	}
	else {
		std::pair<bool, bool> drawPlayerWonPair = evaluate(playerCards);

		gpuErrchk(cudaMemcpy(dsl->draw, &drawPlayerWonPair.first, sizeof(bool), cudaMemcpyHostToDevice));
		gpuErrchk(cudaMemcpy(dsl->playerWon, &drawPlayerWonPair.second, sizeof(bool), cudaMemcpyHostToDevice));

		setLeafPayoffsGpu(dsl);
		loadStrategyToDevice(playerCards, dsl);
		setReachProbabilitiesAndPoliciesGpu(dsl);
		setRegretsGpu(dsl);
		writeStrategyFromDevice(playerCards, dsl);
	}
	
}