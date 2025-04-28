# Cabal Protocol Smart Contracts - Auditor README

## Intro to Cabal

**Please view the Images Below!**

https://docs.google.com/document/d/1Ttrb3CRS7WFIZVmt6pSMWfgMQSa8s0d0wAk3VHeaguM/edit?usp=sharing

---

Initia (https://docs.initia.xyz/) is a L1 chain that allows for the creation of L2 rollups on top of the L1. The L2 rollups are named ‘Minitias.’ Initia operates an incentive framework structure - the **Vested Interest Program.** The architecture, https://docs.initia.xyz/about/vested-interest-program/vip-architecture, distributes INIT tokens to a governance whitelisted set of Minitias based on:

1) the amount of INIT tokens deposited on the Minitia L2

2) Gauge voting process where INIT tokens stakers or governance whitelisted pairs of INIT-X LP tokens (i.e INIT-USDC) can vote on Minitia reward weighting.    

Cabal is a protocol on Initia L1 that issues liquid staking wrappers when users deposit INIT or INIT-X LP tokens. These deposited assets are staked in Initia’s x/mstaking module, granting governance power and rewards from VIP. Cabal also integrates with Initia’s native DEX for liquidity.

### **1. INIT → xINIT <> sxINIT**

**A. Deposit INIT → xINIT**

- Users deposit INIT into Cabal’s “xINIT deposit module”
- In return, Cabal mints and sends the user xINIT, a liquid wrapped with no inherent staking yield on its own
- The underlying INIT is max locked, providing Cabal max voting power.

**B. Liquidity Provisions**

- xINIT will be paired with INIT to form a whitelisted xINIT-INIT LP pair on Initia’s dex
- This allows users to provide liquidity without unbonding their staked INIT

**C. Staking xINIT <> sxINIT (X day lockup and unbonding period)**

- If users want to earn yield and governance influence, they can convert their xINIT into sxINIT, redeeming sxINIT into xINIT goes through a 21 day unbonding period

**D. Yield Sources for sxINIT Holders**

- sxINIT will receive yield from (i) the underlying Initia network staking yield and (ii) Incentives from Cabal’s governance platform (bribes, gauge votes, etc)

### **2. INIT-X LP Tokens**

The Initia governance whitelisted set of INIT-X LP tokens have a separate deposit module on Cabal. LP token holders are able to stake their LP tokens into Cabal and receive a liquid wrapper representing the underlying.

**For example:**

- INIT-USDC LP token pair deposited into Cabal, Cabal stakes the LP token, and returns ‘Cabal Init-X LP’ token to the user for example.

 LP tokens deposited and staked through Cabal, unlike pure INIT, is directly redeemable back into the original LP token - after the 21 day Initia x/staking unbonding period. CabalLP holders receive two sources of rewards:

- Token emissions from InitiaDEX emissions. The INIT rewards are provided as liquidity into the same pool, thus giving Cabal more of the original token. When a user unstakes, they get more Cabal LP tokens than what they put in.
- Direct incentives from Cabal’s built in governance incentive platform, through the same mechanism as sxINIT voting incentives.

Voting Power/Staking yields from LP token pairs are based on the INIT portion of the value that the LP token represents.

A majority of Cabal's revenues come from L2s who bribe use Cabal's vote-locked INIT to vote for them on the guage pool.
## Overview

This document provides an overview of the core smart contracts for the Cabal Protocol, focusing on the structure, interactions, and key mechanisms relevant for auditing. Cabal is a liquid staking protocol built on Initia, allowing users to stake INIT (via xINIT/sxINIT) and whitelisted LP tokens, while also participating in a bribe marketplace to influence Initia's VIP gauge voting. 

The primary modules involved in the core logic are:

*   **`cabal`**: The main staking engine and user interaction hub.
*   **`cabal_token`**: Manages Cabal-specific tokens (xINIT, sxINIT, Cabal LPTs) and implements the lazy balance snapshotting mechanism.
*   **`bribe`**: Handles the deposit and tracking of bribe rewards offered by external parties.
*   **`voting_reward`**: Calculates and distributes bribe rewards to eligible Cabal token holders based on historical snapshots.
*   **`pool_router`**: Acts as an abstraction layer managing interactions with underlying validators for different staked assets (INIT via `vip::lock_staking`, LPs via `mstaking`).

