/*
 *  Copyright 2016-2019 Henry Lee
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 */

#include "hand.cuh"

namespace phevaluator {

static const short binariesById[52] = {
  0x1,  0x1,  0x1,  0x1,
  0x2,  0x2,  0x2,  0x2,
  0x4,  0x4,  0x4,  0x4,
  0x8,  0x8,  0x8,  0x8,
  0x10,  0x10,  0x10,  0x10,
  0x20,  0x20,  0x20,  0x20,
  0x40,  0x40,  0x40,  0x40,
  0x80,  0x80,  0x80,  0x80,
  0x100,  0x100,  0x100,  0x100,
  0x200,  0x200,  0x200,  0x200,
  0x400,  0x400,  0x400,  0x400,
  0x800,  0x800,  0x800,  0x800,
  0x1000,  0x1000,  0x1000,  0x1000,
};

static const short suitbitById[52] = {
  0x1,  0x8,  0x40,  0x200,
  0x1,  0x8,  0x40,  0x200,
  0x1,  0x8,  0x40,  0x200,
  0x1,  0x8,  0x40,  0x200,
  0x1,  0x8,  0x40,  0x200,
  0x1,  0x8,  0x40,  0x200,
  0x1,  0x8,  0x40,  0x200,
  0x1,  0x8,  0x40,  0x200,
  0x1,  0x8,  0x40,  0x200,
  0x1,  0x8,  0x40,  0x200,
  0x1,  0x8,  0x40,  0x200,
  0x1,  0x8,  0x40,  0x200,
  0x1,  0x8,  0x40,  0x200,
};

Hand Hand::operator+(const Card& card) {
  return operator+=(card);
}

Hand& Hand::operator+=(const Card& card) {
  suitHash_ += suitbitById[card];
  suitBinary_[card & 0x3] |= binariesById[card];
  quinary_[(card >> 2)]++;
  size_++;
  return *this;
}

Hand::Hand(const Card& card) {
  operator+=(card);
}

Hand::Hand(const std::vector<Card>& cards) {
  for (auto card : cards) {
    operator+=(card);
  }
}

}
