// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./oracle/PriceOracle.sol";
import "./BasicRandom.sol";

// Currently this contract is the NFT + the smart contract.
// TODO: Consider making them separate entities.
// TODO: Missing:
//  * Claim money
//  * Set fee and win reward method
//  * Getters
contract Characters is Initializable, ERC721Upgradeable, AccessControlUpgradeable {
  
  using BasicRandom for uint256;
  using PriceOracleUSD for PriceOracle;

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
  }

  mapping(uint256 => FightCount) private latestFights;
  mapping(address => uint256) private cdrFee;
  mapping(address => uint256) private tokenRewards;

  IERC20 private battleWagerToken;
  PriceOracle private priceOracle;
  Character[] private characters;

  int128 private mintFee;
  int128 private winReward;

  function initialize(IERC20 _battleWagerToken, PriceOracle _priceOracle) public initializer {
    __ERC721_init("BattleWager character", "BWC");
    __AccessControl_init_unchained();

    _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);

    battleWagerToken = _battleWagerToken;
    priceOracle = _priceOracle;

    mintFee = ABDKMath64x64.divu(50, 1); // 50 usd
    winReward = ABDKMath64x64.divu(5, 1); // 5 usd
  }

  // onlyNonContract is a super simple modifier to shallowly detect if the address is a contract or not.
  modifier onlyNonContract() {
    require(tx.origin == msg.sender, "Contracts not allowed");
    _;
  }

  modifier ownerOf(uint256 target) {
    uint256[] memory tokens = new uint256[](balanceOf(msg.sender));
    bool found = false;
    for (uint256 i = 0; i < tokens.length; i++) {
      if (tokenOfOwnerByIndex(msg.sender, i) == target) {
        found = true;
        break;
      }
    }
    
    require(found, "token is not of owner");
    _;
  }

  modifier available(uint256 self) {
    require(latestFights[self].timestamp < now - 1 days && latestFights[self].count < 4, "only 4 fights per day");
    _;
  }

  // mint a character.
  function mint(string memory name) public onlyNonContract {
    uint256 chargeAmount = priceOracle.convertUSD(mintFee);
    require(battleWagerToken.balanceOf(msg.sender) >= chargeAmount);
    battleWagerToken.transferFrom(msg.sender, address(this), chargeAmount);

    uint tokenID = characters.length;
    // Basic determinstic seed, consider using chainlink or something more secure
    uint256 seed = uint256(keccak(abi.encodePacked(msg.sender, block.number, block.difficulty)));

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
    Affinity affinity = Affinity(seed.rand(0, 2));

    uint256 hl;
    uint256 hr;
    uint256 dl;
    uint256 dr;
    if (affinity == Affinity.TANK) { // High health pool, low damage
      hl = 1500;
      hr = 2000;
      dl = 166;
      dr = 375;
    } else if (affinity == Affinity.BRAWLER) { // Medium health poo, medium damage
      hl = 1000;
      hr = 1500;
      dl = 250;
      dr = 500;
    } else if (affinity = Affinity.MAGE) { // low health pool, high damage
      hl = 500;
      hr = 1000;
      dl = 500;
      dr = 750;
    }

    seed = seed.combine(uint256(affinity));
    characters.push(Character(
      name,
      seed.rand(hl * multiplier, hr * multiplier).mul(multiplier).div(1000),
      seed.rand(dl * multiplier, dr * multiplier).mul(multiplier).div(1000),
      affinity,
      rarity
    ));
    _safeMint(msg.sender, tokenID);
    emit NewCharacter(msg.sender, tokenID);
  }

  function fight(uint256 self) 
    public 
    onlyNonContract 
    ownerOf(self) 
    available(self) {

    uint256 target = _getRandomTarget(self);

    Character memory att = characters[self];
    Character memory trg = characters[target];

    bool attAdv = (uint8(att.affinity) + 1) % 3 == uint8(trg.affinity); // attacker is at advantage.
    bool trgAdv = (uint8(trg.affinity) + 1) % 3 == uint8(att.affinity); // target is at advantage.
    require(!(attAdv & trgAdv), "both can't be at advantage");

    uint256 attDmg = att.damage;
    int256 attHth = att.health;
    uint256 trgDmg = trg.damage;
    int256 trgHth = trg.health;
    if (attAdv) {
      attDmg = attDmg.mul(1200).div(1000);
      attHth = attHth * 1200 / 1000;
    }
    if (trgAdv) {
      trgDmg = trgDmg.mul(1200).div(1000);
      trgHth = trgHth * 1200 / 1000;
    }

    // Basic deterministic seed, consider using chainlink or something more secure
    uint256 seed = uint256(keccak(abi.encodePacked(msg.sender, block.number, block.difficulty, self, target)));
    while (attHth > 0 && trgHth > 0) { // fight.
      uint attRoll = seed.rand(attDmg, attDmg.mul(1500).div(1000));
      uint trgRoll = seed.rand(trgDmg, trgDmg.mul(1500).div(1000));
      
      seed = seed.combine(attRoll).combine(trgRoll);
      attHth -= trgDmg;
      trgHth -= attDmg;
    }

    bool won = attHth >= 0 || (attHth < 0 && trgHth < 0); // we fail in favor of the player if both die in the round.

    latestFights[self] = FightCount(now, (latestFights[self].count+1) % 4);
    if (won) {
      if (cdrFee[msg.sender] == 0) {
        cdrFee[msg.sender] = now;
      }
      
      uint reward = priceOracle.convertUSD(winReward.mul(difficulty).div(1000));
      uint difficulty = 1000;
      if (attHth <= att.health.div(10)) { // less than 10% health
        difficulty = 3000; // 3x payout
      } else if (attHth <= att.health.div(4)) { // less than 25% health
        difficulty = 2000; // 2x payout
      } else if (attHth <= att.health.div(2)) { // less than 50% health
        difficulty = 1500; // 1,5x payout
      } else if (attHth <= att.health.mul(3).div(4)) { // less than 75% health 
        difficulty = 1250;
      }
      tokenRewards[msg.sender] = tokenRewards[msg.sender].add(reward.mul(difficulty).div(1000));
    }
  }

  function _getRandomTarget(uint256 self) private returns(uint256) { 
    // Basic deterministic seed, consider using chainlink or something more secure
    uint256 seed = uint256(keccak(abi.encodePacked(msg.sender, block.number, block.difficulty, self)));
    uint256 i = seed.rand(1, characters.length-1);
    if (i == self) {
      return i+1;
    }
    return i;
  }
}