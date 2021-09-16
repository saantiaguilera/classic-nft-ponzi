const BWToken = artifacts.require("BattleWagerToken");

module.exports = async function (deployer, network, accounts) {
  await deployer.deploy(BWToken);
  
  await BWToken.deployed();
};