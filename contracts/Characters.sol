// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "abdk-libraries-solidity/ABDKMath64x64.sol";
import "./oracle/PriceOracle.sol";
import "./BasicRandom.sol";

// Currently this contract is the NFT + the smart contract.
// TODO: Consider making them separate entities.
contract Characters is Initializable, ERC721Upgradeable, AccessControlUpgradeable {
  
  using ABDKMath64x64 for int128;
  using BasicRandom for uint256;
  using PriceOracleUSD for PriceOracle;
  using SafeERC20 for IERC20;

  event NewCharacter(address indexed minter, uint256 indexed character);

  struct Character {
    string name;
    uint256 health;
    uint256 damage;
    Affinity affinity;
    Rarity rarity;
  }

  // MAGE > TANK > BRAWLER > MAGE
  enum Affinity {
    TANK,
    BRAWLER,
    MAGE
  }

  enum Rarity {
    COMMON,
    RARE,
    EPIC,
    LEGENDARY,
    MYTHICAL
  }

  struct FightCount {
    uint256 timestamp;
    uint256 count;
    bool    blocked;
  }

  mapping(uint256 => FightCount) private fightStats;
  mapping(address => uint256) private cdrFee;
  mapping(address => uint256) private tokenRewards;

  IERC20 private battleWagerToken;
  PriceOracle private priceOracle;
  Character[] private characters;

  int128 private mintFee;

  function initialize(IERC20 _battleWagerToken, PriceOracle _priceOracle) public initializer {
    __ERC721_init("BattleWager character", "BWC");
    __AccessControl_init_unchained();

    _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);

    battleWagerToken = _battleWagerToken;
    priceOracle = _priceOracle;

    mintFee = ABDKMath64x64.divu(50, 1); // 50 usd
  }

  // onlyNonContract is a super simple modifier to shallowly detect if the address is a contract or not.
  modifier onlyNonContract() {
    require(tx.origin == msg.sender, "Contracts not allowed");
    _;
  }

  modifier characterOf(uint256 target) {
    require(ownerOf(target) == msg.sender, "sender not owner");
    _;
  }

  modifier available(uint256 self) {
    require(fightStats[self].timestamp + 1 days < now && !fightStats[self].blocked, "cannot fight anymore today");
    _;
  }

  modifier restricted() {
    require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Not admin");
    _;
  }

  modifier hasBalance(uint256 betAmount) {
    require(tokenRewards[msg.sender] + battleWagerToken.balanceOf(msg.sender) >= betAmount, "not enough balance");
    _;
  }

  function setMintFee(uint256 cts) public restricted {
    mintFee = ABDKMath64x64.divu(cts, 100); // In cents eg. 500 -> 5 usd
  }

  function getMyCharacters() public view returns (uint256[] memory) {
    uint256[] memory tokens = new uint256[](balanceOf(msg.sender));
    for (uint256 i = 0; i < tokens.length; i++) {
      tokens[i] = tokenOfOwnerByIndex(msg.sender, i);
    }
    return tokens;
  }

  // getCharacter returns unpacked Character struct
  function getCharacter(uint256 tokenID) 
    public view 
    characterOf(tokenID) 
    returns(
      string memory name,
      uint256 health,
      uint256 damage,
      uint8 affinity,
      uint8 rarity
    ) {
    
    Character memory char = characters[tokenID];
    return (
      char.name,
      char.health,
      char.damage,
      uint8(char.affinity),
      uint8(char.rarity)
    );
  }

  function getUnclaimedRewards() public view returns(uint256) {
    return tokenRewards[msg.sender];
  }

  // In percentage. Gets 1% lower per day
  function getCurrentClaimTax() public view returns(uint8) {
    uint256 t = cdrFee[msg.sender];
    if (t == 0) {
      return 0; // first time or just claimed
    }
    uint256 ds = now.sub(t).div(1 days);
    if (ds > 15) { // if more than 15 days have passed, cap.
      ds = 15;
    }

    return 15 - uint8(ds); // safe cast. fits even in a word.
  }

  function getNumberOfFightsAvailable(uint256 tokenID) public view characterOf(tokenID) returns(uint8) {
    FightCount memory fc = fightStats[tokenID];
    if (fc.blocked) {
      return 0;
    }
    return 4 - uint8(fc.count % 4);
  }

  function getFightingResetTime(uint256 tokenID) public view characterOf(tokenID) returns(uint256) {
    return fightStats[tokenID].timestamp.add(1 days);
  }

  // mint a character.
  function mint(string memory name) public onlyNonContract {
    uint256 chargeAmount = priceOracle.convertUSD(mintFee);
    require(battleWagerToken.balanceOf(msg.sender) >= chargeAmount);
    battleWagerToken.transferFrom(msg.sender, address(this), chargeAmount);

    uint tokenID = characters.length;
    // Basic determinstic seed, consider using chainlink or something more secure
    uint256 seed = uint256(keccak256(abi.encodePacked(msg.sender, block.number, block.difficulty)));

    uint256 n = seed.rand(1, 1000);
    Rarity rarity = Rarity.MYTHICAL; // 0.01% MYTHICAL (n=1000)
    uint256 multiplier = 1700; // 70%
    if (n <= 608) { // 60.8% COMMON
      rarity = Rarity.COMMON;
      multiplier = 1000; // 0%
    } else if (n <= 902) { // 29.4% RARE 
      rarity = Rarity.RARE;
      multiplier = 1100; // 10%
    } else if (n <= 994) { // 9.2% EPIC
      rarity = Rarity.EPIC;
      multiplier = 1200; // 20%
    } else if (n <= 999) { // 0.05% LEGENDARY
      rarity = Rarity.LEGENDARY;
      multiplier = 1350; // 35%
    }

    seed = seed.combine(n);
    (uint256 h, uint256 d, uint8 affinity) = _generateStats(seed, multiplier);   

    characters.push(Character(
      name,
      h, d,
      Affinity(affinity),
      rarity
    ));
    _safeMint(msg.sender, tokenID);
    emit NewCharacter(msg.sender, tokenID);
  }

  function _generateStats(uint256 seed, uint256 multiplier) private pure returns(uint256 h, uint256 d, uint8 aff) {
    Affinity affinity = Affinity(seed.rand(0, 2));
    seed = seed.combine(uint256(affinity));

    if (affinity == Affinity.TANK) { // High health pool, low damage
      return (
        seed.rand(1500 * multiplier, 2000 * multiplier).mul(multiplier).div(1000),
        seed.rand(166 * multiplier, 375 * multiplier).mul(multiplier).div(1000),
        uint8(affinity)
      );
    }
    if (affinity == Affinity.BRAWLER) { // Medium health poo, medium damage
      return (
        seed.rand(1000 * multiplier, 1500 * multiplier).mul(multiplier).div(1000),
        seed.rand(250 * multiplier, 500 * multiplier).mul(multiplier).div(1000),
        uint8(affinity)
      );
    }
    // defaults to mage: 
    // low health pool, high damage
    return (
      seed.rand(500 * multiplier, 1000 * multiplier).mul(multiplier).div(1000),
      seed.rand(500 * multiplier, 750 * multiplier).mul(multiplier).div(1000),
      uint8(affinity)
    );
  }

  // cannot be performed infinite times. has a timelock
  function fightSpecific(uint256 self, uint256 target, uint256 betAmount) public available(self) {
    fightStats[self] = FightCount(now, fightStats[self].count+1, (fightStats[self].count+1) % 4 == 0);
    _fight(self, target, betAmount, 10); // 90% reward penalization
  }

  // can be performed as much as you want
  function fight(uint256 self, uint256 betAmount) public {
    uint256 target = _getRandomTarget(self);
    _fight(self, target, betAmount, 100);
  }

  // claimRewards from ingame balance
  function claimRewards() public onlyNonContract {
    require(tokenRewards[msg.sender] > 0, "nothing to claim");
    uint256 tax = uint256(getCurrentClaimTax()).add(100).mul(10); // eg. (13 + 100) * 10 = 1130
    uint256 claimable = tokenRewards[msg.sender].mul(tax).div(1000);

    tokenRewards[msg.sender] = 0; // reset, taxed amount stays in the contract as it was already ours.
    cdrFee[msg.sender] = 0;
    battleWagerToken.safeTransfer(msg.sender, claimable);
  }

  function _getRandomTarget(uint256 self) private view returns(uint256) { 
    require(characters.length > 1, "no enemies to fight");
    // Basic deterministic seed, consider using chainlink or something more secure
    uint256 seed = uint256(keccak256(abi.encodePacked(msg.sender, block.number, block.difficulty, self)));
    uint256 i = seed.rand(1, characters.length-1);
    if (i == self) {
      return (i + 1) % characters.length; // next one
    }
    return i;
  }

  function _fight(uint256 self, uint256 target, uint256 betAmount, uint256 rewardPercentage) 
    private
    onlyNonContract 
    characterOf(self) 
    hasBalance(betAmount) {

    (bool won, uint256 initH, uint256 finalH) = _performFight(self, target);
    require(initH >= finalH, "final health cannot be higher");

    if (won) {
      _onFightWon(initH, finalH, betAmount, rewardPercentage);
    } else {
      _onFightLost(betAmount);
    }
  }

  function _onFightWon(uint256 initH, uint256 finalH, uint256 betAmount, uint256 rewardPercentage) private {
    if (cdrFee[msg.sender] == 0) {
      cdrFee[msg.sender] = now;
    }
      
    uint difficulty = 100; // 10% winnings base
    if (finalH <= initH.div(10)) { // less than 10% health
      difficulty = 2000; // 2x payout
    } else if (finalH <= initH.div(4)) { // less than 25% health
      difficulty = 1000; // 1x payout
    } else if (finalH <= initH.div(2)) { // less than 50% health
      difficulty = 500; // 0,5x payout
    } else if (finalH <= initH.mul(3).div(4)) { // less than 75% health 
      difficulty = 250; // 25% payout
    }
    uint reward = betAmount.mul(difficulty).div(1000).mul(rewardPercentage * 10).div(1000);
    tokenRewards[msg.sender] = tokenRewards[msg.sender].add(reward);
  }

  function _onFightLost(uint256 betAmount) private {
    // gotta pay the bet
    if (tokenRewards[msg.sender] >= betAmount) { // has enough ingame balance, use it
      tokenRewards[msg.sender] = tokenRewards[msg.sender].sub(betAmount);
    } else { // doesn't have full ingame balance, use wallet balance + ingame balance if any
      uint256 wb = betAmount.sub(tokenRewards[msg.sender]);
      tokenRewards[msg.sender] = 0;
      cdrFee[msg.sender] = 0;
      battleWagerToken.transferFrom(msg.sender, address(this), wb);        
    }
  }

  function _performFight(uint256 self, uint256 target) private view returns(bool won, uint256 ih, uint256 fh) {
    Character memory att = characters[self];
    Character memory trg = characters[target];

    bool attAdv = (uint8(att.affinity) + 1) % 3 == uint8(trg.affinity); // attacker is at advantage.
    bool trgAdv = (uint8(trg.affinity) + 1) % 3 == uint8(att.affinity); // target is at advantage.
    require(!(attAdv && trgAdv), "both can't be at advantage");

    uint256 attDmg = att.damage;
    int256 attHth = int256(att.health);
    uint256 trgDmg = trg.damage;
    int256 trgHth = int256(trg.health);
    require(attHth > 0 && trgHth > 0, "health overflow");
    if (attAdv) {
      attDmg = attDmg.mul(1200).div(1000);
      attHth = attHth * 1200 / 1000;
    }
    if (trgAdv) {
      trgDmg = trgDmg.mul(1200).div(1000);
      trgHth = trgHth * 1200 / 1000;
    }

    // Basic deterministic seed, consider using chainlink or something more secure
    uint256 seed = uint256(keccak256(abi.encodePacked(msg.sender, block.number, now, target)));
    while (attHth > 0 && trgHth > 0) { // fight.
      uint attRoll = seed.rand(attDmg, attDmg.mul(1500).div(1000));
      uint trgRoll = seed.rand(trgDmg, trgDmg.mul(1500).div(1000));
      
      seed = seed.combine(attRoll).combine(trgRoll);
      attHth -= int256(trgDmg);
      trgHth -= int256(attDmg);
    }

    uint256 finalH = 0;
    if (attHth > 0) { // consider underflows as zero health
      finalH = uint256(attHth);
    }
    return(
      (attHth >= 0 && trgHth <= 0) || (attHth < 0 && trgHth < 0), // we fail in favor of the player if both die in the round.
      att.health,
      finalH
    );
  }
}