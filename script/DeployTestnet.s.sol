// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PublicAgentBudget} from "../src/public-agent-budget.sol";

/// @notice Deploys PublicAgentBudget to Arc TESTNET and configures it in the same run,
///         so the deployed contract is immediately usable for the demo.
/// @dev Signs with the encrypted Foundry keystore (`--keystore deployer`), never a
///      plaintext key. Refuses to run anywhere other than Arc testnet chain 5042002.
/// @dev Gas: Arc enforces a 20 Gwei floor on maxFeePerGas; transactions below the
///      floor get dropped from the mempool with no error receipt. This script relies
///      on forge's own EIP-1559 estimation rather than hardcoding a fee, because
///      simulation showed forge estimating 46-53 Gwei max fee (20 Gwei base plus a
///      sizeable priority fee), comfortably above the floor. Pinning a low constant
///      like 25 Gwei could have been rejected if the base fee rose before inclusion.
contract DeployTestnet is Script {
    /// @dev Arc testnet chain id, verified live against https://rpc.testnet.arc.io
    ///      (eth_chainId returned 0x4cef52) and in docs.arc.io.
    uint256 internal constant ARC_TESTNET_CHAIN_ID = 5042002;

    /// @dev The keystore account that must sign this deploy. Asserted against the
    ///      on-chain `owner()` rather than read from `msg.sender`: inside a broadcast
    ///      the script's own `msg.sender` is the default foundry sender
    ///      (0x1804c8AB...), not the signer, so forge rejects scripts that use it.
    address internal constant DEPLOYER = 0xeF09C1330687CE217Da48876de776a562bFF15c8;

    address internal constant AGENT = 0xAb4F16BB27Ffa7FAf5c68DFAB3881883DB1ba984;
    address internal constant SELLER = 0x6c652c3E0174FBb383b5853388d1490A2da6Df23;

    /// @dev 18-decimal native USDC base units. 1 USDC = 1e18.
    uint256 internal constant ONE_USDC = 1e18;

    function run() external {
        // Guard before anything else. A misconfigured --rpc-url must fail here, not
        // broadcast to the wrong chain.
        require(
            block.chainid == ARC_TESTNET_CHAIN_ID,
            "refusing to run: not Arc testnet (expected chain id 5042002)"
        );

        require(AGENT != address(0) && SELLER != address(0), "agent/seller not set");

        // No private key is read here. `forge script --keystore <path> --broadcast`
        // signs with the encrypted keystore, so the key never touches this repo.
        vm.startBroadcast();

        PublicAgentBudget budget = new PublicAgentBudget();
        require(budget.owner() == DEPLOYER, "owner should be the deployer");

        // Rules first, then money.
        budget.setAgent(AGENT);
        budget.setAllowlist(SELLER, true);
        budget.setCaps(ONE_USDC, 5 * ONE_USDC); // per-tx 1 USDC, daily 5 USDC
        budget.deposit{value: 10 * ONE_USDC}(); // fund with 10 USDC

        vm.stopBroadcast();

        console.log("deployed     ", address(budget));
        console.log("owner        ", budget.owner());
        console.log("agent        ", budget.agent());
        console.log("seller       ", SELLER);
        console.log("perTxCap     ", budget.perTxCap());
        console.log("dailyCap     ", budget.dailyCap());
        console.log("balance      ", budget.balance());
        console.log("remainingDail", budget.remainingDaily());
    }
}