// Paper-trading harness.
//
// Watches the REAL, live Chainlink ETH/USD feed on Base Sepolia for price moves and, when a
// move crosses a configurable trigger threshold, logs a SIMULATED trade referenced against the
// REAL Uniswap V3 pool spot price. No real funds move; everything here is logging + fake P&L
// bookkeeping over real price data.
//
// Run:
//   node paper-trader/index.js                 # uses live feed, pulls recent real round history
//   THRESHOLD_BPS=50 node paper-trader/index.js # lower trigger so more trades print (demo)

import { ethers } from "ethers";
import { writeFileSync } from "fs";

const RPC_URL = process.env.RPC_URL || "https://sepolia.base.org";
const FEED = process.env.CHAINLINK_FEED || "0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1"; // real Base Sepolia ETH/USD
const POOL = process.env.UNISWAP_POOL || "0x92266210FacF124f190fbad79AA230dfB85926Ce"; // real WETH/USDC 0.3% pool, Base Sepolia
const WETH = "0x4200000000000000000000000000000000000006";
const USDC = "0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f";
const THRESHOLD_BPS = Number(process.env.THRESHOLD_BPS || 200); // 200bps = 2%, task's example trigger
const LOOKBACK_ROUNDS = Number(process.env.LOOKBACK_ROUNDS || 150);
const NOTIONAL_USD = Number(process.env.NOTIONAL_USD || 500);

const FEED_ABI = [
  "function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)",
  "function getRoundData(uint80 roundId) view returns (uint80 roundId_, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)",
  "function decimals() view returns (uint8)",
];
const POOL_ABI = ["function slot0() view returns (uint160 sqrtPriceX96,int24 tick,uint16,uint16,uint16,uint8,bool)"];

function tickToWethUsdPrice(tick) {
  // pool token0 = WETH (18dp), token1 = USDC (6dp). Uniswap V3: price_raw(token1/token0) = 1.0001^tick,
  // in raw smallest-unit terms. Convert to a human $-per-whole-WETH number:
  //   usdPerWeth = 1.0001^tick * 10^(decimals0 - decimals1) = 1.0001^tick * 10^12
  const priceRaw = Math.pow(1.0001, tick);
  return priceRaw * 1e12;
}