Other relevant modules include `package` (shared addresses/signers), `manager` (admin controls), `emergency` (pausing), `utils` (helpers), `snapshots` (helping with snapshots), and interactions with Initia standard library modules (`fungible_asset`, `primary_fungible_store`, `cosmos`, `vip`, `dex`, `object`, `table`, etc.).

## Core Modules and Responsibilities

**1. `cabal` Module (`sources/cabal.move`)**

*   **Responsibilities:**
    *   Handles user deposits of native INIT to mint xINIT (`deposit_init_for_xinit`).
    *   Manages the staking process where users lock underlying tokens (xINIT or LP tokens) to mint Cabal liquid staking tokens (sxINIT or Cabal LPTs) (`stake_asset`, triggering internal `stake_xinit` or `stake_lp` which use `cosmos::move_execute` to call `process_xinit_stake` or `process_lp_stake`).
    *   Manages the **sxINIT** unstaking process (`initiate_unstake`), including calculating redemption amounts, initiating unbonding periods (triggering internal `unstake_xinit` which uses `cosmos::move_execute` to call `process_xinit_unstake`), and creating user-specific `UnbondingEntry` claims. 
    *   Manages the **LP** unstaking process as well as reward compounding etc.
    *   Allows users to claim their underlying **xINIT** assets after the unbonding period completes (`claim_unbonded_assets`).
    *   Configures and manages different staking pools (e.g., sxINIT pool, various LP token pools) via admin/manager functions like `config_stake_token`, `set_unbond_period`.
    *   Interacts with `pool_router` to delegate stake (`pool_router::add_stake`), trigger reward claims (`pool_router::request_claim_rewards`), and withdraw rewards/assets (`pool_router::withdraw_rewards`, `pool_router::withdraw_assets`).
    *   Handles compounding of staking rewards (`compound_xinit_pool_rewards`, `compound_lp_pool_rewards`) - *LP compounding logic requires careful review*.
    *   Provides entry points for the admin/manager to cast votes in the Initia VIP system (`vip::weight_vote`), either directly (`vote`) or based on bribe weights (`vote_using_bribe_weights`).
    *   Stores per-user data (`CabalStore`) related to unbonding entries and claimed voting rewards.
    *   Manages fees (`set_stake_xinit_fee_bps`, `set_xinit_stake_reward_fee_bps`) and fee exemptions (`init_fees_exempt`, `set_fees_exempt`).
*   **Key Interactions:** `cabal_token` (mint/burn/capabilities), `primary_fungible_store` (transfers), `cosmos` (via `pool_router` and `move_execute`), `bribe` (getting weights), `voting_reward` (updating claimed amounts), `pool_router`, `package`, `manager`, `emergency`.

**2. `cabal_token` Module (`sources/cabal_token.move`)**

*   **Responsibilities:**
    *   Defines and initializes Cabal-specific fungible assets (xINIT, sxINIT, Cabal LPTs) using `primary_fungible_store` and `dispatchable_fungible_asset` (`initialize`).
    *   Provides mint (`mint_to`), burn (`burn`), and potentially freeze capabilities for these tokens, primarily used by the `cabal` module via capability structs.
    *   Implements the lazy balance snapshotting mechanism:
        *   Stores user balances internally (`HolderStore` -> `CabalBalance`).
        *   Admin/Manager triggers a snapshot via `voting_reward::snapshot` which calls `cabal_token::snapshot()`, setting a global `snapshot_block`.
        *   On subsequent user interactions (mint/burn/deposit/withdraw via `get_mut_cabal_balance`), `check_snapshot` writes the user's pre-interaction balance to their personal `CabalBalance.snapshot` table if an entry for that `snapshot_block` doesn't exist.
        *   Provides `get_snapshot_balance` to retrieve a user's balance at a historical block height (using the lazy read logic: check table, fallback to current balance if no relevant entry).
    *   Allows admin/manager to update snapshot data based on L2 information (`update_l2_data`) - *Purpose and security implications require careful review*.
*   **Key Interactions:** `cabal` (provides capabilities, called for mint/burn), `voting_reward` (calls `get_snapshot_balance`, triggers `snapshot`), `primary_fungible_store` (underlying mint/burn/transfer), `package`.

**3. `bribe` Module (`sources/bribe.move`)**

