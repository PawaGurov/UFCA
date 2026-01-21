#!/usr/bin/env bash
set -euo pipefail

# create_project.sh
# Usage: bash create_project.sh
# This will create a Hardhat + TypeScript project for the UFCA token in the current directory.
# After running it:
#   npm ci
#   npx hardhat test
#
# If you want the script to overwrite an existing directory, run in an empty folder.

PROJECT_NAME="ufca-token"
echo "Creating project files for ${PROJECT_NAME}..."

# package.json
cat > package.json <<'JSON'
{
  "name": "ufca-token",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "test": "hardhat test",
    "coverage": "hardhat coverage"
  },
  "devDependencies": {
    "@nomicfoundation/hardhat-toolbox": "^3.0.0",
    "@openzeppelin/contracts-upgradeable": "^4.9.3",
    "@openzeppelin/hardhat-upgrades": "^1.26.0",
    "dotenv": "^16.3.1",
    "hardhat": "^2.17.0",
    "mocha": "^10.2.0",
    "ts-node": "^10.9.1",
    "typescript": "^5.3.0",
    "chai": "^4.3.8",
    "@types/chai": "^4.3.4",
    "@types/node": "^20.4.2"
  },
  "dependencies": {
    "ethers": "^6.9.0"
  }
}
JSON

# tsconfig.json
cat > tsconfig.json <<'JSON'
{
  "compilerOptions": {
    "target": "es2019",
    "module": "commonjs",
    "strict": true,
    "esModuleInterop": true,
    "outDir": "dist",
    "skipLibCheck": true,
    "resolveJsonModule": true,
    "types": ["node", "mocha"]
  },
  "include": ["./scripts", "./test", "./typechain", "./hardhat.config.ts"]
}
JSON

# .gitignore
cat > .gitignore <<'TXT'
node_modules
dist
coverage
.env
TXT

# hardhat.config.ts
cat > hardhat.config.ts <<'TS'
import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@openzeppelin/hardhat-upgrades";
import * as dotenv from "dotenv";
dotenv.config();

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      }
    }
  },
  networks: {
    hardhat: {}
    // Add other networks here and set RPC URLs via .env
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY || ""
  }
};

export default config;
TS

# Create directories
mkdir -p contracts scripts test

