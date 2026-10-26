// Off-chain reactive listener.
//
// This is the fallback described in the task brief: a real Reactive Network RSC deployment
// (subscribe on an origin chain, react() inside ReactVM, emit a Callback to a destination
// chain) needs REACT testnet tokens on Reactive's own Lasna/Kopli chain plus RN-side
// subscription registration - a separate funded deployment from the Base Sepolia contracts in
// this repo (see src/reactive/ReactiveLiquidationStub.sol for how the real RSC would map onto
// this same logic). This script proves the BEHAVIOR instead: it subscribes to a live event
// stream (Chainlink's AnswerUpdated on the real Base Sepolia ETH/USD feed) and reacts in the
// same tick it sees the event - no fixed-interval polling loop - checking every tracked
// position's health factor and firing FlashLoanLiquidator.executeLiquidation() the instant one
// is underwater.
//
// Run (read-only / dry-run against live Base Sepolia, safe, no tx sent):
//   RPC_URL=https://sepolia.base.org TRACKED_USERS=0x... node listener/index.js
//
// Run for real (sends a tx when triggered — needs a funded keeper key registered via
// liquidator.setKeeper):
//   DRY_RUN=false PRIVATE_KEY=0x... LIQUIDATOR_ADDRESS=0x... node listener/index.js

import { ethers } from "ethers";

const RPC_URL = process.env.RPC_URL || "https://sepolia.base.org";
const AAVE_POOL = process.env.AAVE_POOL || "0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27";
const CHAINLINK_ETH_USD_FEED = process.env.CHAINLINK_FEED || "0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1";
const LIQUIDATOR_ADDRESS = process.env.LIQUIDATOR_ADDRESS || null;
const WETH = process.env.WETH || "0x4200000000000000000000000000000000000006";
const USDC = process.env.USDC || "0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f";
const AAVE_V3_PROTOCOL_ID = ethers.keccak256(ethers.toUtf8Bytes("AAVE_V3"));
const DRY_RUN = (process.env.DRY_RUN ?? "true").toLowerCase() !== "false";
const TRACKED_USERS = (process.env.TRACKED_USERS || "").split(",").map((s) => s.trim()).filter(Boolean);
const RUN_SECONDS = Number(process.env.RUN_SECONDS || 20);

const POOL_ABI = [
  "function getUserAccountData(address user) view returns (uint256 totalCollateralBase,uint256 totalDebtBase,uint256 availableBorrowsBase,uint256 currentLiquidationThreshold,uint256 ltv,uint256 healthFactor)",
];
const FEED_ABI = [
  "event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt)",
  "function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)",
  "function decimals() view returns (uint8)",
];
const LIQUIDATOR_ABI = [
  "function executeLiquidation(bytes32 protocolId,address collateralAsset,address debtAsset,address user,uint256 debtToCover,bool receiveAToken,uint24 swapFeeTier)",
];
const DEBT_TOKEN_ABI = ["function balanceOf(address) view returns (uint256)"];
const USDC_VARIABLE_DEBT_TOKEN = process.env.USDC_VARIABLE_DEBT_TOKEN || "0xFB3e85601b7fEb3691bbb8779Ef0E1069E347204";

async function checkAndMaybeLiquidate(provider, pool, user, triggerLabel) {
  const data = await pool.getUserAccountData(user);
  const hf = data.healthFactor;
  const hfStr = ethers.formatUnits(hf, 18);
  const underwater = hf < ethers.parseUnits("1", 18);
  console.log(
    `  [${triggerLabel}] user=${user} healthFactor=${hfStr} ${underwater ? "<<< UNDERWATER" : "(healthy)"}`
  );

  if (!underwater) return;

  console.log(`  !! Position ${user} crossed the liquidation threshold — reacting immediately (no poll delay).`);

  if (!LIQUIDATOR_ADDRESS) {
    console.log("  LIQUIDATOR_ADDRESS not set — logging only, not calling executeLiquidation.");
    return;
  }

  const debtToken = new ethers.Contract(USDC_VARIABLE_DEBT_TOKEN, DEBT_TOKEN_ABI, provider);
  const debtToCover = await debtToken.balanceOf(user);

  if (DRY_RUN) {
    console.log(
      `  DRY_RUN: would call executeLiquidation(AAVE_V3, WETH, USDC, ${user}, ${debtToCover}, false, 3000) on ${LIQUIDATOR_ADDRESS}`
    );
    return;
  }

  const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);
  const liquidator = new ethers.Contract(LIQUIDATOR_ADDRESS, LIQUIDATOR_ABI, wallet);
  const t0 = Date.now();
  const tx = await liquidator.executeLiquidation(AAVE_V3_PROTOCOL_ID, WETH, USDC, user, debtToCover, false, 3000);
  console.log(`  >> sent liquidation tx ${tx.hash}, waiting for confirmation...`);
  const receipt = await tx.wait();
  console.log(
    `  >> confirmed in block ${receipt.blockNumber}, gasUsed=${receipt.gasUsed}, reaction latency=${Date.now() - t0}ms`
  );
}

