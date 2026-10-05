// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {PublicAgentBudget} from "../../src/public-agent-budget.sol";

/// @notice A seller whose receive() always reverts, so it can never be paid.
contract RevertingSeller {
    error RefusedPayment();

    receive() external payable {
        revert RefusedPayment();
    }
}

/// @notice A well-behaved seller that records what it was paid.
contract RecordingSeller {
    uint256 public received;
    uint256 public calls;

    receive() external payable {
        received += msg.value;
        calls += 1;
    }
}

/// @notice A seller that tries to re-enter the budget from inside receive().
/// @dev Exercises the two realistic attacks: calling spend() again as the seller, and
///      calling withdraw() as the seller. Both should fail, and the observations are
///      recorded so the test can assert on them.
contract ReentrancySeller {
    enum Outcome {
        NotReentered,
        ReenteredSuccessfully,
        Blocked
    }

    PublicAgentBudget public immutable budget;

    bool public attackSpend;
    bool public attackWithdraw;

    Outcome public spendOutcome;
    Outcome public withdrawOutcome;
    bytes public spendRevertData;
    uint256 public spentTodaySeenDuringCallback;
    uint256 public windowStartSeenDuringCallback;
    uint256 public received;
    uint256 public calls;

    constructor(PublicAgentBudget _budget) {
        budget = _budget;
    }

    function setAttack(bool _spend, bool _withdraw) external {
        attackSpend = _spend;
        attackWithdraw = _withdraw;
    }

    receive() external payable {
        received += msg.value;
        calls += 1;

        // Read the state the outer call was supposed to update first. Checks-effects-
        // interactions means these are already the post-spend values.
        spentTodaySeenDuringCallback = budget.spentToday();
        windowStartSeenDuringCallback = budget.windowStart();

        if (attackSpend) {
            // Try to spend again from inside the callback. At this point msg.sender is
            // this seller contract, not the agent, so this must revert with NotAgent().
            // Amount is 1 so it would otherwise fit inside any sane cap.
            try budget.spend(address(this), 1) {
                spendOutcome = Outcome.ReenteredSuccessfully;
            } catch (bytes memory data) {
                spendOutcome = Outcome.Blocked;
                spendRevertData = data;
            }
        }

        if (attackWithdraw) {
            try budget.withdraw(address(this), 1) {
                withdrawOutcome = Outcome.ReenteredSuccessfully;
            } catch {
                withdrawOutcome = Outcome.Blocked;
            }
        }
    }
}

/// @notice An agent that is ALSO the allowlisted seller, so it re-enters `spend()` from
///         inside its own `receive()`.
/// @dev This is the case where `onlyAgent` is not a defence on its own: the re-entrant
///      call comes from the agent address itself, so it passes that check. What keeps it
///      safe is that `spentToday` and `windowStart` are written before the seller is
///      called, so the nested spend is charged against the already-updated counters and
///      the caps still hold.
contract ReentrantAgent {
    PublicAgentBudget public immutable budget;

    bool public armed;
    /// @notice 1 if the nested spend succeeded, 2 if it reverted, 0 if never attempted.
    uint256 public innerOutcome;
    uint256 public innerSpentToday;
    uint256 public innerBalance;
    uint256 public received;
    uint256 public calls;

    constructor(PublicAgentBudget _budget) {
        budget = _budget;
    }

    /// @notice Spend `amount` to itself, arming a nested spend of 1 USDC.
    function attack(uint256 amount) external {
        armed = true;
        budget.spend(address(this), amount);
    }

    receive() external payable {
        received += msg.value;
        calls += 1;

        if (armed) {
            // Disarm first so the nested payment cannot recurse indefinitely.
            armed = false;
            try budget.spend(address(this), 1e18) {
                innerOutcome = 1;
                innerSpentToday = budget.spentToday();
                innerBalance = address(this).balance;
            } catch {
                innerOutcome = 2;
            }
        }
    }
}

/// @notice Minimal 6-decimal ERC-20, used only to demonstrate the 10^12 gap between the
///         6-decimal ERC-20 USDC representation and native USDC's 18 decimals.
/// @dev Not part of the budget contract. The budget never touches an ERC-20; this mock
///      exists so the decimals test compares real numbers instead of asserting a
///      constant.
contract MockUSDC6 {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