# contracts/InvestmentUnitUpgradeable.sol
cat > contracts/InvestmentUnitUpgradeable.sol <<'SOL'
/ / SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title UFCA (upgradeable, UUPS)
/// @notice ERC20 token with whitelist, freeze, and simple linear vesting per-address
contract InvestmentUnitUpgradeable is
    Initializable,
    ERC20Upgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    // --- ACCESS ---
    mapping(address => bool) public whitelist;
    mapping(address => bool) public frozen;

    // --- VESTING ---
    struct Vesting {
        uint256 total;
        uint256 released;
        uint64 start;
        uint64 duration;
    }

    mapping(address => Vesting) public vesting;

    // --- EVENTS ---
    event Whitelisted(address indexed account);
    event Unwhitelisted(address indexed account);
    event Frozen(address indexed account);
    event Unfrozen(address indexed account);
    event VestingCreated(address indexed account, uint256 total, uint64 start, uint64 duration);
    event Minted(address indexed to, uint256 amount);
    event MintedWithVesting(address indexed to, uint256 amount, uint64 duration);
    event Burned(address indexed from, uint256 amount);

    // --- INIT ---
    function initialize() public initializer {
        __ERC20_init("UFCA", "UFCA");
        __Ownable_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        // owner (initializer) is whitelisted by default
        whitelist[_msgSender()] = true;
        emit Whitelisted(_msgSender());
    }

    // --- UPGRADE ---
    function _authorizeUpgrade(address) internal override onlyOwner {}

    // --- WHITELIST ---
    function addToWhitelist(address user) external onlyOwner {
        whitelist[user] = true;
        emit Whitelisted(user);
    }

    function removeFromWhitelist(address user) external onlyOwner {
        whitelist[user] = false;
        emit Unwhitelisted(user);
    }

    // --- FREEZE ---
    function freezeAddress(address user) external onlyOwner {
        frozen[user] = true;
        emit Frozen(user);
    }

    function unfreezeAddress(address user) external onlyOwner {
        frozen[user] = false;
        emit Unfrozen(user);
    }

    // --- PAUSE ---
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // --- MINT / BURN ---
    function mint(address to, uint256 amount) external onlyOwner {
        require(whitelist[to], "Not whitelisted");
        _mint(to, amount);
        emit Minted(to, amount);
    }

    /// @notice Mint tokens and attach a linear vesting schedule for the recipient
    /// @dev This implementation does not allow overwriting existing vesting schedule.
    function mintWithVesting(
        address to,
        uint256 amount,
        uint64 duration
    ) external onlyOwner {
        require(whitelist[to], "Not whitelisted");
        require(vesting[to].total == 0, "Vesting exists");

        _mint(to, amount);

        vesting[to] = Vesting({
            total: amount,
            released: 0,
            start: uint64(block.timestamp),
            duration: duration
        });

        emit MintedWithVesting(to, amount, duration);
        emit VestingCreated(to, amount, uint64(block.timestamp), duration);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
        emit Burned(from, amount);
    }

    // --- VESTING LOGIC ---
    function vestedAmount(address user) public view returns (uint256) {
        Vesting memory v = vesting[user];

        // If no vesting schedule set, treat full balance as vested
        if (v.total == 0) return balanceOf(user);
        if (block.timestamp < v.start) return 0;
        if (block.timestamp >= v.start + v.duration) return v.total;

        return (v.total * (uint256(block.timestamp) - uint256(v.start))) / uint256(v.duration);
    }

    function available(address user) public view returns (uint256) {
        Vesting memory v = vesting[user];
        if (v.total == 0) return balanceOf(user);

        uint256 vested = vestedAmount(user);
        if (vested <= v.released) return 0;

        return vested - v.released;
    }

    // --- INTERNAL CONTROL ---
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override whenNotPaused {
        if (from != address(0)) {
            require(!frozen[from], "Sender frozen");
            require(whitelist[from], "Sender not whitelisted");

            if (vesting[from].total > 0) {
                require(amount <= available(from), "Amount locked");
            }
        }

        if (to != address(0)) {
            require(!frozen[to], "Receiver frozen");
            require(whitelist[to], "Receiver not whitelisted");
        }

        super._beforeTokenTransfer(from, to, amount);
    }

    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        // count any tokens leaving `from` as released (including burns)
        if (from != address(0) && vesting[from].total > 0) {
            vesting[from].released += amount;
            // Ensure released never exceeds total (defensive)
            if (vesting[from].released > vesting[from].total) {
                vesting[from].released = vesting[from].total;
            }
        }

        super._afterTokenTransfer(from, to, amount);
    }

    // Reserved storage gap for future upgrades
    uint256[45] private __gap;
}
SOL

# scripts/deploy.ts
cat > scripts/deploy.ts <<'TS'
import { ethers, upgrades } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with:", await deployer.getAddress());

  const Investment = await ethers.getContractFactory("InvestmentUnitUpgradeable");
  const instance = await upgrades.deployProxy(Investment, { kind: "uups" });
  await instance.deployed();

  console.log("UFCA proxy deployed to:", instance.target || instance.address);
  console.log("Implementation (logic) address:", await upgrades.erc1967.getImplementationAddress(instance.address || instance.target));
  console.log("Owner (proxy admin control) is the account that initialized the proxy.");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
TS

# test/InvestmentUnit.test.ts
cat > test/InvestmentUnit.test.ts <<'TS'
import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { Contract } from "ethers";

