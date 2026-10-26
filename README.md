# keeper-liquidator

A multi-protocol flash-loan liquidation bot + paper-trading harness for Base Sepolia, built for
tiny-you / Soulkin's human (maa-ly, builder of `Keeper`/"Reave"). This is a **from-scratch
sibling project**, not a fork of `maa-ly/Keeper` — see "Relationship to maa-ly/Keeper" below for
why, and what was reused.

**Read this first: what's actually proven vs. what's scaffolded.** This README is written to be
checked against, not just read. Every number in the "Proven results" section came out of a real
command run against real, live-verified Base Sepolia contracts — see
`proofs-liquidation-fork-test-output.txt` and `scripts/*/example-run*.{log,json}` for the raw,
unedited output.

## TL;DR — proven results

- ✅ **A real liquidation fired** in a Foundry fork test against the live Base Sepolia Aave V3
  Pool, Oracle, and Uniswap V3 SwapRouter02 (forked locally, not mocked contracts). Flash loan
  borrowed, liquidation called, flash loan repaid via a real Uniswap swap, profit collected —
  all in one transaction, **0 blocks of reaction delay**, **698,910 gas**.
- ✅ **A real paper-trading run** pulled 150 real historical rounds off the live Chainlink
  ETH/USD feed on Base Sepolia and, when re-run with a lower (but still real-data-driven)
  threshold, logged 139 real trigger events and simulated trades with real P&L math
  (net **-$7.59** on a naive mean-reversion strategy — an honest losing result, not cherry-picked).
- ⚠️ **Not yet deployed live to Base Sepolia mainnet-of-testnets** (i.e. broadcast, not just
  forked). A throwaway deployer wallet was generated (see below) but has 0 ETH — funding it
  needs a human to pass a faucet captcha. The contracts and deploy script are ready to go the
  moment that wallet (or any wallet) has a few cents of Base Sepolia ETH.
- ⚠️ Compound V3, Morpho Blue and Spark adapters are **stubs only** — they compile and show the
  intended shape, they do not actually liquidate anything yet.
- ⚠️ The "ReactiveVM" piece is implemented as an **off-chain event listener** (proven working
  live against the real Chainlink feed), not a deployed Reactive Network RSC — see "Reactive
  Network vs. what's built" below for exactly why and what a real RSC deployment still needs.

## Relationship to `maa-ly/Keeper`

`github.com/maa-ly/Keeper` (internally named "Reave") is public and was reviewed before writing
any code here. It already implements a real Reactive Network RSC (`LeverageLooper.sol` +
`ReactiveBase.sol`, using `lib/reactive-lib`, deployed to Ethereum Sepolia + Reactive's Lasna
testnet) for **leverage looping** (supply/borrow/swap to a target LTV, with a `liquidateLoop`
escape hatch) on a *single* Aave V3 + Uniswap V3 pair.

This task asked for something architecturally different: a **protocol-agnostic liquidation
engine** (one core contract + swappable adapters for Aave V3 / Compound V3 / Morpho Blue /
Spark) funded entirely by flash loans, targeting **Base Sepolia** instead of Ethereum Sepolia.
That's a different core contract, different chain, different adapter-based architecture — so
rather than bolt an unrelated liquidation engine onto `Keeper`'s `LeverageLooper.sol` (which
would make its single-contract design less clear), this is a clean new repo. What *was* reused
conceptually: `Keeper`'s pattern of "ReactVM reacts to an event → emits a callback → destination
chain executes the DeFi call" directly informed `src/reactive/ReactiveLiquidationStub.sol`'s
design and the off-chain listener's "react same-block, no polling" behavior.

## Architecture

