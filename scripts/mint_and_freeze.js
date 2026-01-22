// scripts/mint_and_freeze.js
// Node.js (ESM). Run with: node --experimental-specifier-resolution=node scripts/mint_and_freeze.js
import 'dotenv/config';
import { ethers } from 'ethers';

const RPC = process.env.RPC_URL;
const PK = process.env.PRIVATE_KEY;
const CONTRACT = process.env.CONTRACT_ADDRESS;
const TO = process.env.TARGET_ADDRESS;
const AMOUNT_HUMAN = process.env.AMOUNT || "1000000"; // human readable

if (!RPC || !PK || !CONTRACT || !TO) {
  console.error("Set RPC_URL, PRIVATE_KEY, CONTRACT_ADDRESS and TARGET_ADDRESS in .env");
  process.exit(1);
}

const ABI = [
  "function addToWhitelist(address) external",
  "function mint(address,uint256) external",
  "function freezeAddress(address) external",
  "function decimals() view returns (uint8)",
  "function balanceOf(address) view returns (uint256)",
  "function name() view returns (string)",
  "function symbol() view returns (string)"
];

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC);
  const wallet = new ethers.Wallet(PK, provider);
  const ownerAddr = await wallet.getAddress();
  console.log("Using owner:", ownerAddr);

  const token = new ethers.Contract(CONTRACT, ABI, wallet);

  const decimals = await token.decimals();
  const symbol = await token.symbol();
  console.log(`Token: ${symbol}, decimals: ${decimals}`);

  const amountUnits = ethers.parseUnits(AMOUNT_HUMAN, decimals);
  console.log(`Will mint ${AMOUNT_HUMAN} ${symbol} → ${amountUnits.toString()} units to ${TO}`);

  // 1) add to whitelist
  console.log("Calling addToWhitelist...");
  let tx = await token.addToWhitelist(TO);
  console.log("tx hash:", tx.hash);
  await tx.wait();
  console.log("addToWhitelist confirmed.");

  // 2) mint
  console.log("Calling mint...");
  tx = await token.mint(TO, amountUnits);
  console.log("tx hash:", tx.hash);
  await tx.wait();
  console.log("mint confirmed.");

  // 3) freeze the investor address to prevent transfers
  console.log("Calling freezeAddress...");
  tx = await token.freezeAddress(TO);
  console.log("tx hash:", tx.hash);
  await tx.wait();
  console.log("freezeAddress confirmed.");

  // Show resulting balance
  const bal = await token.balanceOf(TO);
  console.log(`Balance of ${TO}: ${ethers.formatUnits(bal, decimals)} ${symbol}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