*   **Responsibilities:**
    *   Allows external parties to deposit bribe rewards (`deposit_bribe`) for a specific cycle and `bridge_id`.
    *   Validates deposited tokens against an allowed list (`voting_reward_token_metadata`, configured via `set_allowed_bribe_tokens`).
    *   Validates `bridge_id` against the `vip` module.
    *   Calculates and deducts a commission fee (`deposit_voting_reward_fee_bps`, configured via `set_deposit_voting_reward_fee_bps`) from deposited bribes.
    *   Stores net bribe amounts in a nested table structure (`bribe`: cycle -> bridge_id -> token_metadata -> amount).
    *   Provides view functions (`calculate_bribe_weights_for_cycle`, `get_total_bribes_by_token_for_cycle`) to calculate the total value (in USD terms using oracles) of bribes per bridge for a cycle and to aggregate total bribes per token type for a cycle.
*   **Key Interactions:** `cabal` (calls `calculate_bribe_weights_for_cycle`), `voting_reward` (calls `get_total_bribes_by_token_for_cycle`), `emergency`, `vip`, `package`, `primary_fungible_store`, `oracle`.

**4. `voting_reward` Module (`sources/voting_reward.move`)**

*   **Responsibilities:**
    *   Admin/Manager triggers snapshots (`snapshot()`) of Cabal stake token supplies and voting weights at specific block heights (also calls `cabal_token::snapshot`).
    *   Admin/Manager links a reward cycle to a specific `snapshot_block_height` (`finalize_reward_cycle`), enabling reward calculations for that cycle.
    *   Calculates a user's total reward entitlement (`get_total_reward`, `get_single_reward`) by:
        *   Iterating through finalized cycles (`cycle_snapshot_map`).
        *   For each cycle, determining the user's weighted share (`get_cycle_reward_share`) based on their historical Cabal stake token balances (`cabal_token::get_snapshot_balance`) and the snapshot data (`snapshots` table: supply/weight).
        *   Multiplying the user's share by the total bribes deposited for that cycle (`bribe::get_total_bribes_by_token_for_cycle`).
    *   Allows users to claim their calculated rewards (`claim_voting_reward`) for one token type at a time.
    *   Interacts with the `cabal` module to track amounts already claimed by the user (`cabal::get_claimed_voting_reward_amount`, `cabal::update_claimed_voting_reward_amount`).
*   **Key Interactions:** `cabal` (gets weights, updates claimed amounts), `cabal_token` (gets snapshot balances, triggers `snapshot`), `bribe` (gets bribe amounts), `emergency`, `package`, `primary_fungible_store`.

**5. `pool_router` Module (`sources/pool_router.move`)**

*   **Responsibilities:**
    *   Manages `StakePool` objects, each representing a specific validator for a given staked token (`metadata`). Each pool has its own object address and `ExtendRef` for holding funds and signing messages.
    *   Maps staked token `metadata` to a list of associated `StakePool` objects (`PoolRouter.token_pool_map`).
    *   Provides functions (callable by `friend` module `cabal`) to interact with the underlying staking layers:
        *   `add_stake`: Deposits the `FungibleAsset` into the pool object's primary store and delegates it to the pool's validator (using `vip::lock_staking::delegate` via `move_execute` for INIT, or `cosmos::delegate` for LPs). Selects the most underutilized pool for the given token.
        *   `request_claim_rewards`: Triggers reward withdrawal from the underlying layers (using `vip::lock_staking::withdraw_delegator_reward` for INIT, or `cosmos::stargate::MsgWithdrawDelegatorReward` for LPs).
        *   `withdraw_rewards` / `withdraw_assets`: Withdraws accumulated rewards (INIT) or potentially other assets from all pool objects associated with a stake token. **Note: LP unstaking is not currently supported, so `withdraw_assets` primarily applies to INIT rewards or potentially admin recovery scenarios.**
    *   Provides admin/manager functions to configure the router:
        *   `add_pool`: Creates a new `StakePool` object for a token/validator pair.
        *   `change_validator`: Redelegates all stake within a `StakePool` object to a new validator (using `vip::lock_staking::redelegate` for INIT, or `cosmos::stargate::MsgBeginRedelegate` for LPs).
    *   Provides view functions to query pool information (`get_validators`, `get_stake_tokens`, `get_stakes`, `get_total_stakes`, `get_real_total_stakes`).
*   **Key Interactions:** `cabal` (calls friend functions), `package` (uses `utils::get_init_metadata`), `vip::lock_staking` (for INIT stake/redelegate/rewards), `cosmos` (for LP stake/redelegate/rewards), `primary_fungible_store` (deposit/withdraw from pool objects), `manager` (for `add_pool` auth).

## Key Data Structures