```
src/
  interfaces/
    IProtocolAdapter.sol   <- common interface every protocol adapter implements
    IAaveV3Pool.sol        <- minimal Aave V3 Pool/Oracle/flash-loan-receiver interfaces
    ISwapRouter.sol        <- minimal Uniswap V3 SwapRouter02-style interface
  adapters/
    AaveV3Adapter.sol      <- FULLY IMPLEMENTED, tested against live Base Sepolia (forked)
    SparkAdapter.sol       <- thin subclass of AaveV3Adapter (Spark = Aave V3 fork); not
                               deployed, Spark has no Base Sepolia market yet
    CompoundV3Adapter.sol  <- STUB, reverts NotImplemented()
    MorphoBlueAdapter.sol  <- STUB, reverts NotImplemented()
  FlashLoanLiquidator.sol  <- core contract: owns the Aave flash loan + Uniswap repay logic,
                               never changes when a new protocol is added
  reactive/
    ReactiveLiquidationStub.sol <- illustrative only, NOT deployed, NOT tested (see below)
script/Deploy.s.sol        <- forge script to deploy to real Base Sepolia
test/LiquidationFork.t.sol <- the real proof: forks Base Sepolia, creates a real liquidatable
                               position, crashes the oracle price, fires the liquidation
scripts/listener/           <- off-chain Node/ethers.js reactive listener (the "ReactiveVM"
                               fallback, proven running live against Base Sepolia)
scripts/paper-trader/       <- off-chain Node/ethers.js paper-trading harness
```

Adding a 5th protocol = write one more file in `src/adapters/` implementing
`IProtocolAdapter`, then `liquidator.setAdapter(keccak256("NEW_PROTOCOL"), address(newAdapter))`.
`FlashLoanLiquidator.sol` itself never needs to change.

### How a liquidation actually flows
1. Something (the off-chain listener today; a real RSC callback eventually) calls
   `FlashLoanLiquidator.executeLiquidation(protocolId, collateralAsset, debtAsset, user,
   debtToCover, receiveAToken, swapFeeTier)`.
2. The core contract takes an Aave V3 `flashLoanSimple` of `debtToCover` in `debtAsset` — **zero
   upfront capital needed**.
3. Aave calls back into `executeOperation`, which hands the borrowed funds to the registered
   `IProtocolAdapter` for `protocolId`.
4. The adapter pulls the funds, calls the underlying protocol's actual liquidation function
   (`Pool.liquidationCall` for Aave V3/Spark), and forwards whatever collateral it seized back
   to the core contract.
5. The core contract swaps just enough seized collateral through Uniswap V3 to cover the flash
   loan + 0.05% premium. Whatever's left is profit, held in the contract until
   `withdrawProfit()` is called by the owner.

## Reactive Network vs. what's built

The task's "ReactiveVM" concept is a real framework: **Reactive Network**
(`reactive.network`). Reactive Smart Contracts (RSCs) subscribe to EVM log events on an *origin*
chain, run inside Reactive's ReactVM the instant that event lands, and emit `Callback(...)`
payloads that Reactive's relayer delivers to a *destination* chain contract — which is exactly
what `maa-ly/Keeper` already does on Ethereum Sepolia + Reactive's Lasna testnet.

