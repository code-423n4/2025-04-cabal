# Cabal audit details
- Total Prize Pool: $23,000 in USDC
  - HM awards: up to $20,000 USDC (Notion: HM (main) pool)
    - If no valid Highs or Mediums are found, the HM pool is $0 
  - Judge awards: $2,500 in USDC
  - Scout awards: $500 in USDC
- [Read our guidelines for more details](https://docs.code4rena.com/roles/wardens)
- Starts April 28, 2025 20:00 UTC 
- Ends May 5, 2025 20:00 UTC 

**Note re: risk level upgrades/downgrades**

Two important notes about judging phase risk adjustments: 
- High- or Medium-risk submissions downgraded to Low-risk (QA) will be ineligible for awards.
- Upgrading a Low-risk finding from a QA report to a Medium- or High-risk finding is not supported.

As such, wardens are encouraged to select the appropriate risk level carefully during the submission phase.

## Automated Findings / Publicly Known Issues

_Note for C4 wardens: Anything included in this `Automated Findings / Publicly Known Issues` section is considered a publicly known issue and is ineligible for awards._

### Donation Inflation Attack

Someone can donate a huge amount of raw `INIT` (to the tune of millions) to the pool without getting anything in return which would then cause an inflation attack as the new stakers would get a minuscule amount of `sxINIT` when staking.

Due to the absence of economic incentives around the attack, we consider it to be an acknowledged risk of the system.

### Snapshot Balance Queries

Evaluating the balance of a user at a block height where a snapshot has not been taken is inaccurate. This is acceptable behaviour as the system concerns itself with accurate user balances after a snapshot has been taken.

### L2 Desynchronization

When tokens are bridged to an L2, the system will lose track of them. In such cases, we trust that the L2 will provide the necessary data (balances, etc.) for us.

### Rounding Errors

Miniscule decimal rounding of `<1` unit may be observed when large numbers are utilized across the system.

### Price Guarantees

Any issues around oracles misbehaving, misconfigured Time-Weighted Average Price (TWAP) setups, or other administrative / external misbehaviours are considered out-of-scope.

### Stake Slashing

The system has been adequately equipped to handle slashing risks by querying the true staked amounts of a validator wherever needed.

# Overview

Cabal is a liquid staking protocol built on Initia, allowing users to stake INIT (via xINIT/sxINIT) and whitelisted LP tokens, while also participating in a bribe marketplace to influence Initia's VIP gauge voting.

For an in-depth technical overview of the system including user flows, please consult the [relevant documentation](https://github.com/code-423n4/2025-04-cabal/blob/main/DOCUMENTATION.md) of the project. This link presently points to the C4 GitHub repository documentation and will be updated during the contest to a live documentation link.

## Links

The system has undergone two distinct audits with Zenith and Zellic. While the reports are not presently available, all issues have been fixed except for one known issue that has been explicitly outlined.

- **Previous audits:**  
  - Private Zellic Audit Report
  - Private Zenith Audit Report
- **Documentation:**
  - High-Level: https://thecabal.xyz/docs/cabal
  - Technical: https://github.com/code-423n4/2025-04-cabal/blob/main/DOCUMENTATION.md *
- **Website:** https://thecabal.xyz/
- **X/Twitter:** https://x.com/CabalVIP
- **Discord:** https://discord.gg/thecabal

*\* This link will be updated during the contest to a live version of the project's documentation*

---

# Scope

Any test implementations within in-scope files (f.e. `fun` declarations prefixed with `[#test-only]`) are considered out-of-scope for the purposes of the contest. Additionally, `TODO` comments in relation to the configuration of the system are considered known issues.

The current state of the codebase is meant for a `TESTING` environment to ensure that the project's test suites run as smoothly as possible. 

**There are two instances in the code where this can be observed and needs to be changed to achieve a production-ready state of the system**:

- `cabal.move`
    - `cabal::initialize`: The `// USE THIS FOR PROD` function variant should be considered in scope as the `// USE THIS FOR TESTING` variant is not meant for production
- `snapshots.move`
    - `snapshots::update_snapshot`: The `mock_voting_power_weight` invocation should be commented out and the preceding `pool_router::get_voting_power_weight` invocation should be uncommented as the `mock_voting_power_weight` function is out-of-scope

### Files in scope

| Contract | SLOC | Purpose | Libraries used |  
| ----------- | ----------- | ----------- | ----------- |
| [sources/bribe.move](https://github.com/code-423n4/2025-04-cabal/blob/main/sources/bribe.move) | 317 | Handles the deposit and tracking of bribe rewards offered by external parties | `std`, `initia_std`|
| [sources/cabal.move](https://github.com/code-423n4/2025-04-cabal/blob/main/sources/cabal.move) | 993 | The main staking engine and user interaction hub | `std`, `initia_std`, `vip` |
| [sources/cabal_token.move](https://github.com/code-423n4/2025-04-cabal/blob/main/sources/cabal_token.move) | 352 | Manages Cabal-specific tokens (xINIT, sxINIT, Cabal LPTs) and implements the lazy balance snapshotting mechanism | `std`, `initia_std` |
| [sources/package.move](https://github.com/code-423n4/2025-04-cabal/blob/main/sources/package.move) | 81 | Shared addresses / signers, manages commission fee storage address  | `std`, `initia_std` |
| [sources/pool_router.move](https://github.com/code-423n4/2025-04-cabal/blob/main/sources/pool_router.move) | 480 | Acts as an abstraction layer managing interactions with underlying validators for different staked assets  | `std`, `initia_std`, `vip` |
| [sources/snapshots.move](https://github.com/code-423n4/2025-04-cabal/blob/main/sources/snapshots.move) | 124 | Utility implementation for snapshots  | `std`, `initia_std` |
| [sources/utils.move](https://github.com/code-423n4/2025-04-cabal/blob/main/sources/utils.move) | 65 | Oracle-related utility functions  | `std`, `initia_std` |
| [sources/voting_reward.move](https://github.com/code-423n4/2025-04-cabal/blob/main/sources/voting_reward.move) | 162 | Calculates and distributes bribe rewards to eligible Cabal token holders based on historical snapshots  | `std`, `initia_std` |
| **Total SLoC** | 2574 | | |


*See [scope.txt](https://github.com/code-423n4/2025-04-cabal/blob/main/scope.txt) for a machine-friendly list of in-scope files for the contest*

### Files out of scope

| File         |
| ------------ |
| vip-contract/\*\*.\*\* |
| sources/emergency.move |
| sources/manager.move |
| tests/bribing_test.move |
| tests/core_staking_test.move |
| tests/core_unstaking_test.move |
| tests/deployer_auth_test.move |
| tests/emergency_stop_test.move |
| tests/lp_voting_test.move |
| tests/snapshot_test.move |
| tests/xinit_voting_test.move |
| Totals: 8 |

*See [out_of_scope.txt](https://github.com/code-423n4/2025-04-cabal/blob/main/out_of_scope.txt) for a machine-friendly list of out-of-scope files for the contest*

## Scoping Q &amp; A

### General questions

| Question                                | Answer                       |
| --------------------------------------- | ---------------------------- |
| ERC20 used by the protocol              |              Cabal LPTs, xINIT, sxINIT       |
| Test coverage                           | ~76.94% Total, ~70.54% Scope*                          |
| ERC721 used  by the protocol            |            No              |
| ERC777 used by the protocol             |           No                |
| ERC1155 used by the protocol            |              No            |
| Chains the protocol will be deployed on | Initia (MoveVM)  |

*\* The practical code coverage of the system is significantly higher as several real-world user flows have been tested albeit with mock implementations due to the difficulty in executing live-code integrations in test suites*

### ERC20 token behaviors in scope

| Question                                                                                                                                                   | Answer |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| [Missing return values](https://github.com/d-xo/weird-erc20?tab=readme-ov-file#missing-return-values)                                                      |   No  |
| [Fee on transfer](https://github.com/d-xo/weird-erc20?tab=readme-ov-file#fee-on-transfer)                                                                  |  No  |
| [Balance changes outside of transfers](https://github.com/d-xo/weird-erc20?tab=readme-ov-file#balance-modifications-outside-of-transfers-rebasingairdrops) | No    |
| [Upgradeability](https://github.com/d-xo/weird-erc20?tab=readme-ov-file#upgradable-tokens)                                                                 |   No  |
| [Flash minting](https://github.com/d-xo/weird-erc20?tab=readme-ov-file#flash-mintable-tokens)                                                              | No    |
| [Pausability](https://github.com/d-xo/weird-erc20?tab=readme-ov-file#pausable-tokens)                                                                      | No    |
| [Approval race protections](https://github.com/d-xo/weird-erc20?tab=readme-ov-file#approval-race-protections)                                              | No    |
| [Revert on approval to zero address](https://github.com/d-xo/weird-erc20?tab=readme-ov-file#revert-on-approval-to-zero-address)                            | No    |
| [Revert on zero value approvals](https://github.com/d-xo/weird-erc20?tab=readme-ov-file#revert-on-zero-value-approvals)                                    | No    |
| [Revert on zero value transfers](https://github.com/d-xo/weird-erc20?tab=readme-ov-file#revert-on-zero-value-transfers)                                    | No    |
| [Revert on transfer to the zero address](https://github.com/d-xo/weird-erc20?tab=readme-ov-file#revert-on-transfer-to-the-zero-address)                    | No    |
| [Revert on large approvals and/or transfers](https://github.com/d-xo/weird-erc20?tab=readme-ov-file#revert-on-large-approvals--transfers)                  | No    |
| [Doesn't revert on failure](https://github.com/d-xo/weird-erc20?tab=readme-ov-file#no-revert-on-failure)                                                   |  No   |
| [Multiple token addresses](https://github.com/d-xo/weird-erc20?tab=readme-ov-file#revert-on-zero-value-transfers)                                          | No    |
| [Low decimals ( < 6)](https://github.com/d-xo/weird-erc20?tab=readme-ov-file#low-decimals)                                                                 |   Yes  |
| [High decimals ( > 18)](https://github.com/d-xo/weird-erc20?tab=readme-ov-file#high-decimals)                                                              | Yes    |
| [Blocklists](https://github.com/d-xo/weird-erc20?tab=readme-ov-file#tokens-with-blocklists)                                                                | No    |

### External integrations (e.g., Uniswap) behavior in scope:


| Question                                                  | Answer |
| --------------------------------------------------------- | ------ |
| Enabling/disabling fees (e.g. Blur disables/enables fees) | No   |
| Pausability (e.g. Uniswap pool gets paused)               |  No   |
| Upgradeability (e.g. Uniswap gets upgraded)               |   No  |


### EIP compliance checklist

N/A

# Additional context

## Main invariants

### `xINIT` Total Supply

The total supply of `INIT` locked in the system should approximately equate the total supply of `xINIT`.

$$
total\\_init\\_locked \approx total\\_supply\\_xinit
$$

### `xINIT` / `INIT` Ratio

A unit of `xINIT` should approximately equate a unit of `INIT`, ignoring fees, slashing, and other mechanisms that might affect the conversion rate.

$$
1\ xINIT \approx 1\ INIT
$$

### Snapshot Balances

The sum of all individual snapshot balances (`cabal_token::get_snapshot_balance`) for a particular block height should equate the total snapshot supply (`cabal_token::get_snapshot_supply`) of the block height.

$$
\sum_{user=1}^{total\\_users}{get\\_snapshot\\_balance(user,token,block\\_height)} = get\\_snapshot\\_supply(token,block\\_height)
$$

### Cycle Reward Shares

The sum of `voting_reward::get_cycle_reward_share` measurements for all users should equate `1` for all `block_height` values that are linked to a cycle end (i.e. have been snapshotted) and wherein bribes have been observed.

$$
\sum_{user=1}^{total\\_users}{get\\_cycle\\_reward\\_share(user, block\\_height)} \approx 1, block\\_height \in past\\_snapshot
$$

If no bribes have been observed in a particular cycle that has ended, then the sum should equate `0`.

$$
\sum_{user=1}^{total\\_users}{get\\_cycle\\_reward\\_share(user, block\\_height)} = 0, block\\_height \in past\\_snapshot
$$

For any `block_height` that has not been snapshotted the result of this sum is indeterminate (i.e. can be any value).

### Cycle Bribe Weights

The sum of individual weights in the calculation result of bribe weights for a particular cycle (`bribe::calculate_bribe_weights_for_cycle`) should approximately equate `1`. 

In other words, the sum of the weights of each individual Minitia (L2 bridge supported) should reach very close to or equate `1`.

$$
cycle\\_bribe\\_weights = calculate\\_bribe\\_weights\\_for\\_cycle(cycle)
$$

$$
\sum_{n=0}^{length(cycle\\_bribe\\_weights)}{cycle\\_bribe\\_weights[n]} \approx 1, cycle \in calculated\\_cycles
$$

For any `cycle` that has not been observed the result of this sum is indeterminate (i.e. can be any value).

## Attack ideas (where to focus for bugs)

### Function Correctness Focus

We are most interested in any vunlerabilities or bugs revolving around the following functions:

- `sources/cabal.move`
    - `deposit_init_for_xinit`
    - `process_xinit_stake`
    - `process_lp_stake`
    - `process_xinit_unstake`
    - `process_lp_unstake`
- `sources/cabal_token.move`
    - `get_snapshot_balance`
- `sources/bribe.move`
    - `deposit_bribe`
- `sources/voting_reward.move`
    - `get_cycle_reward_share`
    
### Snapshotting Process

The snapshotting process implemented in `sources/cabal_token.move` cannot be manipulated in any way, both in terms of its validity during the maintenance of the snapshot as well as after it has been finalized.

### Bribes & Voting Funds

Regardless of the outcome of bribes and voting as well as the processes involved, user principle amounts (`xINIT`, `sxINIT`, and `Cabal LPTs`) remain safe.

## All trusted roles in the protocol

| Role                                | Description                       |
| --------------------------------------- | ---------------------------- |
| **Deployer**                          | **Pool Router** (`pool_router`)<br>- Can change the validator of the pool router (`change_validator`)<br>**Package** (`package`)<br>- Can configure the commission fee address for bribes (`set_commission_fee_store_addr`)<br>**Cabal Token** (`cabal_token`)<br>- Can initialize the `cabal_token` implementation (`initialize`)<br>**Any Module**<br>- Can initialize several modules (`init_module`)|
| **Manager**   | **Manager** (`manager`)<br>- Can request a change of the manager address (`change_manager_address`)<br>- Can create roles and set their administrators (`create_role`, `set_role_admin`)<br>**Emergency** (`emergency`)<br>- Can set an emergency pause (`set_pause`)<br>**Cabal Token** (`cabal_token`)<br>- Can update L2 snapshot data (`update_l2_data`)<br>**Voting Rewards** (`voting_reward`)<br>- Can snapshot voting rewards (`snapshot`)<br>- Can finalize a voting reward cycle (`finalize_reward_cycle`)<br>**Cabal** (`cabal`)<br>- Can configure the stake token (`config_stake_token`)<br>- Can issue VIP votes (`vote`, `vote_using_bribe_weights`)<br>- Can exempt an address from fees (`init_fees_exempt`)<br>**Pool Router** (`pool_router`)<br>- Can add a pool to the pool router (`add_pool`)|
| **Pending Manager** | **Manager** (`manager`)<br>- Can accept a manager change (`accept_manager_proposal`) |
| **Role Administrator** | **Manager** (`manager`)<br>- Can add and remove role members (`add_role_member`, `remove_role_member`)<br>- Can renounce administratorship of a role (`renounce_role_admin`) |

## Describe any novel or unique curve logic or mathematical models implemented in the contracts:

The mechanism utilized for snapshotting involves lazy writes to save on gas; an approach that is unique to this project.

## Running tests

### Prerequisites

The project requires the `initiad` toolkit of the Initia project to compile the `move` codebase. Specifically:

- [initiad v1.0.0-beta.8](https://github.com/initia-labs/initia/tree/v1.0.0-beta.8)

The `initiad` toolkit has a direct dependency to Golang, so please make sure you have [Golang](https://go.dev/doc/install) setup for your machine. The compilation instructions were tested with Golang `v1.24.2`.

### Building & Testing

The project relies on several `#test-only` preprocessing flags and thus cannot be compiled via the `initiad move build` command. 

Additionally, the `vip-contract` dependency's compilation seems to fail even if the `initiad move build --test` flag is specified due to a potential compiler bug.

Instead, the `initiad move test` command should be issued to simultaneously compile the codebase and run tests:

```bash 
initiad move test
```

### Code Coverage

In order to generate code coverage, the `initiad move test` command should be issued alongside the `--test` and `--coverage` flags:

```bash
initiad move test --coverage --test
```

## Miscellaneous

Employees of Cabal and employees' family members are ineligible to participate in this audit.

Code4rena's rules cannot be overridden by the contents of this README. In case of doubt, please check with C4 staff.


