// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Minimal Reactive Omni system contract interface, inlined so the file compiles in Remix with no imports.
interface ISystemContract {
    struct CallbackConfiguration_V_1_0 {
        uint256 chainId; // destination network
        address recipient; // target contract on the destination chain
        uint64 gasLimit; // execution gas limit
        bytes payload; // ABI-encoded function call
    }

    function subscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topic2_,
        uint256 topic3_
    ) external;

    function requestCallbackV_1_0(CallbackConfiguration_V_1_0 memory config_) external;

    function debt(address account_) external view returns (uint256);
}

/// @title AutoGuardReactive
/// @notice Reactive contract on Reactive Lasna (chain 5318007). It watches AutoGuardVault on Base Sepolia
///         (84532) and, when a user's price falls to or below their stop-loss, asks the network to call
///         `executeEmergencyProtect(address,address)` on the vault.
///
/// Subscriptions (both from the vault on Base Sepolia)
///   - StopLossSet(address,uint256): remembers each user's stop-loss, so every user has their own threshold.
///   - PriceDropped(address,uint256,uint256,uint256): compares the new price with that threshold.
///
/// Reactive pays for `react()` in lREACT from this contract's balance; the vault pays for the callback in ETH.
contract AutoGuardReactive {
    /// @dev Field order and types must match the struct the system contract passes to `react()`.
    struct LogRecord {
        uint256 chainId;
        address contractAddress;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
        bytes data;
        uint256 blockNumber;
        uint256 opCode;
        uint256 blockHash;
        uint256 txHash;
        uint256 logIndex;
    }

    error NotSystem();
    error NotOwner();
    error ZeroAddress();
    error InsufficientFunds();
    error TransferFailed();

    /// @notice Reactive Omni system contract (Lasna and mainnet). 0x...fffFfF is the legacy contract that only emits CRON events.
    address public constant SYSTEM = 0x8888888888888888888888888888888888888888;

    /// @notice Wildcard for topic positions we do not filter on.
    uint256 private constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    uint256 public constant ORIGIN_CHAIN_ID = 84532; // Base Sepolia
    uint64 public constant CALLBACK_GAS_LIMIT = 300000;

    uint256 private constant PRICE_DROPPED_TOPIC_0 = uint256(keccak256("PriceDropped(address,uint256,uint256,uint256)"));
    uint256 private constant STOP_LOSS_SET_TOPIC_0 = uint256(keccak256("StopLossSet(address,uint256)"));

    address public immutable owner;
    address public immutable vault;

    /// @notice Stop-loss per user, mirrored from the vault's StopLossSet events (USD, 8 decimals).
    mapping(address => uint256) public stopLoss;

    /// @notice True once a callback was requested for the user's current stop-loss. Re-arming resets it.
    mapping(address => bool) public triggered;

    event StopLossTracked(address indexed user, uint256 stopLoss);
    event ProtectionRequested(address indexed user, uint256 newPrice, uint256 threshold);

    modifier onlySystem() {
        if (msg.sender != SYSTEM) revert NotSystem();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param vault_ AutoGuardVault address on Base Sepolia. Send lREACT with the deployment to fund reactive transactions.
    constructor(address vault_) payable {
        if (vault_ == address(0)) revert ZeroAddress();
        owner = msg.sender;
        vault = vault_;

        ISystemContract(SYSTEM).subscribe(
            ORIGIN_CHAIN_ID, vault_, PRICE_DROPPED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        ISystemContract(SYSTEM).subscribe(
            ORIGIN_CHAIN_ID, vault_, STOP_LOSS_SET_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    // ---------------------------------------------------------------------
    // Reactive entry point
    // ---------------------------------------------------------------------

    /// @notice Called by the system contract for every log matching a subscription.
    /// @dev Logs that do not match fall through quietly. Reverting would still bill this contract.
    function react(LogRecord calldata log_) external onlySystem {
        if (log_.chainId != ORIGIN_CHAIN_ID || log_.contractAddress != vault) return;

        if (log_.topic0 == STOP_LOSS_SET_TOPIC_0) {
            // StopLossSet(address indexed user, uint256 stopLossPrice): user in topic1, price in data
            address user = address(uint160(log_.topic1));
            uint256 price = abi.decode(log_.data, (uint256));
            stopLoss[user] = price;
            triggered[user] = false;
            emit StopLossTracked(user, price);
        } else if (log_.topic0 == PRICE_DROPPED_TOPIC_0) {
            // PriceDropped(address indexed user, uint256 oldPrice, uint256 newPrice, uint256 timestamp)
            address user = address(uint160(log_.topic1));
            (, uint256 newPrice, ) = abi.decode(log_.data, (uint256, uint256, uint256));

            uint256 threshold = stopLoss[user];
            if (threshold == 0 || triggered[user] || newPrice > threshold) return;

            triggered[user] = true;

            // The first argument is a placeholder: Reactive replaces it with this contract's address,
            // which the vault checks as the callback's rvmId.
            bytes memory payload = abi.encodeWithSignature("executeEmergencyProtect(address,address)", address(0), user);

            ISystemContract(SYSTEM).requestCallbackV_1_0(
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: ORIGIN_CHAIN_ID,
                    recipient: vault,
                    gasLimit: CALLBACK_GAS_LIMIT,
                    payload: payload
                })
            );

            emit ProtectionRequested(user, newPrice, threshold);
        }
    }

    // ---------------------------------------------------------------------
    // Paying for reactive transactions
    // ---------------------------------------------------------------------

    /// @notice Accepts lREACT so the contract can keep paying for `react()` calls.
    receive() external payable {}

    /// @notice Called by the system contract when a charge exceeds reserves.
    function pay(uint256 amount) external onlySystem {
        _pay(msg.sender, amount);
    }

    /// @notice Settle outstanding debt to the system contract from this contract's balance. Anyone may call.
    ///         A contract in debt stops receiving events until this is cleared.
    function coverDebt() external {
        _pay(SYSTEM, ISystemContract(SYSTEM).debt(address(this)));
    }

    /// @notice Owner can recover unused lREACT.
    function withdrawFunds(uint256 amount) external onlyOwner {
        _pay(owner, amount);
    }

    function _pay(address to, uint256 amount) private {
        if (amount == 0) return;
        if (address(this).balance < amount) revert InsufficientFunds();
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