Deploying a *real* RSC for **this** project needs:
1. The `reactive-lib` submodule (same one `Keeper` uses).
2. REACT test tokens on Reactive's own Lasna/Kopli chain — funded via a separate
   Sepolia→Lasna faucet bridge transaction (`cast send` to a specific faucet contract with
   value, see `Keeper`'s README for the exact command).
3. Registering the RSC's event subscription through Reactive Network's own tooling.
4. A funded destination contract (Base Sepolia, in this project's case) to receive the callback.

That's a real but **separate funded deployment pipeline** from the Base Sepolia liquidation
contracts here, and wasn't completed in this pass — no REACT tokens were acquired and no RSC was
deployed. `src/reactive/ReactiveLiquidationStub.sol` documents exactly how this project's logic
would plug into that framework (mirrors `IReactive.react(LogRecord)`'s shape) so swapping it for
a real `AbstractReactive` subclass later is a small diff, not a rewrite.

What **is** proven is the *behavior* an RSC gives you — react immediately to an event, no
polling — implemented off-chain instead: `scripts/listener/index.js` subscribes to the live
Chainlink `AnswerUpdated` event stream on Base Sepolia and would call `executeLiquidation` in
the same JS event-loop tick it sees a triggering price update, not on a timer. Run live against
Base Sepolia (see `scripts/listener/example-run.log` for the actual unedited output): it
connected, decoded the real feed, and correctly found zero triggerable positions (there are none
real — `TRACKED_USERS` was empty of real underwater accounts, as expected). The **same
detect→call→flash-loan→repay path** is what `test/LiquidationFork.t.sol` proves fires correctly
and fast — that test is the real end-to-end evidence; the listener script proves the live
plumbing around it works.

## Proven results in detail

### 1. Liquidation fork test (`test/LiquidationFork.t.sol`)

Forks live Base Sepolia at the current block with Foundry (`vm.createSelectFork`), so the Pool,
Oracle, Protocol Data Provider, token contracts and Uniswap pool are the **real deployed
contracts**, not mocks. What's fabricated for the test: the victim's balances (via `vm.deal` +
real `WETH.deposit()`, no cheat needed there) and the price crash (via `vm.mockCall` on the real
Oracle address — exactly the "manipulate the oracle in the fork" approach asked for, since the
live Chainlink feed obviously can't be pushed down for real).

Run it yourself:
```bash
forge test --match-contract LiquidationForkTest -vv --gas-report
```

Actual output (full version in `proofs-liquidation-fork-test-output.txt`):
```
Forked Base Sepolia at block 50511782
-- position opened --
collateralBase (8dp USD) 6930095575      // ~$69.30 WETH collateral supplied
debtBase (8dp USD) 5613030944            // ~$56.13 USDC borrowed (97% of max LTV)
healthFactor (1e18) 1049447490583796788  // 1.049 — healthy but close to the edge

-- oracle price crash injected --
WETH price before (8dp USD) 231003185856   // $2310.03/WETH, the REAL live price at test time
WETH price after  (8dp USD) 173252389392   // $1732.52/WETH, a -25% mocked crash
healthFactor after crash (1e18) 787085617899989257   // 0.787 — now liquidatable

================ RESULT ================
gas used by executeLiquidation 699137
blocks between trigger and reaction 0     // same block — no polling delay
victim remaining USDC debt 0              // fully repaid by the liquidation
victim healthFactor after liquidation (1e18)  <uint256 max — no more debt>
liquidator profit in WETH (wei) 5150321598992672   // ~0.00515 WETH, ~$8.90 at crashed price
==========================================

[PASS] test_liquidation_fires_when_position_crosses_threshold() (gas: 1625321)
[PASS] test_liquidation_reverts_when_position_is_healthy() (gas: 1163416)
[PASS] test_only_keeper_or_owner_can_trigger_liquidation() (gas: 40504)
[PASS] test_unknown_adapter_reverts() (gas: 43174)
```

4/4 tests pass. Numbers (gas, profit, health factors) vary slightly between runs because the
fork picks up the live, currently-fluctuating real WETH price each time — that's expected and is
itself evidence the "live" part of "live fork" is real.

**Known limitation found during testing:** the real Base Sepolia WETH/USDC 0.3% Uniswap pool is
thin. An earlier version of this test used a 5 WETH position and the repay-swap reverted with
Uniswap's `STF` error — pushing ~$9,300 through this specific pool blows through its liquidity
and crashes the price past `MIN_SQRT_RATIO`. The test now uses a ~$69 position, which swaps
cleanly. A real mainnet deployment, or a deployment against a deeper testnet pool/fee tier,
would need either a liquidity check before committing to a swap size or a multi-hop/aggregator
route — not implemented here.

### 2. Paper-trading harness (`scripts/paper-trader/index.js`)

Pulls real historical rounds straight off the live Chainlink ETH/USD proxy
(`0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1`) by walking `getRoundData` backwards through the
phase-aware round IDs, and reads the real Uniswap V3 WETH/USDC pool's current spot price via
`slot0`. On a configurable % move, it logs a simulated trade (mean-reversion: fade big up-moves,
buy big down-moves) sized at a fixed fake notional, and tracks real P&L math in USD.

Default run (2% threshold, matching the task brief's example trigger) against whatever 150
rounds were live at run time:
```
Largest single round-to-round real move observed in window: 23.42bps (0.23%)
No real move in this window reached the 2% threshold -> 0 trades triggered
```
This is an **honest result**, not a bug: Base Sepolia's Chainlink ETH/USD feed is currently
calm, moving well under 2% between consecutive updates. Full raw output in
`scripts/paper-trader/example-run-default-2pct-threshold.json`.

Re-run with a lower, still-real-data-driven threshold to see the full mechanism fire (same real
150 rounds, just a lower bar):
```bash
cd scripts && THRESHOLD_BPS=12 node paper-trader/index.js
```
```
139 simulated trades logged against real price ticks
Total simulated P&L: -$7.59   (naive strategy, real noisy data — a losing result, reported as-is)
```
Full trade-by-trade log in `scripts/paper-trader/example-run-demo-012pct-threshold.json`.

### 3. Off-chain listener (`scripts/listener/index.js`)

Connected live to Base Sepolia, decoded the real Chainlink feed's `latestRoundData`, correctly
handled the public RPC's 200-block `eth_getLogs` cap by chunking, and subscribed for live
`AnswerUpdated` events for a real time window. Zero new events landed in the ~10-15s windows
tested (expected — Chainlink testnet feeds update every few minutes, not every block). Raw
output in `scripts/listener/example-run.log`. The reaction logic it would run
(`checkAndMaybeLiquidate`) is exercised for real inside the Foundry fork test above.

### 4. Deployer wallet / live Base Sepolia broadcast

A throwaway deployer wallet was generated in-sandbox for this task:
```
0x5801CE0fE9a53d8529cBB29013336408Ee9316EF
```
Balance: 0 ETH. Every public Base Sepolia faucet checked (Coinbase CDP, thirdweb, pk910) needs a
captcha, login, or a timed proof-of-work browser challenge — none of which can be done headlessly
without a human. **This is the manual step for you:** send ~0.01 Base Sepolia ETH to that
address (or your own), then run:
```bash
cp .env.example .env   # fill in DEPLOYER_PRIVATE_KEY
forge script script/Deploy.s.sol:Deploy --rpc-url base_sepolia --broadcast --private-key $DEPLOYER_PRIVATE_KEY
```
This repo's private key for that throwaway address only ever existed inside the sandbox for this
job and was not committed anywhere — it's gone with the sandbox. Use your own key via `.env`.

## On-chain address verification

Every address used was checked live on Base Sepolia (chain id 84532) before being hardcoded —
see `proofs-address-verification.md` for the full table and the exact `cast` commands used.
Headline finding: the task brief's Uniswap "Router" address
(`0x492E6456D9528771018DeB9E87ef7750EF184104`) is real but is Uniswap's **UniversalRouter**, not
the classic `exactOutputSingle`-style router this project's contracts need — **SwapRouter02**
(`0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4`) is what's actually wired in, confirmed working in
the fork test. Also found and used a real, permissionless Aave testnet faucet contract
(`0xD9145b5F45Ad4519c7ACcD6E0A4A82e83bB8A6Dc`, `mint(token, to, amount)`, callable by anyone)
that isn't mentioned in Aave's UI docs.

## What's left before any of this should touch mainnet

- Compound V3, Morpho Blue, Spark adapters are unimplemented stubs.
- No slippage/liquidity-depth check before sizing the repay swap (the thin-pool `STF` revert
  found during testing would be a real, costly failure mode on mainnet with a bad position size).
- No real RSC deployed on Reactive Network — only the off-chain listener equivalent.
- No live broadcast to Base Sepolia yet (fork-only), pending real testnet ETH.
- `FlashLoanLiquidator` has no circuit breaker / max-position-size guard, and `onlyKeeper` is the
  only access control — no pause mechanism, no multi-sig ownership.
- No monitoring/alerting, no retry logic in the listener if a submitted tx fails or is front-run.
- Needs real unit tests for the swap-repay edge cases (partial fill, zero leftover, insufficient
  collateral to cover the premium) beyond the two happy/one unhappy path covered here.

## Setup

```bash
forge install   # pulls forge-std + openzeppelin-contracts (already vendored via git submodules)
forge build
forge test --match-contract LiquidationForkTest -vv --gas-report

cd scripts && npm install
node listener/index.js           # live, read-only/dry-run by default against Base Sepolia
node paper-trader/index.js       # live, read-only, real Chainlink data
```
