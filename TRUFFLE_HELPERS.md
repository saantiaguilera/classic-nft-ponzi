## Simple copy&paste commands

### Connect

`sudo truffle console --network bsctestnet`

### Init bindings

```js
let token = await BattleWagerToken.deployed()
let oracle = await BasicPriceOracle.deployed()
let char = await Characters.deployed()

// approve 1000 tokens for spending
token.approve(char.address, '1000000000000000000000')

// token price = 1 usd
oracle.setCurrentPrice('1000000000000000000')
```

### Usage

```js
// minting of char
char.mint('test name')

// get my chars
char.getMyCharacters()

// get traits for id = 0
char.getChar(0)

// fight betting 1 token
char.fight(0, '1000000000000000000')
char.fightSpecific(0, 5, '1000000000000000000')
```