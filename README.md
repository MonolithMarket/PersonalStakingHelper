# Personal Staking Helper

Stake a Monolith Coin in its DAO's existing GOV rewards pool in one transaction,
after Coin approval. For sCoin pools, the helper deposits into the vault and
stakes the resulting sCoin; for direct-Coin pools, it stakes the Coin. It uses
the existing accounting, with one separate position per user and DAO.

This is standalone periphery for Monolith governance. Earlier discussion is
preserved in [Monolith #60](https://github.com/MonolithMarket/Monolith/pull/60)
and [GovernanceFactory #12](https://github.com/MonolithMarket/GovernanceFactory/pull/12).

## Deployment

Deploy `PersonalStakingHelperFactory(coinDAOFactory)` once per trusted
CoinDAOFactory and chain. The constructor creates the shared implementation.
Verify the registry address and chain before deployment.

The factory supports existing and future DAO records whose staking token is
their Coin or Monolith vault. Each helper is also bound to its DAO's registered
GOV staking contract. No per-coin registration, seed funds or additional factory
deployment is required. Each
user's helper is created automatically on their first successful deposit and
reused on later deposits.

The registry must use the CoinDAOFactory v2 fourteen-address deployment layout
covered by the pinned governance dependency. A different governance factory or
incompatible registry requires a separate helper factory.

## Integrate

1. Approve the Coin to the helper factory.
2. Call `depositAndStake(daoId, assets, minShares)` on the factory.
3. Find the position through `helperOf(daoId, owner)`. Zero means no helper has
   been created successfully for that owner and DAO.

`daoId` is the CoinDAOFactory deployment index, not the Monolith market index.
Approval is a separate transaction unless the user's smart account batches it.
The caller funds and owns the position; there is no arbitrary payer or receiver.

Owner actions on the helper:

| Method | Result |
| --- | --- |
| `claim()` | Claims GOV and forwards the helper's entire loose GOV balance to its owner. |
| `claimAndStake()` | Claims GOV and stakes the helper's entire loose GOV balance directly for its owner. |
| `withdraw(shares, claimRewards)` | Unstakes the pool's Coin or sCoin to the owner. |
| `withdrawAndRedeem(shares, minAssets, claimRewards)` | For sCoin pools only, unstakes and redeems sCoin to Coin for the owner. |
| `recoverToken(token)` | Returns loose tokens to the owner without touching the staked position. |

Both withdrawal routes optionally claim GOV in the same transaction. If a claim
fails, the combined transaction reverts; retry with `claimRewards=false` to exit
without calling the rewards payout. Unpaid rewards remain claimable after a
full principal exit. Failures in the vault, pool or Coin can still prevent exits.

`claimAndStake()` requires no GOV approval from the owner. The helper approves
the registered GOV staking contract for the exact amount and clears it after
use. The non-transferable stGOV receipt belongs directly to the owner, who
retains withdrawal, rewards and delegation rights. First-time voting delegation
is separate. GOV staking harvests revenue; if it fails, the whole transaction
reverts and plain `claim()` remains available. A zero GOV balance skips staking.

For sCoin pools, use the vault's previews to set minimum outputs. Its first
deposit permanently locks `1e16` shares; the helper checks the actual shares
received. Transactions
have no expiry, and output limits do not guarantee a GOV reward rate. For direct
Coin pools, `shares` and `minShares` are Coin units and no vault yield is earned.

For the UI, read `stakedShares()` and `earned()` from the helper, and value its
staked shares using the vault's conversion methods for sCoin pools, or directly
as Coin units for direct-Coin pools. Total claimable GOV also
includes any loose GOV balance at the helper. Wallet-held sCoin and direct pool
stakes are separate positions. This helper creates no transferable receipt token.

## Security assumptions

Owner and market are fixed during atomic helper creation. There is no admin,
upgrade path, ownership transfer or arbitrary-call function. Withdrawals,
rewards and recovered tokens always go to the owner. Helper allowances are
exact and cleared after use; entry points use reentrancy guards.

The registry and its linked Monolith, StakingRewards and GOV staking
implementations are trusted. Coin and GOV must transfer exact amounts and maintain stable balances;
fee-on-transfer and rebasing tokens are unsupported. The helper does not fund
reward schedules or move existing wallet stakes automatically. Direct wallet
stakes and their previously accrued GOV remain separate. Moving a stake into
the helper requires withdrawing it and depositing through the helper factory;
previously accrued GOV remains claimable from the original account. The helper
implementation is fixed; existing deployed
helpers cannot acquire this new function through an upgrade.

## Build and test

Initialize the pinned submodules and run these commands with Foundry v1.8.5:

```sh
git submodule update --init --recursive
forge build --root integration/monolith --use 0.8.24
forge test --use 0.8.26 -vv
forge test --root integration/monolith --use 0.8.24 -vv
forge test --root lib/monolith-gov --use 0.8.26 -vv
```

Dependencies are pinned in the gitlinks and `foundry.lock`. Monolith sources
compile unchanged with Solidity 0.8.24; helpers and governance compile with
0.8.26. The integration tests load native artifacts across compiler versions.
No RPC, credentials or environment files are needed.

Tests cover ownership, initialization, slippage, claims and failed payouts,
reentrancy, donations, multiple users/DAOs, fuzzed exits and stateful invariants.
Full integration scenarios launch actual Monolith lending markets and
CoinDAOFactory rewards pools, including existing-market attachment. Only their
external collateral and price feed are simulated. CI also runs the pinned
governance regression suite.
