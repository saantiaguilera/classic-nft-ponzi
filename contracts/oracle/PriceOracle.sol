// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

import "abdk-libraries-solidity/ABDKMath64x64.sol";

interface PriceOracle {
  event CurrentPriceUpdated(uint256 price);

  function currentPrice() external view returns (uint256 price);
  function setCurrentPrice(uint256 price) external;
}

library PriceOracleUSD {
  
  using ABDKMath64x64 for int128;

  // convert USD into oracle's token
  function convertUSD(PriceOracle oracle, int128 usd) public view returns (uint256) {
    return usd.mulu(oracle.currentPrice());
  }
}