*   **`cabal::ModuleStore`**: Global state for staking. Holds fees, xINIT info, parallel vectors for pool configs (unbonding periods, stake/cabal token metadatas, capabilities, staked/reward amounts, pending undelegations), stake-to-cabal token map.
*   **`cabal::CabalStore`**: Per-user state. Holds `unbonding_entries` and `voting_reward_claimed_amount` map.
*   **`cabal::UnbondingEntry`**: Represents a user's specific claim during unbonding.
*   **`cabal_token::ModuleStore`**: Global state for token module, holds snapshot block info.
*   **`cabal_token::HolderStore`**: Per-token state. Contains `holder_balance_map` (user address -> `CabalBalance`).
*   **`cabal_token::CabalBalance`**: Per-user, per-token state. Holds current `balance`, `start_block`, and `snapshot` table (block height -> balance).
*   **`bribe::ModuleStore`**: Global state for bribes. Holds fee, allowed token list, and the main nested `bribe` table (cycle -> bridge_id -> token_metadata -> amount).
*   **`voting_reward::ModuleStore`**: Global state for reward distribution. Holds `cycle_snapshot_map` (cycle number -> snapshot block height) and `snapshots` table (block height -> snapshot data table).
*   **`voting_reward::SnapshotRecord`**: Stores the supply and weight of a specific Cabal stake token at a snapshot block height.
*   **`manager::Manager`**: Stores the current manager address.
*   **`manager::Role`**: Stores role admin and members.
*   **`emergency::PauseFlag`**: Stores the protocol pause state.
*   **`package::ModuleStore`**: Stores shared object `ExtendRef`s (resource account, assets store, reward store) and the `commission_fee_store_addr`.
*   **`pool_router::PoolRouter`**: Stores `token_pool_map` (token metadata -> vector of `StakePool` objects).
*   **`pool_router::StakePool`**: Represents a specific validator pool for a token, holding metadata, amount, `ExtendRef`, and validator address string.

## Core User Flows

**Please view the Images Below!**

https://docs.google.com/document/d/1Ttrb3CRS7WFIZVmt6pSMWfgMQSa8s0d0wAk3VHeaguM/edit?usp=sharing

**Please view the images above - they are very helpful!**


## External Dependencies & Interactions

*   **`initia_std`**: Core Move utilities, object model, fungible assets, primary store, tables, bigdecimal, block info, oracle.
*   **`cosmos`**: Interactions with underlying Cosmos SDK modules:
    *   `cosmos::delegate`: To stake LP tokens in `mstaking` (via `pool_router`).
    *   `cosmos::stargate::MsgUndelegate`: **(Currently Unused by User Flows)** To unstake LP tokens from `mstaking`.
    *   `cosmos::stargate::MsgWithdrawDelegatorReward`: To claim staking rewards (via `pool_router`).
    *   `cosmos::stargate::MsgBeginRedelegate`: To redelegate LP stake (via `pool_router`).
    *   `cosmos::move_execute`: To trigger hook functions (`process_*_stake`, `process_*_unstake`) in `cabal`.
*   **`vip`**:
    *   `vip::is_registered`: To validate bridge IDs in `bribe`.
    *   `vip::weight_vote::vote`: To cast Cabal's votes (`cabal::vote`).
    *   `vip::lock_staking`: Used by `pool_router` for INIT staking/redelegate/reward interactions and potentially external triggering of INIT undelegation.
*   **`dex`**: Used for LP reward compounding (`cabal::compound_lp_pool_rewards`).
*   **`oracle`**: Used by `bribe` to get USD prices for bribe valuation.

## Frequently Asked Questions (FAQ)

*   **How does a user stake INIT?**
    1.  User calls `cabal::deposit_init_for_xinit` with native INIT, receiving xINIT.
    2.  User calls `cabal::stake_asset` with xINIT. This triggers `cabal::process_xinit_stake` (via `move_execute`), which calculates the current xINIT/sxINIT ratio based on underlying staked INIT + rewards (obtained via `pool_router`), and mints the appropriate amount of sxINIT to the user. The underlying INIT is delegated via `pool_router::add_stake`.
*   **How does a user stake an LP token?**
    1.  User calls `cabal::stake_asset` with the whitelisted LP token.
    2.  This triggers `cabal::process_lp_stake` (via `move_execute`), which delegates the LP token to a validator via `pool_router::add_stake` (`cosmos::delegate`), calculates the current LP/Cabal-LPT ratio, and mints the corresponding Cabal LPT to the user.
