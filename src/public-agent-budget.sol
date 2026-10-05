// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title PublicAgentBudget
/// @notice A public spending limit for one AI agent, holding native USDC (Arc gas
///         token, 18 decimals natively). Anyone can read the budget on-chain before
///         doing work for the agent.
///
/// @dev This is a TRANSPARENT LIMIT, NOT AN ESCROW.
///      - The owner can pause and withdraw at any time. A seller that sees budget
///        remaining is not guaranteed payment.
///      - No funds are reserved for any specific job.
///      - The daily window starts at the first spend and ends 24h later. It is NOT a
///        smooth rolling window, so up to roughly 2x `dailyCap` can move across a
///        window boundary. See the daily-window section below.
///
///      Roles: `owner` (admin) and `agent` (the single spender). No other admin roles,
///      no proxy, no upgradeability.
///
///      Amounts are native USDC base units: 18 decimals. The 6-decimal ERC-20 USDC
///      representation differs by 1e12.
contract PublicAgentBudget {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice The contract is paused.
    error Paused();
    /// @notice Caller is not the agent.
    error NotAgent();
    /// @notice Seller is not on the allowlist.
    error NotAllowlisted();
    /// @notice Amount is above the per-payment cap.
    error OverPerTx();
    /// @notice Amount would push the window past the daily cap.
    error OverDaily();
    /// @notice Not enough unspent balance in the contract.
    error InsufficientBalance();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Owner funded the budget.
    event Deposited(address indexed from, uint256 amount, uint256 newBalance);
    /// @notice Agent paid an allowlisted seller.
    event Spent(address indexed to, uint256 amount, uint256 spentToday, uint256 windowStart);
    /// @notice Owner withdrew unspent funds.
    event Withdrawn(address indexed to, uint256 amount, uint256 remaining);
    /// @notice Owner changed the caps.
    event CapsSet(uint256 perTxCap, uint256 dailyCap);
    /// @notice Owner changed a seller's allowlist status.
    event AllowlistSet(address indexed seller, bool allowed);
    /// @notice Owner changed the paused state.
    /// @dev Covers both directions. The frozen event list could not keep the name
    ///      `Paused`: Solidity does not allow `error Paused()` and `event Paused` to
    ///      coexist, so the event is `PauseSet` and the revert reason stays `Paused()`.
    event PauseSet(address indexed caller, bool paused);

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public agent;

    uint256 public perTxCap;
    uint256 public dailyCap;
    uint256 public spentToday;

    /// @notice Timestamp at which the current daily window opened. 0 means no window
    ///         has opened yet, i.e. the agent has never spent.
    uint256 public windowStart;

    mapping(address seller => bool allowed) public isAllowlisted;

    bool public isPaused;

    /// @dev Tracks whether a window is open. Kept separate from `windowStart` so that a
    ///      window is never confused with the timestamp 0.
    bool private windowOpen;

    /// @dev One day, the fixed window length.
    uint256 private constant WINDOW = 1 days;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier onlyAgent() {
        if (msg.sender != agent) revert NotAgent();
        _;
    }

    modifier notPaused() {
        if (isPaused) revert Paused();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        owner = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                              OWNER: FUNDING
    //////////////////////////////////////////////////////////////*/

    /// @notice Add native USDC to the budget.
    function deposit() external payable onlyOwner {
        // effects
        uint256 newBalance = address(this).balance;
        // interactions: none
        emit Deposited(msg.sender, msg.value, newBalance);
    }

    /// @notice Withdraw unspent funds.
    /// @dev Moves at most the contract's current unspent balance. Already-spent funds
    ///      are gone and cannot be withdrawn; the balance check below is what enforces
    ///      that. Nothing is reserved for a job, so this can withdraw funds a seller is
    ///      relying on. That is intentional: this is a limit, not an escrow.
    function withdraw(address to, uint256 amount) external onlyOwner {
        // checks
        if (amount > address(this).balance) revert InsufficientBalance();
        // effects
        uint256 remaining = address(this).balance - amount;
        emit Withdrawn(to, amount, remaining);
        // interactions
        (bool ok,) = to.call{value: amount}("");
        require(ok, "withdraw transfer failed");
    }

    /*//////////////////////////////////////////////////////////////
                              OWNER: RULES
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the single agent allowed to spend.
    function setAgent(address newAgent) external onlyOwner {
        agent = newAgent;
    }

    /// @notice Allow or disallow a seller.
    function setAllowlist(address seller, bool allowed) external onlyOwner {
        isAllowlisted[seller] = allowed;
        emit AllowlistSet(seller, allowed);
    }

    /// @notice Set the per-payment and daily caps.
    function setCaps(uint256 newPerTx, uint256 newDaily) external onlyOwner {
        require(newPerTx <= newDaily, "perTx > daily");
        perTxCap = newPerTx;
        dailyCap = newDaily;
        emit CapsSet(newPerTx, newDaily);
    }

    /// @notice Stop the agent from spending.
    function pause() external onlyOwner {
        isPaused = true;
        emit PauseSet(msg.sender, true);
    }

    /// @notice Let the agent spend again.
    function unpause() external onlyOwner {
        isPaused = false;
        emit PauseSet(msg.sender, false);
    }

    /*//////////////////////////////////////////////////////////////
                                AGENT: SPEND
    //////////////////////////////////////////////////////////////*/

    /// @notice Pay an allowlisted seller from the budget.
    /// @dev Checks-effects-interactions. `spentToday` and `windowStart` are written
    ///      BEFORE the seller is called, so a seller that re-enters during `receive()`
    ///      is charged against the already-updated counters and the caps still hold.
    ///      That ordering is what makes this safe, not `onlyAgent`: the agent address
    ///      can itself be an allowlisted contract, so a re-entrant call from the agent
    ///      would already pass the `onlyAgent` check. Note the window is not re-rolled
    ///      on entry, so a re-entrant spend cannot reset `spentToday` either.
    function spend(address to, uint256 amount) external onlyAgent notPaused {
        // checks
        if (!isAllowlisted[to]) revert NotAllowlisted();
        if (amount > perTxCap) revert OverPerTx();

        // effects: roll the window, then charge the spend, all before we pay out
        _rollWindow();
        uint256 newSpentToday = spentToday + amount;
        if (newSpentToday > dailyCap) revert OverDaily();
        spentToday = newSpentToday;

        if (address(this).balance < amount) revert InsufficientBalance();
        emit Spent(to, amount, spentToday, windowStart);

        // interactions
        (bool ok,) = to.call{value: amount}("");
        require(ok, "seller payment failed");
    }

    /*//////////////////////////////////////////////////////////////
                                DAILY WINDOW
    //////////////////////////////////////////////////////////////*/

    /// @dev Lazily opens the first window and resets an expired one.
    ///      Deliberately NOT a rolling window: the window starts at the first spend and
    ///      lasts exactly 24h from there. An agent can spend `dailyCap` right before the
    ///      boundary and another `dailyCap` right after it, so up to ~2x `dailyCap` can
    ///      move in a short span. Documented here and in the README on purpose.
    function _rollWindow() internal {
        if (!windowOpen || block.timestamp >= windowStart + WINDOW) {
            windowOpen = true;
            windowStart = block.timestamp;
            spentToday = 0;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Unspent balance held by the contract, in 18-decimal base units.
    function balance() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Daily budget left in the current window. Returns the full cap when no
    ///         window has opened yet or when the current one has expired, because in both
    ///         cases the next spend starts a fresh window.
    /// @dev The owner may lower `dailyCap` below `spentToday` while a window is still
    ///      open. A plain `dailyCap - spentToday` would underflow and panic, which would
    ///      make the budget unreadable to a seller checking it, so an exhausted budget
    ///      reports 0 instead.
    function remainingDaily() external view returns (uint256) {
        if (!windowOpen || block.timestamp >= windowStart + WINDOW) {
            return dailyCap;
        }
        if (spentToday >= dailyCap) {
            return 0;
        }
        return dailyCap - spentToday;
    }

    /// @notice Timestamp the current window ends. 0 if no window is open.
    function windowEnd() external view returns (uint256) {
        if (!windowOpen || block.timestamp >= windowStart + WINDOW) {
            return 0;
        }
        return windowStart + WINDOW;
    }
}
