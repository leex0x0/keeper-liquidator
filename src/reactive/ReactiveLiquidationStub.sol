// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ReactiveLiquidationStub (ILLUSTRATIVE ONLY — NOT DEPLOYED, NOT TESTED)
/// @notice This project's "ReactiveVM" concept maps directly onto Reactive Network
///         (https://reactive.network): Reactive Smart Contracts (RSCs) subscribe to EVM log
///         events on an *origin* chain, run `react(LogRecord)` inside the ReactVM the instant
///         that event lands, and emit `Callback(...)` payloads that Reactive Network's relayer
///         delivers to a contract on a *destination* chain — no polling, no cron job, the
///         callback fires in reaction to the origin event. This is the exact same pattern the
///         human's existing `maa-ly/Keeper` repo (the "Reave" project) already uses via
///         `lib/reactive-lib`'s `AbstractReactive` + `IReactive`, deployed to the Lasna testnet.
///
///         Real deployment of an RSC needs: (1) the `reactive-lib` submodule, (2) REACT test
///         tokens on Reactive's Lasna/Kopli testnet (funded via a Sepolia->Lasna faucet bridge
///         tx), (3) subscribing the RSC to the origin chain's event signature through RN
///         tooling, and (4) a funded destination contract to receive the callback. That's a
///         real but separate deployment+funding flow from the Base Sepolia liquidation
///         contracts in this repo, and wasn't done in this pass — wiring it up is listed as
///         follow-up work in the README.
///
///         What IS proven in this repo is the *behavior* an RSC would have: `scripts/listener`
///         is an off-chain ethers.js process that subscribes to live Base Sepolia event logs
///         and calls `FlashLoanLiquidator.executeLiquidation` the instant a watched position
///         crosses its threshold, in the same block it detects the trigger, no fixed-interval
///         polling. That's the same "react immediately to an event" guarantee an RSC gives,
///         just enforced off-chain instead of inside Reactive Network's ReactVM.
///
///         Shape below mirrors reactive-lib's `IReactive.react` signature so swapping this stub
///         for a real `AbstractReactive` subclass later is a small diff, not a rewrite.
interface ILogRecordLike {
    struct LogRecord {
        uint256 chain_id;
        address _contract;
        uint256 topic_0;
        uint256 topic_1;
        uint256 topic_2;
        uint256 topic_3;
        bytes data;
        uint256 block_number;
        uint256 op_code;
        uint256 block_hash;
        uint256 tx_hash;
        uint256 log_index;
    }
}

contract ReactiveLiquidationStub is ILogRecordLike {
    event Callback(uint256 indexed destChainId, address indexed destContract, uint64 gasLimit, bytes payload);

    address public destLiquidator;
    uint256 public destChainId;

    /// @dev In a real RSC this would be `rnOnly` (reactive-lib modifier restricting the call to
    ///      Reactive Network's internal router). Left open here since this stub is never
    ///      deployed as an actual RSC.
    function setDestination(address liquidator, uint256 chainId) external {
        destLiquidator = liquidator;
        destChainId = chainId;
    }

    /// @notice Illustrative only. A real RSC would decode `log.data` for the subscribed event
    ///         (e.g. Chainlink `AnswerUpdated`, or an Aave `ReserveDataUpdated`/`Borrow`), check
    ///         whether the affected account is now underwater, and emit `Callback` with
    ///         calldata for `FlashLoanLiquidator.executeLiquidation`.
    function react(LogRecord calldata log) external {
        bytes memory payload = abi.encodeWithSignature(
            "executeLiquidation(bytes32,address,address,address,uint256,bool,uint24)",
            bytes32(0),
            address(0),
            address(0),
            address(uint160(log.topic_1)),
            uint256(0),
            false,
            uint24(3000)
        );
        emit Callback(destChainId, destLiquidator, 2_000_000, payload);
    }
}
