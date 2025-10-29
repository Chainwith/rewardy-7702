# RewardyContract (EIP‑7702) — Batch Execution with Optional Fees

**Version:** Solidity ^0.8.20, Ethers v6  
**Contract:** `RewardyContract` — an EIP‑7702 implementation target for per‑transaction delegation

---

## 1) What is this?

`RewardyContract` is a **stateless implementation contract** for [EIP‑7702] style delegation.  
An Externally Owned Account (EOA) temporarily **delegates its behavior for a single transaction** to this implementation via an **Authorization** included in a **type:4** transaction.

This contract adds:
- **Batch execution** of arbitrary calls (`to`, `value`, `data`) with replay protection.
- **Signature verification** using `personal_sign` (i.e., `toEthSignedMessageHash`).
- **Configurable fee** *per call* (either **native ETH** or **any ERC‑20**).
- Supports **ETH and ERC‑20 transfers** inside the batch.
- **No hard‑coded fee token/receiver/amount** — everything is set at call time.

> ⚠️ EIP‑7702 delegation is **not persistent**. It only applies to the **single transaction** that contains the Authorization. After the transaction, the EOA is back to normal.


---

## 2) Design Highlights

- **Per‑EOA storage:** The `nonce` is stored at **slot 0** so each EOA delegating to this implementation maintains its own replay‑protected state.
- **Two different nonces you must understand:**
  - **Authorization Nonce (EOA tx nonce):** used when building the `Authorization` object (`firstSigner.authorize(...)`). This ties delegation to a specific **EOA transaction**.
  - **Contract Nonce (slot0):** stored by `RewardyContract` and consumed in the **batch signature digest** to prevent replay of the **batch** itself.
- **Signature Scheme (off‑chain):**
  ```text
  callsHash = keccak256( packed( (to,value,data)... ) )
  digest    = keccak256( abi.encode(
                  callsHash,
                  fee.token,
                  fee.amount,
                  fee.receiver,
                  contractNonce,   // slot0
                  deadline         // unix seconds
              ))
  signature = personal_sign( digest )  // i.e., toEthSignedMessageHash(digest)
  ```
  On‑chain, we `recover` and require it equals `address(this)` (the smart account address created by delegation).
- **Fees first:** If a fee is specified, it’s charged **before** executing calls. If fee transfer fails, the whole transaction reverts.


---

## 3) Contract Surface

```solidity
contract RewardyContract {
    uint256 public nonce; // slot0

    struct Call { address to; uint256 value; bytes data; }
    struct Fee  { address token; uint256 amount; address receiver; }

    event CallExecuted(address indexed to, uint256 value, bytes data);
    event BatchExecuted(uint256 indexed nonce, uint256 callCount, bytes32 callsHash);
    event FeeCharged(address indexed token, address indexed to, uint256 amount);

    // No-fee path (signature still required)
    function executeWithAuthorization(
        Call[] calldata calls,
        uint256 deadline,
        bytes calldata signature
    ) external payable;

    // Fee path (ETH or ERC-20, fully dynamic per call)
    function executeWithFee(
        Call[] calldata calls,
        Fee calldata fee,
        uint256 deadline,
        bytes calldata signature
    ) external payable;

    // Self-call (when account executes by itself, no signature)
    function executeDirect(Call[] calldata calls) external payable;
}
```

- **ETH fee:** `fee.token == address(0)` → send native ETH to `fee.receiver`.
- **ERC‑20 fee:** `fee.token == <tokenAddress>` → `IERC20(token).transfer(fee.receiver, fee.amount)`.
- **Batch:** Each `Call` is executed with low-level `.call{value}(data)`; revert on any failure.


---

## 4) Included Scripts

All scripts use **Ethers v6** and assume **Node.js 18+**.

### 4.1 `coin_transfer.ts`
- **What:** Send **ETH** via sponsor with **no fee**.
- **How:** Builds `calls` with a single `[recipient, value, "0x"]` entry, signs batch (fee=0), creates Authorization (using **EOA tx nonce**), and calls `executeWithAuthorization` via **type:4** with `authorizationList`.

### 4.2 `coin_transfer_with_erc20.ts`
- **What:** Send **ERC‑20** via sponsor with **no fee**.
- **How:** Encodes `transfer(recipient, amount)` using the token ABI; no fee in digest; same Authorization flow.

### 4.3 `coin_transfer_with_fee.ts`
- **What:** Send **ETH or ERC‑20** and **charge a fee** (ETH or ERC‑20).
- **How:** Digest includes `fee.token/amount/receiver`. Calls `executeWithFee(...)` with Authorization.

### 4.4 `eth_transfer_with_fee.ts`
- **What:** Send **ETH** while charging **ERC‑20 fee**.
- **How:** Ensures `fee.token != address(0)`; otherwise identical digest + Authorization flow.

> All scripts share the invariant:  
> - **Authorization nonce = EOA tx nonce**
> - **Batch digest nonce = contract slot0 nonce**


---

## 5) Env Vars

Create a `.env` file in the project root. Examples below; not all variables are used by every script.

