// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PublicAgentBudget} from "../src/public-agent-budget.sol";

/// @notice Arc MAINNET deploy script. Intentionally inert during Phase 2.
/// @dev SAFETY: this contract does not run unless a human explicitly opts in, by
///      passing ALL THREE flags on the command line:
///
///        forge script script/DeployMainnet.s.sol:DeployMainnet \
///          --rpc-url $ARC_MAINNET_RPC_URL \
///          --keystore deployer \
///          --broadcast \
///          --confirm-mainnet
///
///      Two independent guards:
///
///      1. `RUN_MAINNET` is false in code. Until a human edits it to true, `run()`
///         reverts before any state is read or any transaction is constructed. The
///         default state of this file is safe.
///      2. Even with RUN_MAINNET true, `block.chainid` must equal 5042. Pointing this
///         at the testnet RPC reverts, so an RPC mix-up cannot broadcast to testnet
///         while pretending to be a mainnet deploy.
///
///      Also refuses if the RPC flag is absent: `vm.envOr("ARC_MAINNET_RPC_URL", "")`
///      must be non-empty, because the documented mainnet RPC is empty in .env
///      until Phase 6.
contract DeployMainnet is Script {
    bool internal constant RUN_MAINNET = false;

    /// @dev Arc mainnet chain id, per docs.arc.io.
    uint256 internal constant ARC_MAINNET_CHAIN_ID = 5042;

    /// @dev Arc enforces a 20 Gwei floor on maxFeePerGas.
    uint256 internal constant MAX_FEE_PER_GAS = 25 gwei;

    address internal constant AGENT = address(0);
    address internal constant SELLER = address(0);

    /// @dev 18-decimal native USDC base units.
    uint256 internal constant ONE_USDC = 1e18;

    function run() external {
        require(
            RUN_MAINNET,
            "MAINNET DISABLED: set RUN_MAINNET=true, pass --rpc-url, --keystore, --broadcast, --confirm-mainnet"
        );
        require(
            block.chainid == ARC_MAINNET_CHAIN_ID,
            "refusing to run: not Arc mainnet (expected chain id 5042)"
        );
        require(
            bytes(vm.envOr("ARC_MAINNET_RPC_URL", string(""))).length != 0,
            "ARC_MAINNET_RPC_URL is empty: mainnet RPC not enabled yet"
        );

        // Configuration is deliberately unset. Mainnet deploy is out of scope for
        // Phase 2 and must be set deliberately at the time it is used.
        require(AGENT != address(0) && SELLER != address(0), "agent/seller not set");

        vm.startBroadcast();
        address deployer = msg.sender;

        PublicAgentBudget budget = new PublicAgentBudget();
        require(budget.owner() == deployer, "owner should be the deployer");

        budget.setAgent(AGENT);
        budget.setAllowlist(SELLER, true);
        budget.setCaps(ONE_USDC, 5 * ONE_USDC);
        budget.deposit{value: 10 * ONE_USDC}();

        vm.stopBroadcast();

        console.log("deployed     ", address(budget));
        console.log("owner        ", budget.owner());
        console.log("agent        ", budget.agent());
        console.log("seller       ", SELLER);
        console.log("perTxCap     ", budget.perTxCap());
        console.log("dailyCap     ", budget.dailyCap());
        console.log("balance      ", budget.balance());
    }
}