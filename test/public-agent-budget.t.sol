// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PublicAgentBudget} from "../src/public-agent-budget.sol";
import {
    RevertingSeller,
    RecordingSeller,
    ReentrancySeller,
    ReentrantAgent,
    MockUSDC6
} from "./mocks/Mocks.sol";

/// @notice Tests for PublicAgentBudget.
/// @dev Covers every custom error, the daily-window reset and remainingDaily() after
///      expiry, pause blocking spend, withdraw touching only unspent funds, a seller that
///      reverts, a seller that re-enters, the 18-vs-6 decimal gap, and fuzzed caps.
contract PublicAgentBudgetTest is Test {
    PublicAgentBudget internal budget;

    address internal owner = address(this);
    address internal agent = makeAddr("agent");
    address internal stranger = makeAddr("stranger");
    address internal seller = makeAddr("seller");
    address internal other = makeAddr("other");

    uint256 internal constant PER_TX = 10e18; // 10 USDC at 18 decimals
    uint256 internal constant DAILY = 50e18; // 50 USDC at 18 decimals
    uint256 internal constant DEPOSIT = 500e18;

    /// @dev One native USDC at 18 decimals, and the 10^12 gap to the 6-decimal ERC-20.
    uint256 internal constant ONE_USDC = 10 ** 18;

    function setUp() public {
        budget = new PublicAgentBudget();
        budget.setAgent(agent);
        budget.setAllowlist(seller, true);
        budget.setCaps(PER_TX, DAILY);
        vm.deal(owner, 1000e18);
        // The pranked actors need their own balance, otherwise a call carrying value
        // fails the EVM balance check before it ever reaches the contract.
        vm.deal(stranger, 100e18);
        vm.deal(other, 100e18);
        vm.prank(owner);
        budget.deposit{value: DEPOSIT}();
    }

    /// @dev The owner is this test contract, so it has to be able to receive a withdrawal.
    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                              INITIAL STATE
    //////////////////////////////////////////////////////////////*/

    function test_InitialState() public view {
        assertEq(budget.owner(), owner, "owner");
        assertEq(budget.agent(), agent, "agent");
        assertEq(budget.perTxCap(), PER_TX, "perTxCap");
        assertEq(budget.dailyCap(), DAILY, "dailyCap");
        assertEq(budget.spentToday(), 0, "spentToday");
        assertEq(budget.windowStart(), 0, "windowStart");
        assertEq(budget.windowEnd(), 0, "windowEnd");
        assertFalse(budget.isPaused(), "paused");
        assertEq(budget.balance(), DEPOSIT, "balance");
        assertTrue(budget.isAllowlisted(seller), "seller allowlisted");
        assertFalse(budget.isAllowlisted(stranger), "stranger not allowlisted");
    }

    /*//////////////////////////////////////////////////////////////
                              HAPPY PATHS
    //////////////////////////////////////////////////////////////*/

    function test_Deposit_OwnerOnly() public {
        vm.expectRevert("not owner");
        vm.prank(stranger);
        budget.deposit{value: 1e18}();
    }

    function test_Spend_HappyPath() public {
        vm.prank(agent);
        budget.spend(seller, 1e18);

        assertEq(budget.balance(), DEPOSIT - 1e18, "balance drops by amount");
        assertEq(budget.spentToday(), 1e18, "spentToday accrues");
        assertEq(budget.remainingDaily(), DAILY - 1e18, "remainingDaily drops");
        assertGt(budget.windowStart(), 0, "window opened on first spend");
    }

    function test_Spend_CreatesWindowOnFirstSpend() public {
        assertEq(budget.windowStart(), 0, "no window before first spend");

        vm.prank(agent);
        budget.spend(seller, 1e18);

        assertEq(budget.windowStart(), block.timestamp, "windowStart is now");
        assertEq(budget.windowEnd(), block.timestamp + 1 days, "windowEnd is +1 day");
    }

    function test_Spend_EmitsSpent() public {
        vm.expectEmit(true, false, false, true, address(budget));
        emit PublicAgentBudget.Spent(seller, 2e18, 2e18, block.timestamp);

        vm.prank(agent);
        budget.spend(seller, 2e18);
    }

    function test_SetCaps_EmitsCapsSet() public {
        vm.expectEmit(false, false, false, true, address(budget));
        emit PublicAgentBudget.CapsSet(1e18, 2e18);

        budget.setCaps(1e18, 2e18);
    }

    function test_SetAllowlist_EmitsAllowlistSet() public {
        vm.expectEmit(true, false, false, true, address(budget));
        emit PublicAgentBudget.AllowlistSet(stranger, true);

        budget.setAllowlist(stranger, true);
        assertTrue(budget.isAllowlisted(stranger), "now allowlisted");
    }

    function test_Deposit_EmitsDeposited() public {
        uint256 newBalance = DEPOSIT + 5e18;

        vm.expectEmit(true, false, false, true, address(budget));
        emit PublicAgentBudget.Deposited(owner, 5e18, newBalance);

        vm.prank(owner);
        budget.deposit{value: 5e18}();
    }

    /*//////////////////////////////////////////////////////////////
                            ERROR: NotAgent
    //////////////////////////////////////////////////////////////*/

    function test_Spend_RevertsNotAgent() public {
        vm.expectRevert(PublicAgentBudget.NotAgent.selector);
        vm.prank(stranger);
        budget.spend(seller, 1e18);
    }

    function test_Spend_OwnerIsNotAgentByDefault() public {
        // Owner has no special spend path. Spending is agent-only, so the owner cannot
        // move funds out through spend().
        vm.expectRevert(PublicAgentBudget.NotAgent.selector);
        vm.prank(owner);
        budget.spend(seller, 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                          ERROR: NotAllowlisted
    //////////////////////////////////////////////////////////////*/

    function test_Spend_RevertsNotAllowlisted() public {
        vm.expectRevert(PublicAgentBudget.NotAllowlisted.selector);
        vm.prank(agent);
        budget.spend(stranger, 1e18);
    }

    function test_Spend_AllowlistIsRevocable() public {
        budget.setAllowlist(seller, false);

        vm.expectRevert(PublicAgentBudget.NotAllowlisted.selector);
        vm.prank(agent);
        budget.spend(seller, 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                            ERROR: OverPerTx
    //////////////////////////////////////////////////////////////*/

    function test_Spend_RevertsOverPerTx() public {
        vm.expectRevert(PublicAgentBudget.OverPerTx.selector);
        vm.prank(agent);
        budget.spend(seller, PER_TX + 1);
    }

    function test_Spend_ExactlyPerTxCapIsAllowed() public {
        vm.prank(agent);
        budget.spend(seller, PER_TX);
        assertEq(budget.spentToday(), PER_TX, "full per-tx cap allowed");
    }

    /*//////////////////////////////////////////////////////////////
                            ERROR: OverDaily
    //////////////////////////////////////////////////////////////*/

    function test_Spend_RevertsOverDaily() public {
        // perTx allows it, but daily does not.
        budget.setCaps(DAILY, DAILY);

        vm.startPrank(agent);
        budget.spend(seller, DAILY / 2);
        budget.spend(seller, DAILY / 2);
        vm.expectRevert(PublicAgentBudget.OverDaily.selector);
        budget.spend(seller, 1);
        vm.stopPrank();
    }

    function test_Spend_ExactlyDailyCapIsAllowed() public {
        budget.setCaps(DAILY, DAILY);

        vm.prank(agent);
        budget.spend(seller, DAILY);

        assertEq(budget.spentToday(), DAILY, "daily cap fully used");
        assertEq(budget.remainingDaily(), 0, "nothing left today");
    }

    /*//////////////////////////////////////////////////////////////
                        ERROR: InsufficientBalance
    //////////////////////////////////////////////////////////////*/

    function test_Spend_RevertsInsufficientBalance() public {
        // Drain most of the balance out, then leave less than one spend.
        vm.prank(owner);
        budget.withdraw(other, DEPOSIT - 1e18);

        vm.expectRevert(PublicAgentBudget.InsufficientBalance.selector);
        vm.prank(agent);
        budget.spend(seller, 2e18);
    }

    function test_Withdraw_RevertsInsufficientBalance() public {
        vm.expectRevert(PublicAgentBudget.InsufficientBalance.selector);
        vm.prank(owner);
        budget.withdraw(other, DEPOSIT + 1);
    }

    /// @dev Cap checks run before the balance check, so a spend that is both over-cap
    ///      and under-funded reports the cap problem.
    function test_Spend_CapErrorTakesPrecedenceOverBalance() public {
        vm.prank(owner);
        budget.withdraw(other, DEPOSIT);

        vm.expectRevert(PublicAgentBudget.OverPerTx.selector);
        vm.prank(agent);
        budget.spend(seller, PER_TX + 1);
    }

    /*//////////////////////////////////////////////////////////////
                              ERROR: Paused
    //////////////////////////////////////////////////////////////*/

    function test_Spend_RevertsPaused() public {
        budget.pause();

        vm.expectRevert(PublicAgentBudget.Paused.selector);
        vm.prank(agent);
        budget.spend(seller, 1e18);
    }

    function test_Pause_EmitsPauseSet() public {
        vm.expectEmit(true, false, false, true, address(budget));
        emit PublicAgentBudget.PauseSet(owner, true);

        budget.pause();
        assertTrue(budget.isPaused(), "paused");
    }

    function test_Unpause_EmitsPauseSet() public {
        budget.pause();

        vm.expectEmit(true, false, false, true, address(budget));
        emit PublicAgentBudget.PauseSet(owner, false);

        budget.unpause();
        assertFalse(budget.isPaused(), "unpaused");
    }

    function test_Unpause_RestoresSpending() public {
        budget.pause();
        budget.unpause();

        vm.prank(agent);
        budget.spend(seller, 1e18);
        assertEq(budget.spentToday(), 1e18, "spend works again");
    }

    /*//////////////////////////////////////////////////////////////
                          DAILY WINDOW BEHAVIOUR
    //////////////////////////////////////////////////////////////*/

    function test_RemainingDaily_IsFullCapBeforeAnySpend() public view {
        assertEq(budget.remainingDaily(), DAILY, "full cap with no window");
    }

    function test_RemainingDaily_DecreasesWithSpend() public {
        vm.prank(agent);
        budget.spend(seller, 4e18);
        assertEq(budget.remainingDaily(), DAILY - 4e18, "drops by spend");
    }

    function test_RemainingDaily_IsFullCapAfterExpiry() public {
        vm.prank(agent);
        budget.spend(seller, 4e18);

        vm.warp(block.timestamp + 1 days);

        assertEq(budget.remainingDaily(), DAILY, "full cap again once expired");
        assertEq(budget.windowEnd(), 0, "no live window while expired");
        // spentToday is stale until the next spend resets it.
        assertEq(budget.spentToday(), 4e18, "spentToday still shows old value");
    }

    function test_Window_ResetsOnFirstSpendAfterExpiry() public {
        uint256 start = block.timestamp + 100;
        vm.warp(start);

        vm.prank(agent);
        budget.spend(seller, 4e18);
        assertEq(budget.windowStart(), start, "window opened at first spend");

        // Just before expiry the daily cap still applies.
        vm.warp(start + 1 days - 1);
        assertEq(budget.remainingDaily(), DAILY - 4e18, "still inside same window");

        // One second later the window has expired and the next spend resets the counter.
        vm.warp(start + 1 days);
        vm.prank(agent);
        budget.spend(seller, 1e18);

        assertEq(budget.spentToday(), 1e18, "counter reset to the new spend");
        assertEq(budget.windowStart(), start + 1 days, "new window started");
    }

    function test_Window_OneSecondBeforeExpiry_DailyStillBlocks() public {
        uint256 start = block.timestamp + 100;
        vm.warp(start);

        budget.setCaps(DAILY, DAILY);
        vm.prank(agent);
        budget.spend(seller, DAILY);

        vm.warp(start + 1 days - 1);
        vm.expectRevert(PublicAgentBudget.OverDaily.selector);
        vm.prank(agent);
        budget.spend(seller, 1);
    }

    /// @dev Documents the documented caveat: the window is NOT rolling. The agent can
    ///      move a full daily cap right before the boundary and another right after, so
    ///      up to ~2x the daily cap can cross in a very short span.
    function test_Window_IsNotSmoothRolling_DoubleCapCrossesBoundary() public {
        uint256 start = block.timestamp + 100;
        vm.warp(start);

        budget.setCaps(DAILY, DAILY);

        vm.prank(agent);
        budget.spend(seller, DAILY);

        // 1 second before expiry the cap is exhausted.
        vm.warp(start + 1 days - 1);
        vm.expectRevert(PublicAgentBudget.OverDaily.selector);
        vm.prank(agent);
        budget.spend(seller, 1);

        // 1 second after expiry a whole new cap is available.
        vm.warp(start + 1 days);
        vm.prank(agent);
        budget.spend(seller, DAILY);

        assertEq(budget.spentToday(), DAILY, "new window fully refilled");
        assertEq(budget.balance(), DEPOSIT - 2 * DAILY, "2x daily cap left the contract");
    }

    function test_RemainingDaily_MatchesSpendAcrossBoundary() public {
        uint256 start = block.timestamp + 100;
        vm.warp(start);

        vm.prank(agent);
        budget.spend(seller, 10e18);
        assertEq(budget.remainingDaily(), DAILY - 10e18, "before expiry");

        vm.warp(start + 1 days + 5);
        assertEq(budget.remainingDaily(), DAILY, "long after expiry");
    }

    /// @dev Regression: the owner can lower `dailyCap` below `spentToday` while a window
    ///      is open. `dailyCap - spentToday` would then underflow and panic, so a seller
    ///      or the frontend reading the budget got an error instead of a number.
    function test_RemainingDaily_ReturnsZeroWhenDailyCapLoweredBelowSpent() public {
        // Open a window and spend 30 USDC against the default 50 USDC daily cap.
        budget.setCaps(30e18, 50e18);
        vm.prank(agent);
        budget.spend(seller, 30e18);
        assertEq(budget.spentToday(), 30e18, "spent 30 in the open window");

        // Owner lowers the daily cap to 2 USDC, i.e. below what is already spent.
        budget.setCaps(1e18, 2e18);

        // Must report 0 remaining, not revert with an arithmetic panic.
        assertEq(budget.remainingDaily(), 0, "no remaining budget, and no panic");
    }

    /// @dev Same scenario from a `spend()` angle: once the cap is below what is already
    ///      spent, every further payment must revert `OverDaily`.
    function test_Spend_RevertsOverDailyAfterDailyCapLoweredMidWindow() public {
        budget.setCaps(30e18, 50e18);
        vm.prank(agent);
        budget.spend(seller, 30e18);

        budget.setCaps(1e18, 2e18);

        // Even 1 wei busts the 2 USDC cap because 30 USDC is already spent.
        vm.expectRevert(PublicAgentBudget.OverDaily.selector);
        vm.prank(agent);
        budget.spend(seller, 1);

        // The window was already open, so the check above fired rather than a reset.
        assertEq(budget.windowStart() != 0, true, "window stayed open");
    }

    /// @dev Lowering the cap mid-window must not wedge the contract: after the window
    ///      expires the next spend starts fresh at the new cap.
    function test_Window_ResetsNormallyAfterDailyCapLoweredMidWindow() public {
        uint256 start = block.timestamp + 100;
        vm.warp(start);

        budget.setCaps(30e18, 50e18);
        vm.prank(agent);
        budget.spend(seller, 30e18);

        budget.setCaps(1e18, 2e18);
        assertEq(budget.remainingDaily(), 0, "zeroed inside the window");

        // After expiry the full new cap is available again.
        vm.warp(start + 1 days);
        assertEq(budget.remainingDaily(), 2e18, "refilled to the new cap after expiry");

        vm.prank(agent);
        budget.spend(seller, 1e18);

        assertEq(budget.spentToday(), 1e18, "counter reset for the new window");
        assertEq(budget.windowStart(), start + 1 days, "new window opened");
        assertEq(budget.remainingDaily(), 1e18, "new cap minus the new spend");
    }

    /*//////////////////////////////////////////////////////////////
                              WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function test_Withdraw_OwnerOnly() public {
        vm.expectRevert("not owner");
        vm.prank(agent);
        budget.withdraw(owner, 1e18);
    }

    function test_Withdraw_MovesUnspentFunds() public {
        uint256 before = budget.balance();
        uint256 ownerBefore = owner.balance;

        vm.prank(owner);
        budget.withdraw(owner, 100e18);

        assertEq(budget.balance(), before - 100e18, "balance reduced");
        assertEq(owner.balance, ownerBefore + 100e18, "owner received funds");
    }

    /// @dev The core limit claim: the owner can take back only what has not been spent.
    ///      Once spent, the funds are gone and the contract balance reflects that.
    function test_Withdraw_CannotRecoverSpentFunds() public {
        budget.setCaps(DAILY, DAILY);

        vm.prank(agent);
        budget.spend(seller, 50e18);

        uint256 unspent = DEPOSIT - 50e18;

        // Owner can withdraw the unspent remainder.
        vm.prank(owner);
        budget.withdraw(owner, unspent);

        assertEq(budget.balance(), 0, "nothing left");

        // But cannot claw back the 50 already paid out.
        vm.expectRevert(PublicAgentBudget.InsufficientBalance.selector);
        vm.prank(owner);
        budget.withdraw(owner, 1);
    }

    function test_Withdraw_AllThenSpendReverts() public {
        vm.prank(owner);
        budget.withdraw(owner, budget.balance());

        vm.expectRevert(PublicAgentBudget.InsufficientBalance.selector);
        vm.prank(agent);
        budget.spend(seller, 1e18);
    }

    function test_Withdraw_DoesNotTouchDailyCounters() public {
        vm.prank(agent);
        budget.spend(seller, 10e18);

        vm.prank(owner);
        budget.withdraw(owner, 100e18);

        // Spending already happened; withdrawing does not give the daily budget back.
        assertEq(budget.spentToday(), 10e18, "spentToday unchanged");
        assertEq(budget.remainingDaily(), DAILY - 10e18, "remainingDaily unchanged");
    }

    function test_Withdraw_EmitsWithdrawn() public {
        vm.expectEmit(true, false, false, true, address(budget));
        emit PublicAgentBudget.Withdrawn(other, 10e18, DEPOSIT - 10e18);

        vm.prank(owner);
        budget.withdraw(other, 10e18);
    }

    function test_Withdraw_ToContractThatRevertsReverts() public {
        RevertingSeller rejecter = new RevertingSeller();

        vm.expectRevert("withdraw transfer failed");
        vm.prank(owner);
        budget.withdraw(address(rejecter), 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                        ADVERSARIAL SELLERS
    //////////////////////////////////////////////////////////////*/

    function test_Spend_ToSellerThatReverts_FailsAndKeepsFunds() public {
        RevertingSeller rejecter = new RevertingSeller();
        budget.setAllowlist(address(rejecter), true);

        vm.expectRevert("seller payment failed");
        vm.prank(agent);
        budget.spend(address(rejecter), 1e18);

        // Nothing moved, and the failed spend left no trace in the counters.
        assertEq(budget.balance(), DEPOSIT, "funds retained");
        assertEq(budget.spentToday(), 0, "spentToday not charged");
        assertEq(budget.windowStart(), 0, "no window opened");
    }

    function test_Spend_ToWellBehavedSeller_ReceivesExactAmount() public {
        RecordingSeller rec = new RecordingSeller();
        budget.setAllowlist(address(rec), true);

        vm.prank(agent);
        budget.spend(address(rec), 3e18);

        assertEq(rec.received(), 3e18, "seller got exact native amount");
        assertEq(rec.calls(), 1, "paid once");
    }

    /// @dev A seller that re-enters spend() and withdraw() from inside receive() cannot
    ///      do either: by then msg.sender is the seller, so onlyAgent and onlyOwner both
    ///      fail. The outer payment completes exactly once.
    function test_Spend_ToReentrancySeller_ReentryBlocked() public {
        ReentrancySeller attacker = new ReentrancySeller(budget);
        attacker.setAttack(true, true);
        budget.setAllowlist(address(attacker), true);

        vm.prank(agent);
        budget.spend(address(attacker), 2e18);

        assertEq(
            uint8(attacker.spendOutcome()),
            uint8(ReentrancySeller.Outcome.Blocked),
            "re-entrant spend blocked"
        );
        assertEq(
            uint8(attacker.withdrawOutcome()),
            uint8(ReentrancySeller.Outcome.Blocked),
            "re-entrant withdraw blocked"
        );
        assertEq(attacker.calls(), 1, "paid exactly once, no re-entry");
        assertEq(attacker.received(), 2e18, "only the intended amount");
        assertEq(budget.balance(), DEPOSIT - 2e18, "one payment left the contract");
        assertEq(budget.spentToday(), 2e18, "charged once");
    }

    /// @dev Checks-effects-interactions: the counters are already updated when the
    ///      seller's receive() runs, so the seller observes post-spend state.
    function test_Spend_StateUpdatedBeforeSellerCallback() public {
        ReentrancySeller observer = new ReentrancySeller(budget);
        budget.setAllowlist(address(observer), true);

        vm.prank(agent);
        budget.spend(address(observer), 2e18);

        assertEq(
            observer.spentTodaySeenDuringCallback(),
            2e18,
            "spentToday already updated during callback"
        );
        assertEq(
            observer.windowStartSeenDuringCallback(),
            block.timestamp,
            "windowStart already updated during callback"
        );
    }

    function test_Spend_ReentrantAttemptDoesNotInflateCounters() public {
        ReentrancySeller attacker = new ReentrancySeller(budget);
        attacker.setAttack(true, false);
        budget.setAllowlist(address(attacker), true);

        vm.prank(agent);
        budget.spend(address(attacker), 1e18);

        // If the inner spend had succeeded it would have charged 1 more.
        assertEq(budget.spentToday(), 1e18, "counter charged once");
        assertEq(budget.balance(), DEPOSIT - 1e18, "one payment only");
    }

    function test_FailedSpend_EmitsNoEvents() public {
        vm.recordLogs();

        vm.expectRevert(PublicAgentBudget.OverPerTx.selector);
        vm.prank(agent);
        budget.spend(seller, PER_TX + 1);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no logs from a reverted spend");
    }

    /*//////////////////////////////////////////////////////////////
                  RE-ENTRANCY WHEN THE AGENT IS THE SELLER
    //////////////////////////////////////////////////////////////*/

    /// @dev The agent address is itself the allowlisted seller, so it re-enters `spend()`
    ///      from inside its own `receive()` and the re-entrant call passes `onlyAgent`.
    ///      This is why the contract's safety rests on checks-effects-interactions rather
    ///      than on the access check. The nested spend must be charged, not free.
    function test_Spend_AgentAsSeller_ReentryIsChargedNotFree() public {
        ReentrantAgent agentAsSeller = new ReentrantAgent(budget);

        budget.setAgent(address(agentAsSeller));
        budget.setAllowlist(address(agentAsSeller), true);

        agentAsSeller.attack(5e18);

        // The nested spend really did execute rather than reverting.
        assertEq(agentAsSeller.innerOutcome(), 1, "re-entrant spend was allowed through");

        // 5 USDC outer + 1 USDC nested, both charged.
        assertEq(agentAsSeller.innerSpentToday(), 6e18, "nested spend charged on top");
        assertEq(budget.spentToday(), 6e18, "counter reflects both spends");
        assertEq(agentAsSeller.received(), 6e18, "seller received both payments");
        assertEq(agentAsSeller.calls(), 2, "paid twice, not infinitely");
        assertEq(budget.balance(), DEPOSIT - 6e18, "both payments left the contract");
    }

    /// @dev Same setup, but the caps must still bind across the nested call: the nested
    ///      spend cannot slip past the per-tx or daily limit just because it is re-entrant.
    function test_Spend_AgentAsSeller_ReentryStillRespectsPerTxCap() public {
        ReentrantAgent agentAsSeller = new ReentrantAgent(budget);

        // Per-tx cap below the nested 1 USDC, so the nested call must be rejected.
        budget.setAgent(address(agentAsSeller));
        budget.setAllowlist(address(agentAsSeller), true);
        budget.setCaps(5e17, DAILY);

        agentAsSeller.attack(5e17);

        assertEq(agentAsSeller.innerOutcome(), 2, "re-entrant spend blocked by per-tx cap");
        assertEq(agentAsSeller.calls(), 1, "only the outer payment landed");
        assertEq(budget.spentToday(), 5e17, "charged once");
        assertEq(budget.balance(), DEPOSIT - 5e17, "one payment left the contract");
    }

    /*//////////////////////////////////////////////////////////////
                        DECIMALS: 18 vs 6 (1e12)
    //////////////////////////////////////////////////////////////*/

    /// @dev Native USDC on Arc has 18 decimals, so 1 USDC is 10^18 base units.
    function test_Decimals_NativeIs18() public {
        assertEq(ONE_USDC, 1e18, "one USDC is 1e18 native base units");
        assertEq(ONE_USDC, 1_000_000_000_000_000_000, "18 decimals");

        RecordingSeller rec = new RecordingSeller();
        budget.setAllowlist(address(rec), true);

        vm.prank(agent);
        budget.spend(address(rec), 1e18);

        assertEq(rec.received(), 1e18, "seller received exactly 1 USDC");
    }

    /// @dev The ERC-20 USDC representation has 6 decimals, so 1 USDC there is 10^6.
    ///      The gap is exactly 10^12. This test pins that number down against a real
    ///      6-decimal token rather than asserting a constant.
    function test_Decimals_Erc20GapIsExactly1e12() public {
        MockUSDC6 token = new MockUSDC6();
        assertEq(token.decimals(), 6, "ERC-20 USDC has 6 decimals");

        uint256 oneUsdcErc20 = 10 ** token.decimals(); // 1e6
        uint256 oneUsdcNative = 10 ** 18; // 1e18

        assertEq(oneUsdcNative / oneUsdcErc20, 1e12, "native is 1e12x the ERC-20 amount");
        assertEq(oneUsdcErc20 * 1e12, oneUsdcNative, "multiplying by 1e12 converts");
    }

    /// @dev Concrete money version of the trap: moving 1e6 through the 6-decimal token
    ///      is 1 USDC, while 1e6 native is 0.000000000001 USDC. A script that copies an
    ///      ERC-20 amount into a native call is off by 10^12.
    function test_Decimals_SixDecimalAmountIsDustNatively() public {
        uint256 erc20Amount = 1e6; // "1 USDC" if you read it as an ERC-20 amount

        // As native USDC the same number is a trillionth of a cent-scale unit.
        assertLt(erc20Amount, 1e12, "1e6 native is dust, not 1 USDC");

        RecordingSeller rec = new RecordingSeller();
        budget.setAllowlist(address(rec), true);

        vm.prank(agent);
        budget.spend(address(rec), erc20Amount);

        assertEq(rec.received(), 1e6, "native payment really was 1e6");
        assertLt(rec.received(), 1e12, "which is dust in 18-decimal terms");
    }

    /// @dev Caps are denominated in the same 18-decimal native units, so a cap written
    ///      with 6-decimal maths silently allows 1e12x less than intended.
    function test_Decimals_CapsAreNativeUnits() public {
        uint256 naiveCap = 1e6; // a naive "1 USDC" in 6-decimal terms

        budget.setCaps(naiveCap, naiveCap);

        vm.prank(agent);
        budget.spend(seller, naiveCap);

        assertEq(budget.spentToday(), naiveCap, "spent in native units");
        assertEq(budget.remainingDaily(), 0, "cap exhausted immediately");
        assertLt(naiveCap, ONE_USDC, "cap was 1e12x smaller than intended");
    }

    /*//////////////////////////////////////////////////////////////
                            ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_OwnerOnly_Functions() public {
        vm.startPrank(stranger);

        vm.expectRevert("not owner");
        budget.setAgent(stranger);
        vm.expectRevert("not owner");
        budget.setAllowlist(stranger, true);
        vm.expectRevert("not owner");
        budget.setCaps(1e18, 2e18);
        vm.expectRevert("not owner");
        budget.pause();
        vm.expectRevert("not owner");
        budget.unpause();
        vm.expectRevert("not owner");
        budget.withdraw(stranger, 1e18);

        vm.stopPrank();

        // Nothing changed.
        assertEq(budget.agent(), agent, "agent unchanged");
        assertFalse(budget.isAllowlisted(stranger), "allowlist unchanged");
        assertEq(budget.perTxCap(), PER_TX, "perTx unchanged");
        assertFalse(budget.isPaused(), "not paused");
    }

    function test_SetCaps_RevertsWhenPerTxExceedsDaily() public {
        vm.expectRevert("perTx > daily");
        budget.setCaps(2e18, 1e18);
    }

    function test_SetCaps_AllowsEqualCaps() public {
        budget.setCaps(1e18, 1e18);
        assertEq(budget.perTxCap(), 1e18, "perTx set");
        assertEq(budget.dailyCap(), 1e18, "daily set");
    }

    function test_SetAgent_ChangesSpender() public {
        budget.setAgent(other);

        vm.expectRevert(PublicAgentBudget.NotAgent.selector);
        vm.prank(agent);
        budget.spend(seller, 1e18);

        vm.prank(other);
        budget.spend(seller, 1e18);
        assertEq(budget.spentToday(), 1e18, "new agent can spend");
    }

    /*//////////////////////////////////////////////////////////////
                                FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev Any spend at or under both caps succeeds and is charged correctly.
    function testFuzz_SpendWithinCapsSucceeds(uint96 amount, uint96 perTx, uint96 daily) public {
        perTx = uint96(bound(perTx, 0, 100e18));
        daily = uint96(bound(daily, perTx, 200e18));
        amount = uint96(bound(amount, 0, perTx));

        uint256 before = budget.balance();

        budget.setCaps(perTx, daily);
        vm.deal(owner, daily);
        vm.prank(owner);
        budget.deposit{value: daily}();

        vm.prank(agent);
        budget.spend(seller, amount);

        assertEq(budget.spentToday(), amount, "charged the amount");
        assertEq(budget.balance(), before + daily - amount, "paid out");
        assertEq(budget.remainingDaily(), daily - amount, "remaining tracks daily");
    }

    /// @dev Anything strictly above the per-tx cap reverts, whatever the daily cap.
    function testFuzz_SpendAbovePerTxAlwaysReverts(uint96 amount, uint96 perTx) public {
        perTx = uint96(bound(perTx, 0, 100e18));
        amount = uint96(bound(amount, perTx + 1, type(uint96).max));

        budget.setCaps(perTx, type(uint96).max);

        vm.expectRevert(PublicAgentBudget.OverPerTx.selector);
        vm.prank(agent);
        budget.spend(seller, amount);
    }

    /// @dev Repeated spends inside one window can never exceed the daily cap.
    function testFuzz_RepeatedSpendsNeverExceedDaily(uint96 daily, uint8 count) public {
        daily = uint96(bound(daily, 1e12, 50e18));
        count = uint8(bound(count, 1, 20));

        // perTx == daily so a single payment can reach the whole cap.
        budget.setCaps(daily, daily);
        vm.deal(address(this), daily * 4);
        vm.prank(owner);
        budget.deposit{value: daily * 4}();

        uint256 spentTotal = 0;

        for (uint8 i = 0; i < count; i++) {
            uint256 room = daily - budget.spentToday();
            if (room == 0) break;

            uint256 amount = bound(uint256(keccak256(abi.encode(i))), 1, room);

            vm.prank(agent);
            budget.spend(seller, amount);

            spentTotal += amount;
            assertLe(budget.spentToday(), daily, "never exceeds the daily cap");
        }

        assertEq(budget.spentToday(), spentTotal, "counters match what was paid");
    }

    /// @dev A spend that stays under the per-tx cap but busts the daily cap reverts with
    ///      OverDaily and leaves the balance and counters untouched. The first spend is what
    ///      opens room for the daily cap to be the binding constraint.
    function testFuzz_OverDailySpendRevertsAndKeepsFunds(uint96 daily, uint96 amount) public {
        daily = uint96(bound(daily, 1e12, 50e18));

        budget.setCaps(daily, daily);

        // Consume half the daily cap.
        vm.prank(agent);
        budget.spend(seller, daily / 2);

        // Bound against the room actually left, so the bound holds for odd and even
        // daily values alike. Anything above `remaining` busts the daily cap.
        uint256 remaining = daily - budget.spentToday();
        amount = uint96(bound(amount, remaining + 1, daily));

        uint256 before = budget.balance();

        // amount is > the remaining daily room but <= perTxCap, so OverDaily is the
        // constraint that fires.
        vm.expectRevert(PublicAgentBudget.OverDaily.selector);
        vm.prank(agent);
        budget.spend(seller, amount);

        assertEq(budget.balance(), before, "funds untouched");
        assertEq(budget.spentToday(), daily / 2, "counter still holds the first spend");
    }

    /// @dev Withdraw never moves more than the current balance, for any amount.
    function testFuzz_WithdrawAboveBalanceAlwaysReverts(uint256 amount) public {
        amount = bound(amount, DEPOSIT + 1, type(uint256).max);

        vm.expectRevert(PublicAgentBudget.InsufficientBalance.selector);
        vm.prank(owner);
        budget.withdraw(other, amount);
    }

    /// @dev Deposits and spends keep balance() equal to deposits minus spends.
    function testFuzz_BalanceTracksDepositsMinusSpends(uint96 dep, uint96 spend) public {
        dep = uint96(bound(dep, 0, 50e18));
        uint256 spendMax = dep < PER_TX ? dep : PER_TX;
        spend = uint96(bound(spend, 0, spendMax));

        uint256 before = budget.balance();

        vm.deal(address(this), dep);
        vm.prank(owner);
        budget.deposit{value: dep}();

        if (spend > 0) {
            vm.prank(agent);
            budget.spend(seller, spend);
        }

        assertEq(budget.balance(), before + dep - spend, "balance arithmetic holds");
    }

    /// @dev The window resets at the boundary, so a full cap is available again after 1
    ///      day no matter how much was spent.
    function testFuzz_RemainingDailyRefillsAfterWindow(uint96 daily, uint256 elapsed) public {
        daily = uint96(bound(daily, 1e12, 50e18));
        elapsed = bound(elapsed, 1 days, 30 days);

        budget.setCaps(daily, daily);
        uint256 start = block.timestamp + 1000;
        vm.warp(start);

        vm.prank(agent);
        budget.spend(seller, daily);
        assertEq(budget.remainingDaily(), 0, "empty within the window");

        vm.warp(start + elapsed);
        assertEq(budget.remainingDaily(), daily, "refilled once expired");
    }
}