```ini
# RPC & Keys
RPC_URL=...
FIRST_PRIVATE_KEY=0x...             # EOA (the account being delegated)
SPONSOR_PRIVATE_KEY=0x...           # The sponsor paying gas

# Delegation Target
DELEGATION_CONTRACT_ADDRESS=0x...   # RewardyContract deployed address

# Common
RECEIPENT_ADDRESS=0x...             # Recipient for ETH/ERC-20 transfers

# ETH
ETH_AMOUNT=0.000005

# ERC-20 (for transfer)
TOKEN_ADDRESS=0x...                 # ERC-20 you want to send (omit for ETH)
TOKEN_DECIMALS=6
ERC20_AMOUNT=10                     # "human-readable" amount (not wei)

# Fee (ERC-20 or ETH)
FEE_TOKEN_ADDRESS=0x...             # ZeroAddress => ETH fee
FEE_RECEIVER=0x...
# Use exactly one of these:
FEE_AMOUNT=1000000                  # minimal units (wei or token decimals)
# FEE_AMOUNT_HUMAN=1.0             # human amount, requires FEE_TOKEN_DECIMALS
# FEE_TOKEN_DECIMALS=6
```

**Notes:**
- If `FEE_TOKEN_ADDRESS == 0x000...0`, the fee is **ETH** (amount in **wei**).  
- For ERC‑20 fee, ensure the **account (EOA)** has enough fee tokens. The sponsor only covers **gas**.  
- For ERC‑20 transfers, ensure the account holds enough tokens for the transfer itself.


---

## 6) How to Run

```bash
# 1) Install deps
pnpm i         # or npm i / yarn

# 2) Build or run directly with ts-node (if configured)
ts-node coin_transfer.ts
ts-node coin_transfer_with_erc20.ts
ts-node coin_transfer_with_fee.ts
ts-node eth_transfer_with_fee.ts
```

Each script:
1. Loads env, initializes provider/signers.
2. Builds `calls` (ETH or ERC‑20) and **deadline**.
3. Reads **contract nonce (slot0)** for the **batch digest**.
4. Reads **EOA tx nonce** to build the **Authorization**.
5. Signs the digest with `personal_sign` (`signMessage`) and **locally verifies**.
6. Sends a **type:4** tx from the **sponsor** with `authorizationList: [auth]` calling `executeWithAuthorization` or `executeWithFee` on **`to = firstSigner.address`**.


---

## 7) Troubleshooting

### `Rewardy: bad signature`
- **Cause:** Mismatch between **off‑chain digest** and on‑chain verification.
- **Checklist:**
  - Authorization nonce must be **EOA tx nonce**, not the contract nonce.
  - Digest must encode exactly: `abi.encode(callsHash, fee.token, fee.amount, fee.receiver, contractNonce, deadline)`.
  - Signature must be **personal_sign** (use `signMessage` and `verifyMessage` off‑chain).
  - Ensure you are sending to **`to = firstSigner.address`** (the account), not the implementation address.

### `Rewardy: call reverted`
- **Cause:** One of the `calls[i]` failed.
- **Checklist:**
  - For ERC‑20 `transfer`, does the **account** have enough tokens?
  - For ETH value calls, does the **account** have enough ETH?
  - Is the target contract address correct and deployed on this network?
  - Re‑encode calldata and amounts (watch token **decimals**).

### Fee failures
- `Rewardy: fee token failed` → ERC‑20 fee transfer failed; check fee token balance and decimals.
- `Rewardy: fee eth failed` → ETH fee value couldn’t be sent; check the account’s ETH balance.


---

## 8) Security Notes

- **Per‑transaction delegation:** There is no persistent “delegated state.” Authorization works **once**, bound to the **EOA nonce**.
- **Front‑running & cancelation:** If an Authorization signature leaks, you can “revoke” by **preemptively spending the same EOA nonce** (e.g., submit your own tx or a type:4 auth with a different impl/zero‑address) so the leaked one becomes invalid.
- **Always verify locally** (`verifyMessage`) before sending on-chain.


---

## 9) Minimal Code Snippets

### Off‑chain digest & signature
```ts
const callsHash = keccak256(packedCalls);
const digest = keccak256(AbiCoder.defaultAbiCoder().encode(
  ["bytes32","address","uint256","address","uint256","uint256"],
  [callsHash, fee.token, fee.amount, fee.receiver, contractNonce, deadline]
));
const signature = await firstSigner.signMessage(getBytes(digest));
const recovered = verifyMessage(getBytes(digest), signature);
if (recovered.toLowerCase() !== firstSigner.address.toLowerCase())
  throw new Error("local recover mismatch");
```

### Authorization (EOA tx nonce!)
```ts
const authNonce = await provider.getTransactionCount(firstSigner.address, "latest");
const auth = await firstSigner.authorize({
  address: DELEGATION_CONTRACT_ADDRESS,
  nonce: authNonce,
  chainId: Number((await provider.getNetwork()).chainId),
});
```

### Send type:4 with authorizationList
```ts
const delegated = new ethers.Contract(firstSigner.address, rewardyAbi, sponsorSigner);
const tx = await delegated["executeWithFee"](calls, fee, deadline, signature, {
  type: 4,
  authorizationList: [auth],
});
await tx.wait();
```


---

## 10) License

MIT
