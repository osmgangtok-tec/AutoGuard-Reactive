// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Minimal view of the Reactive callback proxy, inlined so the file compiles in Remix with no imports.
interface ICallbackProxy {
    function debt(address account) external view returns (uint256);
}

/// @title AutoGuardVault
/// @notice Origin + destination contract on Base Sepolia (chain 84532).
///
/// Flow
///   1. A user deposits ETH and sets a stop-loss price (USD, 8 decimals).
///   2. `simulatePriceFeed` moves that user's mock price and emits `PriceDropped` when it falls.
///   3. AutoGuardReactive (Reactive Lasna) sees the event and, if the stop-loss is crossed,
///      requests a callback.
///   4. The Reactive callback proxy calls `executeEmergencyProtect`, which moves the user's
///      active balance into a protected balance.
///
/// Time: Base Sepolia blocks arrive every ~200ms, so this contract uses `block.timestamp` only.
contract AutoGuardVault {
    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    struct Position {
        uint256 active; // ETH exposed to the stop-loss
        uint256 protectedAmount; // ETH moved to safety by the callback
        uint256 protectedUntil; // timestamp when protected funds can be withdrawn
        uint256 stopLossPrice; // USD, 8 decimals; 0 means not armed
        uint256 simulatedPrice; // mock price for this user, USD 8 decimals; 0 means DEFAULT_PRICE
    }

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAmount();
    error ZeroAddress();
    error NotOwner();
    error NotCallbackProxy();
    error UnauthorizedReactive(address rvmId);
    error InsufficientBalance();
    error StillLocked(uint256 unlocksAt);
    error InsufficientGasReserve();
    error TransferFailed();
    error Reentrancy();

    // ---------------------------------------------------------------------
    // Constants and storage
    // ---------------------------------------------------------------------

    /// @notice Reactive callback proxy for Base Sepolia (84532). Only this address may deliver callbacks.
    address public constant CALLBACK_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;

    /// @notice Starting mock price: $3,000.00 with 8 decimals.
    uint256 public constant DEFAULT_PRICE = 3000e8;

    /// @notice How long protected funds stay locked after an emergency protect.
    uint256 public constant PROTECTION_COOLDOWN = 1 minutes;

    address public immutable owner;

    /// @notice The AutoGuardReactive contract on Lasna. Reactive injects this address as the
    ///         first argument of every callback, so it doubles as the callback's `rvmId`.
    address public reactiveContract;

    /// @notice Sum of all user balances (active + protected). Never available for gas payments.
    uint256 public totalLiabilities;

    mapping(address => Position) private _positions;
    uint256 private _lock = 1;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event Deposited(address indexed user, uint256 amount, uint256 timestamp);
    event StopLossSet(address indexed user, uint256 stopLossPrice);
    event PriceDropped(address indexed user, uint256 oldPrice, uint256 newPrice, uint256 timestamp);
    event PriceUpdated(address indexed user, uint256 oldPrice, uint256 newPrice, uint256 timestamp);
    event EmergencyProtected(address indexed user, uint256 protectedAmount, uint256 timestamp);
    event Withdrawn(address indexed user, uint256 amount, bool fromProtected, uint256 timestamp);
    event ReactiveContractSet(address indexed reactive);
    event GasReserveFunded(address indexed from, uint256 amount);

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_lock == 2) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    /// @dev Reactive overwrites the first 160 bits of the callback payload with the address of the
    ///      reactive contract that requested it. Checking both the sender and that address proves
    ///      the call came through the network from the contract we trust.
    modifier rvmIdOnly(address rvmId) {
        if (msg.sender != CALLBACK_PROXY) revert NotCallbackProxy();
        if (reactiveContract == address(0) || rvmId != reactiveContract) revert UnauthorizedReactive(rvmId);
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    /// @notice Authorize the deployed AutoGuardReactive contract. Call once after deploying it on Lasna.
    function setReactiveContract(address reactive) external onlyOwner {
        if (reactive == address(0)) revert ZeroAddress();
        reactiveContract = reactive;
        emit ReactiveContractSet(reactive);
    }

    /// @notice Recover ETH from the callback gas reserve. User funds are never reachable from here.
    function withdrawGasReserve(uint256 amount) external onlyOwner nonReentrant {
        _payFromReserve(owner, amount);
    }

    // ---------------------------------------------------------------------
    // User actions
    // ---------------------------------------------------------------------

    function deposit() external payable {
        if (msg.value == 0) revert ZeroAmount();
        _positions[msg.sender].active += msg.value;
        totalLiabilities += msg.value;
        emit Deposited(msg.sender, msg.value, block.timestamp);
    }

    /// @param price Stop-loss in USD with 8 decimals (for example 2500e8 for $2,500).
    function setStopLoss(uint256 price) external {
        if (price == 0) revert ZeroAmount();
        _positions[msg.sender].stopLossPrice = price;
        emit StopLossSet(msg.sender, price);
    }

    /// @notice Testnet price feed. Moves the caller's own mock price. A lower price emits `PriceDropped`,
    ///         which AutoGuardReactive listens for on Lasna.
    /// @param newPrice USD with 8 decimals.
    function simulatePriceFeed(uint256 newPrice) external {
        if (newPrice == 0) revert ZeroAmount();
        Position storage p = _positions[msg.sender];
        uint256 oldPrice = _price(p);
        p.simulatedPrice = newPrice;
        if (newPrice < oldPrice) {
            emit PriceDropped(msg.sender, oldPrice, newPrice, block.timestamp);
        } else {
            emit PriceUpdated(msg.sender, oldPrice, newPrice, block.timestamp);
        }
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Position storage p = _positions[msg.sender];
        if (amount > p.active) revert InsufficientBalance();
        p.active -= amount;
        totalLiabilities -= amount;
        _send(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, false, block.timestamp);
    }

    function withdrawProtected() external nonReentrant {
        Position storage p = _positions[msg.sender];
        uint256 amount = p.protectedAmount;
        if (amount == 0) revert InsufficientBalance();
        if (block.timestamp < p.protectedUntil) revert StillLocked(p.protectedUntil);
        p.protectedAmount = 0;
        totalLiabilities -= amount;
        _send(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, true, block.timestamp);
    }

    // ---------------------------------------------------------------------
    // Reactive callback
    // ---------------------------------------------------------------------

    /// @notice Called by the Reactive callback proxy when AutoGuardReactive decides a stop-loss was hit.
    /// @param rvmId Injected by Reactive: the address of the reactive contract that requested the callback.
    /// @param user The depositor to protect.
    /// @dev The trigger is re-checked here so a callback can never move funds unless the user's own
    ///      stop-loss is crossed. A stale or duplicate callback returns quietly instead of reverting,
    ///      because a reverting callback still costs gas.
    function executeEmergencyProtect(address rvmId, address user) external rvmIdOnly(rvmId) {
        Position storage p = _positions[user];
        uint256 amount = p.active;
        if (amount == 0 || p.stopLossPrice == 0 || _price(p) > p.stopLossPrice) return;

        p.active = 0;
        p.protectedAmount += amount;
        p.protectedUntil = block.timestamp + PROTECTION_COOLDOWN;
        emit EmergencyProtected(user, amount, block.timestamp);
    }

    // ---------------------------------------------------------------------
    // Callback gas payments
    // ---------------------------------------------------------------------

    /// @notice Plain ETH sent here funds the callback gas reserve. It is not a deposit; use `deposit()`.
    receive() external payable {
        emit GasReserveFunded(msg.sender, msg.value);
    }

    /// @notice ETH held beyond what users are owed. Only this portion can pay for callbacks.
    function gasReserve() public view returns (uint256) {
        return address(this).balance - totalLiabilities;
    }

    /// @notice Called by the callback proxy when a callback creates debt.
    function pay(uint256 amount) external {
        if (msg.sender != CALLBACK_PROXY) revert NotCallbackProxy();
        _payFromReserve(msg.sender, amount);
    }

    /// @notice Settle any debt owed to the callback proxy from the gas reserve. Anyone may call.
    function coverDebt() external {
        _payFromReserve(CALLBACK_PROXY, ICallbackProxy(CALLBACK_PROXY).debt(address(this)));
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getPosition(address user)
        external
        view
        returns (
            uint256 active,
            uint256 protectedAmount,
            uint256 protectedUntil,
            uint256 stopLossPrice,
            uint256 price
        )
    {
        Position storage p = _positions[user];
        return (p.active, p.protectedAmount, p.protectedUntil, p.stopLossPrice, _price(p));
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _price(Position storage p) private view returns (uint256) {
        uint256 current = p.simulatedPrice;
        return current == 0 ? DEFAULT_PRICE : current;
    }

    function _payFromReserve(address to, uint256 amount) private {
        if (amount == 0) return;
        if (amount > gasReserve()) revert InsufficientGasReserve();
        _send(to, amount);
    }

    function _send(address to, uint256 amount) private {
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
