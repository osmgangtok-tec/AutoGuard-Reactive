# AutoGuard — Autonomous Cross-Chain DeFi Stop-Loss & Risk Sentinel

**Built for the Reactive Omni Buildathon**

AutoGuard is an autonomous, non-custodial cross-chain risk-protection protocol powered by **Reactive Network (`Reactive Lasna`)** and **Base (`Base Sepolia`)**. Instead of relying on centralized off-chain cron jobs or keeper bots that can go offline during high volatility, AutoGuard uses a Reactive Smart Contract (`AutoGuardReactive`) to continuously subscribe to on-chain price-drop events on Base Sepolia and automatically trigger emergency position protection callbacks on-chain.

---

## Architecture & Workflow

1. **Deposit & Configure Guard (`Base Sepolia`):** A user deposits ETH into `AutoGuardVault` and sets an on-chain stop-loss threshold via `setStopLoss(uint256)`.
2. **Autonomous Event Subscription (`Reactive Lasna`):** `AutoGuardReactive` subscribes directly to `PriceDropped` events emitted by `AutoGuardVault` on Base Sepolia (`Chain ID: 84532`).
3. **Zero-Keeper Cross-Chain Callback (`Lasna -> Base Sepolia`):** When market prices breach the user's stop-loss (`simulatePriceFeed`), `AutoGuardReactive.react()` detects the log on Reactive Lasna (`Chain ID: 5318007`) and emits a `Callback` payload to execute `executeEmergencyProtect(address,address)` back on Base Sepolia, moving the user's funds into protected withdrawable status without human intervention.

---

## Live Deployed & Verified Contracts

| Component | Network | Chain ID | Contract Address | Verification |
| :--- | :--- | :--- | :--- | :--- |
| **`AutoGuardVault`** | Base Sepolia | `84532` | `0x92De22c7122819D905dAd5533522F74C1264F5b7` | Verified (Sourcify) |
| **`AutoGuardReactive`** | Reactive Lasna | `5318007` | `0x92De22c7122819D905dAd5533522F74C1264F5b7` | Verified (Sourcify) |

---

## End-to-End On-Chain Proof (Full Transaction Hashes)

All core lifecycle steps have been executed and verified on-chain from deployer wallet `0x8d0c695ee0183962f7bb1d90b27b573e9a05f21c`:

1. **User Vault Deposit (`deposit()` — `0.00001 ETH` on Base Sepolia):**  
   `0xc6b6694442fcb4651b2f0d5bcc646cf589eee42ae0b0ab48c1ba80469b82a310`
2. **Configure Stop-Loss Threshold (`setStopLoss($2,800 / 280000000000)` on Base Sepolia):**  
   `0x0161e529fe8f8e8ad711e11d399e74a9efc52f8d26aaaf5f7176806da804e47b`
3. **Trigger Price Drop Event (`simulatePriceFeed($2,500 / 250000000000)` on Base Sepolia):**  
   `0x8512066a690a61d9ac797fdf0255e5423eef9428d9be3b402b0dda723c7867a0`

---

## Security Features

* **Strict Callback Authentication (`rvmIdOnly`):** Only authorized callbacks originating from the Reactive Network Callback Proxy (`0x476F44b11F5C942c58f4c8E3d0300E5710743585`) and matching the deployer's ReactVM ID can trigger `executeEmergencyProtect`.
* **Reentrancy Protection:** Custom non-reentrant lock guards all ETH deposits and withdrawals.
* **Pull-Over-Push Withdrawals:** Protected funds are isolated per user for safe self-custody withdrawal (`withdrawProtected`).
