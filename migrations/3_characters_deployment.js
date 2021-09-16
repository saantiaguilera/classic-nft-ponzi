const { deployProxy } = require('@openzeppelin/truffle-upgrades');
const assert = require('assert');

const BasicPriceOracle = artifacts.require("./oracle/BasicPriceOracle");

const BattleWagerToken = artifacts.require("BattleWagerToken");
const Characters = artifacts.require("Characters");

module.exports = async function (deployer, network) {
  const bwToken = await BattleWagerToken.deployed();
  assert(bwToken != null, 'Expected bwToken to be set to a contract');

  const priceOracle = await deployProxy(BasicPriceOracle, [], { deployer });
  await deployProxy(Characters, [bwToken.address, priceOracle.address], { deployer });
  
  await Characters.deployed();
};
