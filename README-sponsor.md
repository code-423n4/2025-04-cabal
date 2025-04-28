# Cabal Protocol Smart Contracts - Auditor README

## Overview

This document provides an overview of the core smart contracts for the Cabal Protocol, focusing on the structure, interactions, and key mechanisms relevant for auditing. Cabal is a liquid staking protocol built on Initia, allowing users to stake INIT (via xINIT/sxINIT) and whitelisted LP tokens, while also participating in a bribe marketplace to influence Initia's VIP gauge voting. **Note: Unstaking of LP tokens is currently not supported.**

The primary modules involved in the core logic are:

*   **`cabal`**: The main staking engine and user interaction hub.
*   **`cabal_token`**: Manages Cabal-specific tokens (xINIT, sxINIT, Cabal LPTs) and implements the lazy balance snapshotting mechanism.
*   **`bribe`**: Handles the deposit and tracking of bribe rewards offered by external parties.
*   **`voting_reward`**: Calculates and distributes bribe rewards to eligible Cabal token holders based on historical snapshots.
*   **`pool_router`**: Acts as an abstraction layer managing interactions with underlying validators for different staked assets (INIT via `vip::lock_staking`, LPs via `mstaking`).

Other relevant modules include `package` (shared addresses/signers), `manager` (admin controls), `emergency` (pausing), `utils` (helpers), and interactions with Initia standard library modules (`fungible_asset`, `primary_fungible_store`, `cosmos`, `vip`, `dex`, `object`, `table`, etc.).

## Core Modules and Responsibilities

**1. `cabal` Module (`sources/cabal.move`)**

*   **Responsibilities:**
    *   Handles user deposits of native INIT to mint xINIT (`deposit_init_for_xinit`).
    *   Manages the staking process where users lock underlying tokens (xINIT or LP tokens) to mint Cabal liquid staking tokens (sxINIT or Cabal LPTs) (`stake_asset`, triggering internal `stake_xinit` or `stake_lp` which use `cosmos::move_execute` to call `process_xinit_stake` or `process_lp_stake`).
    *   Manages the **sxINIT** unstaking process (`initiate_unstake`), including calculating redemption amounts, initiating unbonding periods (triggering internal `unstake_xinit` which uses `cosmos::move_execute` to call `process_xinit_unstake`), and creating user-specific `UnbondingEntry` claims. **LP unstaking is not currently supported via this function.**
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
*   **`cabal::CabalStore`**: Per-user state. Holds `unbonding_entries` (for sxINIT) and `voting_reward_claimed_amount` map.
*   **`cabal::UnbondingEntry`**: Represents a user's specific claim during sxINIT unbonding.
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

## Core User Flows (Simplified)

*   **xINIT/sxINIT Staking:**
    1.  `cabal::deposit_init_for_xinit` (User deposits INIT, receives xINIT).
    2.  `cabal::stake_asset` (User stakes xINIT).
    3.  -> `cabal::stake_xinit` -> `cosmos::move_execute` -> `cabal::process_xinit_stake` (Calculates ratio, mints sxINIT via `cabal_token::mint_to`). *Note: Underlying INIT delegation happens via `pool_router::add_stake` -> `vip::lock_staking::delegate`.*
*   **xINIT/sxINIT Unstaking:**
    1.  `cabal::initiate_unstake` (User unstakes sxINIT).
    2.  -> `cabal_token::burn` & `cabal::unstake_xinit` -> `cosmos::move_execute` -> `cabal::process_xinit_unstake` (Calculates underlying xINIT amount, creates `UnbondingEntry`). *Note: Underlying INIT undelegation likely needs separate handling via `vip::lock_staking`, triggered externally (e.g., keeper/admin).*
    3.  `cabal::claim_unbonded_assets` (User claims xINIT after unbonding period).
*   **LP Staking:**
    1.  `cabal::stake_asset` (User stakes LP token).
    2.  -> `cabal::stake_lp` -> `cosmos::move_execute` -> `cabal::process_lp_stake` (Delegates LP via `pool_router::add_stake` -> `cosmos::delegate`, calculates ratio, mints Cabal LPT via `cabal_token::mint_to`).
*   **~~LP Unstaking:~~** **(Functionality Removed)**
*   **Bribing (Minitia POV):**
    1.  `bribe::deposit_bribe` -> `primary_fungible_store::transfer` & updates `bribe` table.
*   **Claiming Bribes (User POV):**
    1.  `voting_reward::claim_voting_reward`
    2.  -> `voting_reward::get_single_reward` -> `voting_reward::get_cycle_reward_share` -> `cabal_token::get_snapshot_balance` & `bribe::get_total_bribes_by_token_for_cycle`.
    3.  -> `cabal::update_claimed_voting_reward_amount`.
    4.  -> `primary_fungible_store::transfer` (from reward store).

## Snapshotting Mechanism (`cabal_token`)

