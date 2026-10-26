# On-chain address verification (Base Sepolia, chainId 84532)

Checked live on 2026-10-26 against RPC https://sepolia.base.org with `cast code` (bytecode
present = contract is deployed/live) and `cast call` (sane return value = contract is
functioning as expected). Raw commands are reproducible, see below.

| Contract | Address | Verified |
|---|---|---|
| Aave V3 PoolAddressesProvider | 0xE4C23309117Aa30342BFaae6c95c6478e0A4Ad00 | ✅ code present, matches aave-address-book |
| Aave V3 Pool | 0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27 | ✅ code present; `ADDRESSES_PROVIDER()` returns the provider above |
| Aave V3 Oracle | 0x943b0dE18d4abf4eF02A85912F8fc07684C141dF | ✅ `getAssetPrice(WETH)` returns ~$2300 (8dp), sane |
| Aave V3 Protocol Data Provider | 0xBc9f5b7E248451CdD7cA54e717a2BFe1F32b566b | ✅ `getReserveConfigurationData` returns sane WETH/USDC config |
| WETH (Base predeploy) | 0x4200000000000000000000000000000000000006 | ✅ real canonical Base WETH9, confirmed via aave-address-book |
| Test USDC | 0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f | ✅ `name()/symbol()/decimals()` = "USD Coin"/"USDC"/6 |
| USDC variable debt token | 0xFB3e85601b7fEb3691bbb8779Ef0E1069E347204 | ✅ used directly in the fork test to read exact debt |
| Aave testnet Faucet | 0xD9145b5F45Ad4519c7ACcD6E0A4A82e83bB8A6Dc | ✅ `mint(token,to,amount)` callable by anyone (is the token's owner) — confirmed live with a real `cast call` mint of 1,000,000 USDC |
| Chainlink ETH/USD feed | 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1 | ✅ `latestRoundData()` returns a live, sane ETH price; matches Aave's own `WETH_ORACLE` mapping in aave-address-book (cross-check) |
| Uniswap V3 Factory | 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24 | ✅ code present; `getPool(WETH,USDC,3000)` returns a real pool with live liquidity |
| Uniswap V3 WETH/USDC 0.3% pool | 0x92266210FacF124f190fbad79AA230dfB85926Ce | ✅ `liquidity()` = ~4.96e12 (non-zero, tradeable, but THIN — see README "known limitations") |
| Uniswap V3 SwapRouter02 | 0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4 | ✅ code present; used successfully in the fork test to repay the flash loan |

## Correction vs. the address list we were initially given
The task brief's "Uniswap V3 Router" address `0x492E6456D9528771018DeB9E87ef7750EF184104` is live
on-chain, but it is Uniswap's **UniversalRouter**, not the classic `ISwapRouter`/`SwapRouter02`
(different ABI — UniversalRouter takes opaque encoded commands, not `exactOutputSingle`/
`exactInputSingle` structs). For a contract that needs to call `exactOutputSingle` directly
(like `FlashLoanLiquidator`), the correct address is **SwapRouter02**:
`0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4` (source: developers.uniswap.org Base Sepolia
deployments page). That's the address actually wired into the contracts and used in the passing
fork test.

## Raw verification commands (reproducible)
```bash
RPC=https://sepolia.base.org
cast code 0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27 --rpc-url $RPC   # Aave Pool, non-empty
cast call 0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27 "ADDRESSES_PROVIDER()(address)" --rpc-url $RPC
cast call 0x943b0dE18d4abf4eF02A85912F8fc07684C141dF "getAssetPrice(address)(uint256)" 0x4200000000000000000000000000000000000006 --rpc-url $RPC
cast call 0xD9145b5F45Ad4519c7ACcD6E0A4A82e83bB8A6Dc "mint(address,address,uint256)(uint256)" 0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f 0x000000000000000000000000000000000000dEaD 1000000 --rpc-url $RPC
cast call 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24 "getPool(address,address,uint24)(address)" 0x4200000000000000000000000000000000000006 0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f 3000 --rpc-url $RPC
```