async function main() {
  console.log("=== Keeper off-chain reactive listener ===");
  console.log("RPC:", RPC_URL);
  console.log("Aave V3 Pool:", AAVE_POOL);
  console.log("Chainlink ETH/USD feed:", CHAINLINK_ETH_USD_FEED);
  console.log("Dry run:", DRY_RUN, "| Liquidator:", LIQUIDATOR_ADDRESS || "(not set)");
  console.log("Tracked users:", TRACKED_USERS.length ? TRACKED_USERS : "(none passed — demo mode only)");

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const network = await provider.getNetwork();
  const startBlock = await provider.getBlockNumber();
  console.log(`Connected. chainId=${network.chainId} latestBlock=${startBlock}`);

  const pool = new ethers.Contract(AAVE_POOL, POOL_ABI, provider);
  const feed = new ethers.Contract(CHAINLINK_ETH_USD_FEED, FEED_ABI, provider);

  const latest = await feed.latestRoundData();
  console.log(
    `Chainlink ETH/USD latest round ${latest.roundId}: $${ethers.formatUnits(latest.answer, 8)} (updatedAt ${new Date(
      Number(latest.updatedAt) * 1000
    ).toISOString()})`
  );

  // Show it reacting to REAL historical AnswerUpdated events first (proves event decoding
  // against the live feed, deterministically, without waiting for a live price tick).
  console.log("\n-- scanning the last ~1000 blocks of real AnswerUpdated events (chunked, public RPC caps eth_getLogs at 200 blocks/call) --");
  const totalRange = 1000;
  const chunkSize = 200;
  const rangeStart = startBlock - totalRange > 0 ? startBlock - totalRange : 0;
  let pastEvents = [];
  for (let from = rangeStart; from <= startBlock; from += chunkSize) {
    const to = Math.min(from + chunkSize - 1, startBlock);
    const chunk = await feed.queryFilter(feed.filters.AnswerUpdated(), from, to);
    pastEvents = pastEvents.concat(chunk);
  }
  console.log(`Found ${pastEvents.length} real AnswerUpdated event(s) in that range.`);
  for (const ev of pastEvents.slice(-3)) {
    console.log(
      `  round ${ev.args.roundId} @ block ${ev.blockNumber}: answer=$${ethers.formatUnits(ev.args.current, 8)}`
    );
    for (const user of TRACKED_USERS) {
      await checkAndMaybeLiquidate(provider, pool, user, `historical AnswerUpdated round ${ev.args.roundId}`);
    }
  }

  if (TRACKED_USERS.length === 0) {
    console.log(
      "\nNo TRACKED_USERS supplied, so there's nothing live to react to — this run only proves the " +
        "connection + historical-event decoding path. Pass TRACKED_USERS=<address> to watch real " +
        "accounts; the Foundry fork test (test/LiquidationFork.t.sol) exercises the full " +
        "detect -> executeLiquidation -> flash loan -> repay path end-to-end deterministically."
    );
  }

  console.log(`\n-- now subscribing live for ${RUN_SECONDS}s: will react the instant a new AnswerUpdated lands --`);
  let seen = 0;
  const listener = async (current, roundId, updatedAt, event) => {
    seen++;
    console.log(`\n[LIVE EVENT] AnswerUpdated round ${roundId} answer=$${ethers.formatUnits(current, 8)} (reacting now, same tick, no polling delay)`);
    for (const user of TRACKED_USERS) {
      await checkAndMaybeLiquidate(provider, pool, user, `live AnswerUpdated round ${roundId}`);
    }
  };
  feed.on("AnswerUpdated", listener);

  await new Promise((resolve) => setTimeout(resolve, RUN_SECONDS * 1000));
  feed.off("AnswerUpdated", listener);
  console.log(`\nListener window ended. Live AnswerUpdated events observed in window: ${seen}.`);
  process.exit(0);
}

main().catch((err) => {
  console.error("listener fatal error:", err);
  process.exit(1);
});
