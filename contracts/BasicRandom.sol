// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

import "@openzeppelin/contracts/math/SafeMath.sol";

// BasicRandom library for basic operations.
// TODO: Should use chainlink or something more robust
library BasicRandom {

  using SafeMath for uint256;

  function rand(uint seed, uint min, uint max) internal pure returns (uint) {
    // inclusive,inclusive (don't use absolute max values of uint256)
    // deterministic based on seed provided
    uint diff = max.sub(min).add(1);
    uint randomVar = uint(keccak256(abi.encodePacked(seed))).mod(diff);
    randomVar = randomVar.add(min);
    return randomVar;
  }

  function combine(uint seed1, uint seed2) internal pure returns (uint) {
    return uint(keccak256(abi.encodePacked(seed1, seed2)));
  }
}