describe("InvestmentUnitUpgradeable (UFCA)", function () {
  let ufca: Contract;
  let owner: any;
  let alice: any;
  let bob: any;

  beforeEach(async () => {
    [owner, alice, bob] = await ethers.getSigners();
    const Investment = await ethers.getContractFactory("InvestmentUnitUpgradeable");
    ufca = await upgrades.deployProxy(Investment, { kind: "uups" });
    await ufca.deployed();
  });

  it("initializes correctly and owner is whitelisted", async () => {
    expect(await ufca.owner()).to.equal(await owner.getAddress());
    expect(await ufca.whitelist(await owner.getAddress())).to.equal(true);
    expect(await ufca.name()).to.equal("UFCA");
    expect(await ufca.symbol()).to.equal("UFCA");
  });

  it("mint to whitelisted address works", async () => {
    await ufca.addToWhitelist(await alice.getAddress());
    await ufca.connect(owner).mint(await alice.getAddress(), ethers.parseUnits("100", 18));
    expect(await ufca.balanceOf(await alice.getAddress())).to.equal(ethers.parseUnits("100", 18));
  });

  it("mintWithVesting creates vesting and locks amount", async () => {
    await ufca.addToWhitelist(await bob.getAddress());
    // mint 100 tokens with duration 100 seconds
    await ufca.connect(owner).mintWithVesting(await bob.getAddress(), ethers.parseUnits("100", 18), 100);
    // immediately available should be 0
    expect(await ufca.available(await bob.getAddress())).to.equal(0);
    // advance time 50 seconds (half vested)
    await ethers.provider.send("evm_increaseTime", [50]);
    await ethers.provider.send("evm_mine", []);
    const availableHalf = await ufca.available(await bob.getAddress());
    // should be greater than 0 and less than total
    expect(availableHalf).to.be.gt(0);
    expect(availableHalf).to.be.lt(ethers.parseUnits("100", 18));
  });

  it("transfer more than available reverts", async () => {
    await ufca.addToWhitelist(await bob.getAddress());
    await ufca.connect(owner).mintWithVesting(await bob.getAddress(), ethers.parseUnits("100", 18), 100);
    await ethers.provider.send("evm_increaseTime", [10]);
    await ethers.provider.send("evm_mine", []);
    // tried transfer 20 while only ~10% vested => should revert if greater than available
    await expect(ufca.connect(bob).transfer(await alice.getAddress(), ethers.parseUnits("20", 18))).to.be.revertedWith("Amount locked");
  });

  it("freeze and unfreeze works", async () => {
    await ufca.addToWhitelist(await alice.getAddress());
    await ufca.connect(owner).mint(await alice.getAddress(), ethers.parseUnits("10", 18));
    await ufca.freezeAddress(await alice.getAddress());
    await expect(ufca.connect(alice).transfer(await bob.getAddress(), ethers.parseUnits("1", 18))).to.be.revertedWith("Sender frozen");
    await ufca.unfreezeAddress(await alice.getAddress());
    await ufca.connect(alice).transfer(await bob.getAddress(), ethers.parseUnits("1", 18));
    expect(await ufca.balanceOf(await bob.getAddress())).to.equal(ethers.parseUnits("1", 18));
  });

  it("pause and unpause works", async () => {
    await ufca.addToWhitelist(await alice.getAddress());
    await ufca.connect(owner).mint(await alice.getAddress(), ethers.parseUnits("20", 18));
    await ufca.pause();
    await expect(ufca.connect(alice).transfer(await bob.getAddress(), ethers.parseUnits("1", 18))).to.be.reverted;
    await ufca.unpause();
    await ufca.connect(alice).transfer(await bob.getAddress(), ethers.parseUnits("1", 18));
    expect(await ufca.balanceOf(await bob.getAddress())).to.equal(ethers.parseUnits("1", 18));
  });

  it("burn decreases balance", async () => {
    await ufca.addToWhitelist(await alice.getAddress());
    await ufca.connect(owner).mint(await alice.getAddress(), ethers.parseUnits("5", 18));
    expect(await ufca.balanceOf(await alice.getAddress())).to.equal(ethers.parseUnits("5", 18));
    await ufca.connect(owner).burn(await alice.getAddress(), ethers.parseUnits("2", 18));
    expect(await ufca.balanceOf(await alice.getAddress())).to.equal(ethers.parseUnits("3", 18));
  });
});
TS

# README.md
cat > README.md <<'MD'
# UFCA (Upgradeable ERC20)

Upgradeable ERC20 token UFCA with:
- Whitelist-based minting
- Per-address linear vesting (single vesting schedule per address)
- Freeze/unfreeze addresses
- Pausable transfers
- UUPS upgradeable pattern (OpenZeppelin Upgrades)

Notes:
- Token name & symbol: UFCA
- Decimals: 18 (standard)
- Operational peg "1 token = 1 USD" is an off-chain convention.

Quickstart:
1. Install dependencies:
   npm ci

2. Run tests:
   npx hardhat test

3. Deploy (example local):
   npx hardhat run scripts/deploy.ts --network hardhat

After deploy:
- The account that called `initialize` is the owner and is whitelisted.
- Recommended: transfer ownership to a multisig (Gnosis Safe) and use a timelock for upgrades.

Security:
- This project should be audited before mainnet deployment.
- Run static analysis (Slither) and fuzzing (Foundry/Echidna) for additional assurance.
MD

echo "Project files created."
echo ""
echo "Next steps (run):"
echo "  npm ci"
echo "  npx hardhat test"
echo ""
echo "If you want this script to also run npm ci automatically, re-run with 'bash create_project.sh && npm ci'."
echo "Done."
chmod +x create_project.sh