*   **Lazy Write:** Snapshots triggered globally (`voting_reward::snapshot` -> `cabal_token::snapshot`), but balances written to per-user storage (`CabalBalance.snapshot`) only upon user interaction post-snapshot (`check_snapshot`).
*   **Lazy Read:** `get_snapshot_balance` checks the user's snapshot table first. If no entry for the requested block height, it returns the current balance (assuming inactivity).
*   **Coordination:** `voting_reward::snapshot` captures token supplies/weights and calls `cabal_token::snapshot` in the same transaction to conceptually align state and balance snapshots.

## Reward Calculation Logic (`voting_reward`)

1.  Identify finalized cycles (`cycle_snapshot_map`).
2.  For each cycle, get snapshot block height and data (`snapshots` table).
3.  Calculate user's share for the cycle (`get_cycle_reward_share`):
    *   For each Cabal stake token (sxINIT, Cabal LPTs):
        *   Get user's balance at snapshot block (`cabal_token::get_snapshot_balance`).
        *   Get token's total supply and voting weight from snapshot data.
        *   `user_share_for_token = (user_balance / total_supply) * token_weight`.
    *   Sum `user_share_for_token` across all tokens held = `total_share`.
4.  Get total bribes for the cycle per token (`bribe::get_total_bribes_by_token_for_cycle`).
5.  User's reward for a specific bribe token = `total_share * total_bribes_of_that_token`.
6.  Sum across relevant cycles for total entitlement.

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
    *   **Cabal LPT:** **Unstaking of Cabal LPTs is not currently supported.**
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
*   **How does a user claim their voting rewards (including from previous cycles)?**
    1.  The user calls `voting_reward::claim_voting_reward`, specifying the `metadata` of the *bribe token* they wish to claim (e.g., USDC, INIT).
    2.  The function internally calls `voting_reward::get_single_reward`. This function iterates through *all* cycles that have been finalized (recorded in `voting_reward::ModuleStore.cycle_snapshot_map`).
    3.  For each finalized cycle, it retrieves the corresponding snapshot block height and calculates the user's reward share for that cycle based on their historical staked balances (`cabal_token::get_snapshot_balance`) at that snapshot height.
    4.  It multiplies the user's share for that cycle by the total amount of the *requested bribe token* deposited for that cycle (`bribe::get_total_bribes_by_token_for_cycle`).
    5.  It sums these calculated amounts across all finalized cycles to get the user's *total entitlement* for the specified bribe token.
    6.  It checks how much of this token the user has *already claimed* by reading `cabal::get_claimed_voting_reward_amount` from the user's `CabalStore`.
    7.  It calculates the `remain_amount` (total entitlement - already claimed).
    8.  It updates the user's claimed amount in `CabalStore` via `cabal::update_claimed_voting_reward_amount`.
    9.  It transfers the `remain_amount` of the bribe token from the central reward store (`package::get_reward_store_address`) to the user.
    *   **Key Point:** Users claim rewards per bribe token type, accumulating rewards across all past finalized cycles in a single transaction for that token. They don't need to claim cycle by cycle.
*   **What is the role of the `manager.move` module?**
    *   It defines an administrative address (`Manager.manager_address`) separate from the deployer. Functions protected by `manager::is_authorized` can only be called by this address. It handles operational tasks like pausing, setting fees, configuring pools, managing roles, finalizing reward cycles, triggering snapshots, and potentially changing the manager address itself.
*   **What is the role of the deployer address (`@staking_addr`)?**
    *   It's the address that deployed the contracts and initially calls `init_module` functions. Crucially, it typically holds the power to *upgrade* the contract code on-chain (depending on platform setup). Some high-risk functions might remain restricted to the deployer even after launch (e.g., `pool_router::change_validator`, `package::set_commission_fee_store_addr`).
*   **How does the emergency pause work?**
    *   The Manager can call `emergency::set_pause` to set a global `PauseFlag`. Critical user-facing functions check this flag using `emergency::assert_no_paused()` and revert if the protocol is paused.
*   **How are staking rewards handled?**
    *   **INIT Rewards (for sxINIT):** `cabal::compound_xinit_pool_rewards` calls `pool_router::request_claim_rewards` (which uses `vip::lock_staking::withdraw_delegator_reward`) and then `pool_router::withdraw_rewards`. A fee is taken, and the rest is effectively added back to the pool (increasing the xINIT backing per sxINIT).
    *   **LP Rewards (e.g., INIT for LP stakers):** `cabal::compound_lp_pool_rewards` calls `pool_router::request_claim_rewards` (which uses `cosmos::stargate::MsgWithdrawDelegatorReward`) and then `pool_router::withdraw_rewards`. The claimed INIT rewards are then used to provide single-asset liquidity back into the DEX pool via `dex::single_asset_provide_liquidity`, and the resulting LP tokens are used to reward Cabal LP holders when they transfer back/unstake.