*   **How does unstaking work?**
    *   **sxINIT:** User calls `cabal::initiate_unstake` with sxINIT. This burns the sxINIT and triggers `cabal::process_xinit_unstake` (via `move_execute`), which calculates the underlying xINIT amount based on the current ratio. An `UnbondingEntry` is created for the user. After the unbonding period (`cabal::ModuleStore.unbond_period[0]`), the user calls `cabal::claim_unbonded_assets` to receive their xINIT. *Note: The actual undelegation from `vip::lock_staking` needs to be triggered separately, likely by a keeper or admin action.*
    *   **Cabal LPT:** Please refer to the flowcharts provided.
*   **How does someone offer a bribe?**
    *   Anyone can call `bribe::deposit_bribe`, specifying the reward token (must be whitelisted), amount, target voting cycle, and target `bridge_id` (from the VIP module). The function transfers the tokens (minus a fee) to the reward store and records the bribe details.
*   **How are bribes used to influence voting?**
    *   The `cabal` module's admin/manager can call `cabal::vote_using_bribe_weights`. This function calls `bribe::calculate_bribe_weights_for_cycle` to determine the relative USD value of bribes offered for each `bridge_id` in a given cycle. These weights are then used to call `cabal::vote`, which submits votes to the `vip::weight_vote` module, allocating Cabal's total voting power according to the bribe weights.
*   **How does the snapshotting mechanism work?**
    *   See "Snapshotting Mechanism (`cabal_token`)" section above. It's a lazy write/read system triggered globally but recorded per-user upon interaction.
*   **How is a reward cycle (epoch) finalized?**
    1.  The Manager calls `voting_reward::snapshot()` at a chosen block height. This captures the total supply and voting weight of each Cabal stake token (sxINIT, Cabal LPTs) at that moment and triggers `cabal_token::snapshot()` to set the global snapshot block for lazy balance recording.
    2.  The Manager then calls `voting_reward::finalize_reward_cycle()`, providing a `cycle` number and the `block_height` of the snapshot taken in step 1. This links the cycle number to the captured state in the `cycle_snapshot_map`, making rewards for that cycle calculable. Bribes deposited via `bribe::deposit_bribe` for this `cycle` number are now associated with this finalized state.
*   **How are voting rewards calculated for a user?**
    *   See "Reward Calculation Logic (`voting_reward`)" section above. It involves calculating the user's proportional share of the total weighted voting power (based on their historical staked Cabal token balances from the relevant snapshot) for each finalized cycle and multiplying that share by the total bribes offered in that cycle.
*   **What is the role of the `manager.move` module?**
    *   It defines an administrative address (`Manager.manager_address`) separate from the deployer. Functions protected by `manager::is_authorized` can only be called by this address. It handles operational tasks like pausing, setting fees, configuring pools, managing roles, finalizing reward cycles, triggering snapshots, and potentially changing the manager address itself.
*   **What is the role of the deployer address (`@staking_addr`)?**
    *   It's the address that deployed the contracts and initially calls `init_module` functions. Crucially, it typically holds the power to *upgrade* the contract code on-chain (depending on platform setup). Some high-risk functions might remain restricted to the deployer even after launch (e.g., `pool_router::change_validator`, `package::set_commission_fee_store_addr`).
*   **How does the emergency pause work?**
    *   The Manager can call `emergency::set_pause` to set a global `PauseFlag`. Critical user-facing functions check this flag using `emergency::assert_no_paused()` and revert if the protocol is paused.
*   **How are staking rewards handled?**
    *   **INIT Rewards (for sxINIT):** `cabal::compound_xinit_pool_rewards` calls `pool_router::request_claim_rewards` (which uses `vip::lock_staking::withdraw_delegator_reward`) and then `pool_router::withdraw_rewards`. A fee is taken, and the rest is effectively added back to the pool (increasing the xINIT backing per sxINIT).
    *   **LP Rewards (e.g., INIT for LP stakers):** `cabal::compound_lp_pool_rewards` calls `pool_router::request_claim_rewards` (which uses `cosmos::stargate::MsgWithdrawDelegatorReward`) and then `pool_router::withdraw_rewards`. The claimed INIT rewards are then used to provide single-asset liquidity back into the DEX pool via `dex::single_asset_provide_liquidity`, and the resulting LP tokens are used to reward Cabal LP holders when they transfer back/unstake.
    *   **For both**, staking rewards are implicit, basically increasing the backing of the user's Cabal token to the original asset.