async function main() {
  console.log("=== Keeper paper-trading harness (real price data, simulated trades only) ===");
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const feed = new ethers.Contract(FEED, FEED_ABI, provider);
  const pool = new ethers.Contract(POOL, POOL_ABI, provider);

  const latest = await feed.latestRoundData();
  const decimals = await feed.decimals();
  console.log(`Chainlink ETH/USD feed: ${FEED}`);
  console.log(`Latest round ${latest.roundId}: $${ethers.formatUnits(latest.answer, decimals)}`);

  const PHASE_SHIFT = 64n;
  const phaseId = latest.roundId >> PHASE_SHIFT;
  const aggRoundId = latest.roundId & ((1n << PHASE_SHIFT) - 1n);

  console.log(`\n-- pulling ${LOOKBACK_ROUNDS} real historical rounds from the live feed --`);
  const rounds = [];
  for (let i = 0; i < LOOKBACK_ROUNDS; i++) {
    const rid = (phaseId << PHASE_SHIFT) | (aggRoundId - BigInt(i));
    try {
      const rd = await feed.getRoundData(rid);
      if (rd.answer === 0n) break;
      rounds.push({ roundId: rd.roundId_, price: rd.answer, updatedAt: Number(rd.updatedAt) });
    } catch (e) {
      break; // hit phase boundary or missing round, stop
    }
  }
  rounds.reverse(); // oldest -> newest
  console.log(`Got ${rounds.length} real rounds, span: $${ethers.formatUnits(rounds[0].price, decimals)} -> $${ethers.formatUnits(rounds[rounds.length - 1].price, decimals)}`);

  const slot0 = await pool.slot0();
  const uniswapWethUsd = tickToWethUsdPrice(Number(slot0.tick));
  console.log(`Current real Uniswap V3 WETH/USDC (0.3%) pool spot price: ~$${uniswapWethUsd.toFixed(2)} per WETH (tick ${slot0.tick})`);
  console.log(`(Reference only — this testnet pool is thin, see README for real measured slippage.)\n`);

  console.log(`-- scanning for >= ${THRESHOLD_BPS / 100}% moves between consecutive real rounds (trigger threshold) --`);
  const trades = [];
  let openTrade = null;
  let maxMoveBps = 0;

  for (let i = 1; i < rounds.length; i++) {
    const prev = rounds[i - 1];
    const cur = rounds[i];
    const prevPrice = Number(ethers.formatUnits(prev.price, decimals));
    const curPrice = Number(ethers.formatUnits(cur.price, decimals));
    const moveBps = ((curPrice - prevPrice) / prevPrice) * 10000;
    if (Math.abs(moveBps) > maxMoveBps) maxMoveBps = Math.abs(moveBps);

    if (Math.abs(moveBps) >= THRESHOLD_BPS) {
      // Close any open paper trade at this new price first.
      if (openTrade) {
        const pnl = openTrade.side === "LONG"
          ? NOTIONAL_USD * (curPrice - openTrade.entryPrice) / openTrade.entryPrice
          : NOTIONAL_USD * (openTrade.entryPrice - curPrice) / openTrade.entryPrice;
        trades.push({ ...openTrade, exitPrice: curPrice, exitRound: cur.roundId.toString(), pnlUsd: pnl });
        openTrade = null;
      }
      // Mean-reversion signal: price just moved down a lot -> paper LONG (buy the dip);
      // moved up a lot -> paper SHORT (fade the pump). Purely illustrative strategy logic.
      const side = moveBps < 0 ? "LONG" : "SHORT";
      openTrade = {
        side,
        entryRound: cur.roundId.toString(),
        entryPrice: curPrice,
        triggerMoveBps: moveBps,
        entryTime: new Date(cur.updatedAt * 1000).toISOString(),
      };
      console.log(
        `  TRIGGER round ${cur.roundId}: price $${prevPrice.toFixed(2)} -> $${curPrice.toFixed(2)} (${moveBps.toFixed(2)}bps) => open paper ${side} of $${NOTIONAL_USD}`
      );
    }
  }
  if (openTrade) {
    const lastPrice = Number(ethers.formatUnits(rounds[rounds.length - 1].price, decimals));
    const pnl = openTrade.side === "LONG"
      ? NOTIONAL_USD * (lastPrice - openTrade.entryPrice) / openTrade.entryPrice
      : NOTIONAL_USD * (openTrade.entryPrice - lastPrice) / openTrade.entryPrice;
    trades.push({ ...openTrade, exitPrice: lastPrice, exitRound: "latest (still open at end of window)", pnlUsd: pnl });
  }

  console.log(`\nLargest single round-to-round real move observed in window: ${maxMoveBps.toFixed(2)}bps (${(maxMoveBps / 100).toFixed(2)}%).`);
  if (maxMoveBps < THRESHOLD_BPS) {
    console.log(
      `No real move in this window reached the ${THRESHOLD_BPS / 100}% threshold -> 0 trades triggered at that ` +
      `setting. This is an honest result of real (currently low-volatility) testnet feed data, not a bug. ` +
      `Re-run with THRESHOLD_BPS=${Math.max(10, Math.floor(maxMoveBps / 2))} to see the trigger/P&L logging fire ` +
      `against this same real data.`
    );
  }

  console.log("\n================ PAPER TRADE LOG ================");
  let totalPnl = 0;
  for (const t of trades) {
    totalPnl += t.pnlUsd;
    console.log(
      `${t.side} entry $${t.entryPrice.toFixed(2)} (round ${t.entryRound}) -> exit $${t.exitPrice.toFixed(2)} (round ${t.exitRound}) | P&L $${t.pnlUsd.toFixed(2)}`
    );
  }
  console.log(`Total simulated trades: ${trades.length} | Total simulated P&L: $${totalPnl.toFixed(2)}`);
  console.log("===================================================\n");

  const out = {
    generatedAt: new Date().toISOString(),
    feed: FEED,
    thresholdBps: THRESHOLD_BPS,
    notionalUsd: NOTIONAL_USD,
    roundsFetched: rounds.length,
    maxMoveBpsObserved: maxMoveBps,
    uniswapWethUsdSpot: uniswapWethUsd,
    trades,
    totalPnlUsd: totalPnl,
  };
  writeFileSync(new URL("./last-run-results.json", import.meta.url), JSON.stringify(out, null, 2));
  console.log("Wrote scripts/paper-trader/last-run-results.json");
}

main().catch((err) => {
  console.error("paper-trader fatal error:", err);
  process.exit(1);
});
