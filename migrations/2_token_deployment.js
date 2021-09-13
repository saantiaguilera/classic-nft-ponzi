const BWToken = artifacts.require("BattleWagerToken");

module.exports = async function (deployer, network, accounts) {
  await deployer.deploy(BWToken);
  const token = await BWToken.deployed();

  // token setup for local dev
  await token.transferFrom(token.address, accounts[0], web3.utils.toWei('1', 'kether')); // 1000 tokens
};