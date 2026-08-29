# Apex Audit Context

This file records the intended architecture, intentional product deltas, and known accepted caveats for the Apex audit scope. The project generally preserves compatibility with established upstream designs where practical, especially in the Pancake-style CL stack and periphery.

Last reconciled for audit: 2026-08-29 against contract source tree `af289dce21d2efb13b7c22ac6ee3c3b5624a0659`. The immutable repository handoff commit is recorded separately so this document does not attempt to self-reference its own commit hash.

This is triage context, not a request to suppress independent validation. Auditors should verify every developer response against the reviewed source. The public auditor mirror contains `src`, non-deployment tests, vendored libraries, and this file. Deployment configuration, broadcast records, signing operations, and private release automation are outside that public mirror unless supplied separately.

## Current Architecture

Apex is a Classic + CL DEX with a Pancake-compatible CL stack and Apex-specific protocol control, emissions, fee routing, veNFT, and vault layers.

- `src/core`: Classic pools/factory, CL core, chefs, `ApexController`, `FeeCenter`, `FeeReceiver`, `VeApexToken`, `ApexVault`, storage, and core libraries.
- `src/periphery`: NFP manager, routers, quoters, tick lens, multicall, periphery interfaces, and periphery libraries.
- `test`: Forge unit, integration, fuzz, symbolic, and gas tests. The private deployment-lifecycle test is not part of the public mirror.
- Companion SDK: maintained in a separate repository and outside this contracts-repository audit scope; references below describe integration expectations only.

Main modules:

- `ClassicPool` / `ClassicFactory`: Solidly-style volatile and stable ERC20 LP pools.
- `ClassicRouter`: Classic liquidity add/remove plus atomic add-and-stake flows into `ClassicChef`.
- `CLPool` / `CLFactory` / `CLPoolDeployer`: Pancake-style concentrated liquidity pools.
- `NonfungiblePositionManager`, routers, quoters, multicall/lens: Pancake-style periphery with Apex mixed-route additions.
- `ClassicChef` and `CLMasterChef`: controller-driven emissions for Classic LPs and CL NFTs.
- `ApexController`: upgradeable role and command surface for protocol setup, fees, farms, emissions, treasury routing, FeeCenter, Vault, and VeApexToken controls. Fee-policy logic is split into `ApexControllerFeePolicy` for bytecode-size headroom.
- `FeeCenter` and `FeeReceiver`: protocol fee intake, receiver registry, fee splitting, whitelisted swapper execution, and Vault notification.
- `VeApexToken` and `ApexVault`: upgradeable lock NFT plus multi-output reward streaming/compound vault.

## Source Map

- `ClassicPool` and `ClassicFactory`: Solidly-style Pair and PairFactory base.
- `CLPool`, `CLFactory`, `CLPoolDeployer`, CL libraries, callbacks, and CL periphery: Pancake V3 / Pancake CL base.
- `CLMasterChef`: Pancake `MasterChefV3` base, with boost removed and controller-driven emissions replacing Pancake owner/operator upkeep.
- `LmPool` and `LmPoolDeployer`: Pancake V3 LM pool base, with Apex naming and controller-compatible reward source.
- `ClassicChef`: JoeV2/Sushi-style pid-based ERC20 MasterChef shape, with no owner minting, no dev/treasury/investor cuts, no secondary rewarder hooks, and controller-paid APEX rewards.
- `VeApexToken`: current veAERO `VotingEscrow` normal-lock mechanics, made transparent-upgradeable with namespaced storage, with 26-week max lock, managed NFTs removed, permanent locks removed, voting hooks removed, and split removed.

## Authority And Upgrades

`ApexController` is the runtime role hub.

- `DEFAULT_ADMIN_ROLE`: multisig high authority for protocol setup, farm activation/deactivation, global fee controls, treasury rotation, receiver registry, rescue/sweep paths, and controller role grants/revokes.
- `FEE_OPERATOR`: per-pool fee/protocol-fee overrides, batch application of ungauged protocol-fee defaults, fee splitting, receiver swaps, receiver-to-vault notifications, and CL/Classic protocol-fee collection.
- `EMISSION_OPERATOR`: `rebalanceEmissions`.
- `VAULT_OPERATOR`: direct Vault notifications and batched compound calls.

`ApexController`, `VeApexToken`, `ApexVault`, and `FeeCenter` are deployed behind OpenZeppelin transparent proxies. Proxy admin ownership is separate from controller runtime roles.

All Apex-owned transparent-upgradeable contracts keep mutable project state behind storage libraries under `src/core/storage`. Inherited OpenZeppelin upgradeable state keeps its upstream layout.

## Intentional Product Deltas

### Classic

- Classic protocol fees are minted lazily as LP tokens, following Solidly-style `_mintFee`.
- Ungauged Classic pairs start with a 20% protocol share. Governance can change the factory default; existing pair-local values change only when explicitly overridden, batch-applied, or reset through farm deactivation.
- Activated Classic farms set protocol fee to 100% and route fee LP to `FeeCenter`.
- `ApexController.collectClassicProtocolFees(pair)` settles pending fee LP to `FeeCenter`, then `FeeCenter.realizeClassicFees(pair)` burns FeeCenter-held LP into raw pair tokens.
- Pair-level fee receiver overrides reject `address(0)`. This is an Apex safety delta; zero receiver would act as fee-off and could erase pending lazy protocol-fee growth.
- `ClassicRouter.addLiquidityAndStake` and `addLiquidityETHAndStake` mint LP to the router and atomically deposit it for the requested beneficiary. The paired Chef surface includes `depositFor`, `withdrawTo`, `withdrawToAndCall`, and an authenticated router callback.

### CL

- CL callbacks keep Pancake names (`pancakeV3MintCallback`, `pancakeV3SwapCallback`, `pancakeV3FlashCallback`) for aggregator, router, and MEV-bot compatibility.
- Apex extends CL protocol-fee range to the full safe `0..10000` scale. Ungauged pools start at 20%; `DEFAULT_ADMIN_ROLE` can change the global ungauged policy and `FEE_OPERATOR` can explicitly apply it to selected inactive pools. Activated farms use 100%.
- Apex enables a wider default CL fee-tier set than Pancake: 0.01%, 0.02%, 0.05%, 0.10%, 0.20%, 0.30%, 1.00%, and 2.00%.
- `CLPoolDeployer.setFactoryAddress` keeps Pancake's one-time binding concept but adds a deployer-only guard to remove the public mempool race.
- `NonfungiblePositionManager.mintAndStake` is an Apex UX extension that mints to the NFP manager, verifies the staking receiver, then transfers the NFT to `CLMasterChef` with the intended beneficiary encoded.
- Liquidity donations into CL positions are blocked in the NFP/Chef paths because they interact badly with MEV-resistant farming timers.
- CL farming includes MEV resistance: recent liquidity changes can forfeit rewards instead of trapping the NFT. Default window is 120 seconds. User withdrawals must remain possible.

### Emissions

- `ApexController.rebalanceEmissions(amount, duration, weights)` is the operator-facing emission primitive.
- Classic and CL farms share one controller-level allocation set.
- Rebalance mass-updates both chefs before changing weights.
- Emissions are rolling funded windows, not governance epochs. Operators can renew windows continuously, but each call has a finite `periodEndTime`.
- If a previous window is still active, only its unelapsed future rewards are rolled into the new stream. Fresh `_amount` is the only value added to `rewardLiability`.
- Calling `rebalanceEmissions(0, duration, weights)` restreams the remaining active-window rewards over the new duration while changing weights. If there is no remaining reward, the global rate is cleared.
- `ClassicChef` uses JoeV2/Sushi-style `lastRewardTime` and `accRewardPerShare` accounting, but caps elapsed reward time at the controller's current `periodEndTime`.
- `CLMasterChef` keeps Pancake `LmPool` accounting; `ApexController.getLatestPeriodInfo` returns the same finite controller `periodEndTime` for CL and Classic.
- `ApexController.payReward` short-pays available rewards when underfunded. Underfunding can reduce rewards, but must not block withdrawals. `rewardLiability()` is the committed emission amount that treasury/operator monitoring should compare against the controller's APEX balance.
- `releaseAndSplitEmissions` releases vested APEX from `EmissionCenter`, transfers 5% (`released / 20`, rounded down) to the current treasury, and leaves the remainder available for funded emissions. `DEFAULT_ADMIN_ROLE` can rotate the treasury through `setTreasury`.
- Farm deactivation keeps the farm registered, sets its alloc point to zero, marks it inactive for future rebalances, and resets protocol-fee routing to default inactive-pool settings. Reactivation reuses the existing Classic pid or CL LmPool; it does not deploy or register duplicates.

### VeApexToken

- `VeApexToken` is a lock NFT for `ApexVault`, not a governance voting NFT.
- There is no `voter`, `voted`, `voting`, `abstain`, or `setVoter` surface.
- There is no `split` surface. Merge remains enabled for lock consolidation.
- Historical supply uses current veAERO timestamp semantics: `totalSupplyAt` takes a timestamp, `clock()` returns `block.timestamp`, and `CLOCK_MODE()` returns `mode=timestamp`.
- Lock/checkpoint memory snapshots intentionally use explicit field copies, matching current veAERO's anti-memory-aliasing pattern.
- Vault accounting uses raw locked amount, not decayed voting power.
- Vault positions require at least `10_000` raw locked APEX units. This is the exact minimum needed for any nonzero 1 bp reward allocation to produce nonzero effective weight.
- The lock token address (`veNFT.token()`, APEX) is treated as the compound token. In Vault accounting the compound bucket key is the `veNFT` contract address.

### ApexVault

- Users stake a veNFT and choose reward-token bps plus optional compound bps.
- `rewardTokenAt` / `rewardTokensLength` expose the all-time reward token set; `isRewardToken(token)` is the current active/selectable status.
- Reward tokens stream over `rewardDuration`; operators can notify repeatedly to roll streams forward.
- Compound rewards are APEX and are relocked into the user's veNFT by controller/operator calls.
- Expired/invalid compound rewards are forfeited to treasury.
- Rewards streamed while `totalWeight == 0` accrue as unallocated and are sweepable to treasury; they do not later stream to the next staker.
- Inactive positions can be flushed permissionlessly when the lock no longer satisfies `minRemainingLock`.
- Final Vault reward output tokens must be exact-transfer, non-rebasing ERC20s with at least 4 decimals. Fee-on-transfer, rebasing, hook-based, lower-decimal, or otherwise non-standard tokens are unsupported.
- Direct veNFT transfers to `ApexVault` are unsupported user error and may be unrecoverable without an upgrade or governance action. Users should enter through `stake`.
- There is no broad admin token sweep from Vault. Treasury recovery for abandoned rewards uses accounting-aware unallocated-reward paths.
- There is intentionally no generic emergency unstake path. The Vault is upgradeable and reward tokens are controlled/whitelisted.

### FeeCenter

- `FeeCenter` is both fee intake and receiver factory/registry.
- `pushAndSplitFees(tokens)` splits current FeeCenter balances equally across active receivers.
- `removeReceiver(outputToken)` removes a receiver from future splits but leaves the receiver known/manageable for leftover cleanup.
- Swaps execute arbitrary calldata only against Safe-approved target contracts. The receiver grants that target an exact temporary input-token allowance, clears it after the call, and verifies actual input spent and output received against a nonzero minimum.
- Receiver output tokens are notified into the Vault as claimable reward streams, or as compound streams when the receiver output token is the underlying APEX lock token.
- `FeeCenter` intentionally also serves as the `IBeacon` for `FeeReceiver` `BeaconProxy` instances to avoid an extra deployment contract. The final `implementation()` view in `FeeCenter` is beacon compatibility surface and must not be removed or repurposed during FeeCenter upgrades. Regression tests verify existing receivers still resolve after a FeeCenter implementation upgrade.

### Launcher creator fees

- `DEFAULT_ADMIN_ROLE` configures and authorizes each launcher address in one call with a fixed recipient, gross creator-fee bps, base veGIGA-fee bps, start-gauged flag, typed `LauncherPermission.NONE`, `CLASSIC`, `CL`, or `BOTH` permission, and active flag. LP fee share is the unconfigured remainder; authorized launchers cannot choose fee terms during creation.
- Launcher entrypoints create only new pools through the controller's configured canonical Classic or CL factory. Existing pools cannot be registered retroactively. CL creation also initializes the starting price in the same transaction.
- Launcher terms are snapshotted per pool across controller and `FeeCenter` storage; later launcher-configuration edits affect future pools only. Different launchers can therefore retain independent recipients, base splits, and initial farm states concurrently. Admin pool updates settle old terms first and may rotate or remove the creator while preserving a separately configured base veGIGA share.
- Creator and veGIGA terms are expressed uniformly in basis points for both pool types. The controller converts the total protocol share to Classic's `1_000_000` scale and CL's `10_000` scale. Creator fees are a percentage of gross swap fees, paid in both pool tokens out of that protocol-fee portion. For example, 500 creator bps plus 1,500 veGIGA bps leaves 8,000 bps for LPs while ungauged.
- A start-gauged launcher configuration atomically registers the Classic Chef pool or deploys/registers the CL LM pool at zero emission weight and applies the fixed gauged split: creator bps to the creator, all remaining gross fees to FeeCenter/veGIGA, and zero LP swap-fee accrual. Only the controller admin can subsequently assign a nonzero emission allocation. Deactivation restores that pool's snapshotted base split rather than the factory-global default.
- Classic protocol fees still crystallize lazily as LP tokens. Permissionless creator-pool collection mints pending fee LP, burns FeeCenter-held fee LP into both underlying tokens, pays the snapshotted creator, and leaves the remainder in FeeCenter. CL collection sends the factory-collected protocol amounts to FeeCenter, pays the creator proportionally, and leaves the remainder in FeeCenter.
- Creator-pool recipients are fixed by stored configuration during collection; permissionless collectors cannot redirect payment, while only `DEFAULT_ADMIN_ROLE` can rotate or remove the stored creator. Classic launcher pools cannot redirect their fee receiver away from FeeCenter.
- Fee/protocol-fee overrides, farm activation/deactivation, and creator-term rotation settle accrued creator fees under the old regime before changing it. Creator configuration survives farm activation and deactivation.
- All configured launchers, active launchers, all launcher pools, active launcher pools, and per-launcher pool membership are enumerable on-chain. Pool metadata exposes its original launcher, current split, typed pool kind, and gauge state; historical changes remain indexed by events.
- Upgrade storage additions are append-only inside the existing `apex.controller.storage.v1` and `apex.fee.center.storage.v1` namespaces. Existing layout field order and types are unchanged; launcher configuration, enumerable sets, and per-pool mappings are appended to the controller layout.

## Finding Disposition

No owner-tracked unresolved remediation item exists as of the reviewed baseline. That statement does not mean the system is finding-free: the entries below document accepted behavior, inherited compatibility constraints, integration risks, and fixed historical findings that auditors should independently retest.

## Historical Finding Log

The status is carried in each `Severity` line. Entries marked `fixed` describe prior behavior and should be verified through the cited regression behavior; other entries remain accepted or intentional caveats. Finding IDs are kept stable for reviewer correspondence. `F-41` is retired because it duplicated `F-27`.

### F-01: CL emergency mode can skip LM cleanup

Severity: Informational / inherited Pancake behavior.

Finding: `CLMasterChef` follows Pancake `MasterChefV3`: when `emergency` is enabled, withdrawal prioritizes returning the NFT and can skip LM cleanup.

Dev response: Accepted for Pancake parity. If emergency mode is used, emissions should be set to zero and the same LM state should not resume normal rewards without migration/review.

### F-02: Pancake-style CL sweep footgun is retained

Severity: Low / advanced integration risk.

Finding: Raw Pancake-style CL collect/sweep flows can be misused by custom callers. Pancake `MasterChefV3.collect` rewrites `recipient == address(0)` to the Chef and warns callers to pair it with `unwrapWETH9` / `sweepToken`. Pancake `collectTo` also sweeps full Chef-held balances for the pool tokens rather than measuring only the current collect delta; Apex keeps this behavior for parity.

Dev response: Accepted for Pancake compatibility. Official SDK/frontend paths use Chef `collectTo` helpers inside multicall and do not expose raw collect/sweep flows as default UX. Raw ABI callers must not leave token balances in the Chef or NFP manager.

### F-03: Raw NFP mint can bypass active farm staking UX

Severity: Low / user integration risk.

Finding: Raw `NonfungiblePositionManager.mint(...)` remains available. If a user raw-mints into an active CL farm with 100% protocol-fee routing and does not stake, they may miss intended farm rewards.

Dev response: Accepted for Pancake compatibility. Frontends should use `mintAndStake` for active farm deposits.

### F-04: SmartRouter direct swaps do not enforce per-function deadlines

Severity: Low / inherited Pancake pattern.

Finding: SmartRouter direct swap functions follow Pancake's pattern without per-function deadlines.

Dev response: Accepted for Pancake parity. Official SDK/frontend paths should wrap swaps in `SmartRouter.multicall(...)` with deadline or previous-blockhash validation.

### F-05: Classic TWAP helpers can revert without enough history

Severity: Informational / inherited Solidly-style behavior.

Finding: Classic TWAP helper views can revert for new or undersampled pools.

Dev response: Accepted. Frontends/indexers should check `observationLength()` and fall back to spot quote or insufficient-history UI.

### F-06: Classic lazy protocol fees use current config at mint time

Severity: Informational / inherited Solidly-style behavior.

Finding: Classic protocol fees are minted lazily, so the active `feeReceiver` and protocol-fee config at settlement time determines where pending protocol LP is minted.

Dev response: Accepted. If an exact fee-regime boundary matters, settle Classic protocol fees before changing that pair's fee receiver or protocol fee.

### F-07: Full emission rebalance updates the whole farm book

Severity: Informational / operational constraint.

Finding: `rebalanceEmissions` mass-updates all Classic and CL farms before changing allocation weights.

Dev response: Accepted. Production assumption is at most 200 total MasterChef farms. On the reviewed baseline with Foundry v1.7.1, gas tests measured approximately 3.33M for 100 Classic, 3.55M for 100 CL, and 6.88M for 100 Classic + 100 CL in the actual `rebalanceEmissions` call. Re-measure if farm logic or compiler settings change.

### F-08: Deployment validation is not cross-transaction atomic

Severity: Informational / deployment-process risk.

Finding: Foundry broadcasts deployment as a sequence of transactions, so script validations cannot make the whole deployment atomically revert after earlier transactions are mined.

Dev response: Accepted. Run the script without `--broadcast` first. If any post-broadcast validation fails, treat the deployment as invalid and do not launch from those addresses.

### F-09: VeApexToken keeps veAERO non-strict ERC721 view semantics

Severity: Informational / inherited veAERO compatibility.

Finding: `VeApexToken` keeps veAERO-style non-strict ERC721 view semantics for nonexistent-token queries such as `ownerOf`, `getApproved`, and `balanceOf(address(0))`.

Dev response: Accepted for veAERO parity. Transfers and state-changing paths are guarded; this is an integration caveat, not a custody issue.

### F-10: CL pending reward view is checkpoint-state based

Severity: Low / inherited Pancake behavior.

Finding: `CLMasterChef.pendingReward` mirrors Pancake `pendingCake`: it reads the last `LmPool` reward-growth state and does not project an uncheckpointed `accumulateReward(block.timestamp)` in view mode. Actual harvest paths checkpoint `LmPool` before payout.

Dev response: Accepted for Pancake parity. Frontends/indexers should treat this as checkpoint-state pending reward, not fully projected live pending reward. Actual harvest payout remains correct.

### F-11: Vault reward notifications require existing bucket weight

Severity: Low / intentional operator constraint.

Finding: `ApexVault.notifyRewardAmount` and `ApexVault.notifyCompoundAmount` revert when the target reward bucket has zero total weight. The Vault only accrues unallocated rewards for streams that started while weight existed and later became empty.

Dev response: Intentional. Operators should not notify empty buckets. FeeReceiver/output leftovers can remain parked until users create demand for that reward token, or be handled through explicit operator cleanup paths.

### F-12: Removed FeeCenter receivers remain known for cleanup

Severity: Low / intentional operator cleanup behavior.

Finding: `FeeCenter.removeReceiver(outputToken)` removes the receiver from future `pushAndSplitFees` distributions, but leaves `receiverOutput[receiver]` set. This means the receiver remains known to FeeCenter and can still be operated by `ApexController`.

Dev response: Intentional. Removed receivers should stop receiving new split fees, but may still hold old raw fees, partially swapped leftovers, output-token balances, or dust. Keeping them known lets the controller swap, notify, compound-notify, or rescue leftovers. Random users cannot operate removed receivers: FeeReceiver calls are `onlyFeeCenter`, and FeeCenter management calls are `onlyApexController`.

### F-13: CL liquidity changes used to make mature rewards slashable

Severity: Medium / fixed.

Finding: `CLMasterChef.increaseLiquidity` and `CLMasterChef.decreaseLiquidity` previously settled rewards into `positionInfo.reward` before resetting `lastLiquidityChange`. Mature pending rewards could then be slashed if the user harvested or withdrew inside the new MEV-resistance window.

Dev response: Fixed. The Chef now pays settled rewards to the position owner before updating LM liquidity accounting and resetting the MEV timer. If the position is already inside its current MEV window, rewards still slash as intended. After a mature liquidity change, only newly accrued rewards are exposed to the new timer.

Implementation note: `increaseLiquidity` keeps Pancake's deposit-token pull before reward settlement, so pending APEX rewards cannot implicitly fund the liquidity payment when APEX is also one side of the CL pool. Reward settlement happens after the NFP liquidity call but before LM liquidity accounting and `lastLiquidityChange` reset.

### F-14: Vault inactivity is enforced lazily through flushInactive

Severity: Low / intentional keeper-liveness behavior.

Finding: `ApexVault` positions keep their reward weight after crossing `minRemainingLock` until someone calls `flushInactive(tokenIds)`. Rewards accrued before that flush remain claimable.

Dev response: Accepted. This is intentional lazy-flush behavior to keep Vault accounting simple and avoid per-position expiry scheduling. While a veNFT is staked, the user cannot transfer or sell it elsewhere. Keepers/operators are expected to call `flushInactive` regularly to remove expired or below-threshold positions from future reward streams.

### F-15: FEE_OPERATOR can change per-pool fee economics

Severity: Medium / accepted role authority.

Finding: `FEE_OPERATOR` can call per-pool Classic fee overrides, Classic protocol-fee overrides, and CL protocol-fee overrides. A compromised or misused `FEE_OPERATOR` can change pool economics within protocol caps.

Dev response: Accepted. This is intentional operational authority, not a random-user exploit. LPs are not locked by these settings and can withdraw if they dislike a pool's fee configuration. Farm activation already intentionally moves selected pools to 100% protocol-fee routing. Deployers should treat `FEE_OPERATOR` as a trusted operations role and secure it accordingly.

### F-16: Vault per-user reward settlement can leave bounded raw-unit dust

Severity: Low / accepted rounding behavior.

Finding: `ApexVault` tracks stream-level carry, but per-position settlement floors fractional raw token units. Repeated settlement can leave bounded dust in the Vault, especially for low-decimal reward tokens.

Dev response: Accepted. This is not a DoS vector: one participant repeatedly settling cannot advance another participant's paid index or make them stop earning. Fuzz tests cover repeated forced settlement, BTC-style 8-decimal rewards, and attacker-frequent-claim scenarios. Production reward output tokens must have at least 4 decimals, be exact-transfer, and be non-rebasing; lower-decimal reward tokens are out of scope.

### F-17: VeApexToken global checkpoint loop is bounded to 255 weeks

Severity: Informational / accepted inherited behavior.

Finding: `VeApexToken` inherits the ve-style bounded weekly checkpoint loop. If no one checkpoints for more than 255 weeks, global `totalSupply` history can lag until later checkpoint calls catch up.

Dev response: Accepted. 255 weeks is roughly five years, `MAXTIME` is only 26 weeks, and Apex does not use ve global supply for voting or Vault reward accounting. `ApexVault` uses each veNFT's raw locked amount from `locked(tokenId)`, so this is an analytics/indexing edge case rather than a user-funds risk.

### F-18: VeApexToken direct storage under transparent proxy

Severity: Informational / fixed.

Finding: `VeApexToken` was transparent-upgradeable while keeping Apex-owned mutable state as direct contract variables, unlike the other Apex upgradeable contracts that use namespaced storage libraries.

Dev response: Fixed. `VeApexToken` now stores Apex-owned mutable state in `VeApexTokenStorage` under `src/core/storage`, while preserving the prior public getter ABI through explicit getter functions. `testVeApexTokenStorageSurvivesImplementationUpgrade` verifies lock ownership, lock data, checkpoints, token/team config, metadata, and supply survive a transparent-proxy implementation upgrade.

### F-19: ClassicPool direct quote edge cases match Solidly-style Pair behavior

Severity: Low / accepted inherited behavior.

Finding: `ClassicPool.getAmountOut` can revert for zero or dust inputs because it returns `_getAmountOut(...) - 1`; if the raw quote is zero, Solidity 0.8 checked arithmetic reverts. Direct callers that pass an invalid `tokenIn` are also treated as the non-`token0` side.

Dev response: Accepted. This is inherited from the Solidly-style `Pair.getAmountOut` pattern and is not an Apex-introduced deviation. Normal Apex router/quoter paths derive the pair from canonical route tokens before calling the pool. Treat this as a direct-pool integration quirk, not a protocol accounting or custody issue.

### F-20: Classic pair fee event used to emit the zero sentinel instead of the applied fee

Severity: Informational / fixed.

Finding: `ClassicFactory.setPairFee(pair, 0)` resolves the applied pair fee to the current global fee, but used to emit `SetPairFee(pair, 0)`. Event-only indexers could display a zero fee even though pool state was correctly updated to the global fee.

Dev response: Fixed. `SetPairFee` now emits the resolved/applied fee. A regression test covers `overrideClassicFee(pair, 0)` after changing the global fee.

### F-21: External APEX_TOKEN validation used to happen after deployment started

Severity: Low / fixed.

Finding: When `APEX_TOKEN` was supplied, the deploy script used to check only that the address had code during preflight, then verified fixed supply and treasury ownership after deployment work had already started.

Dev response: Fixed. `_preflight` now verifies any supplied `APEX_TOKEN` has the expected 1B supply and that the full supply is held by `APEX_TREASURY` before broadcast deployment begins. Post-deployment validation keeps the same checks as defense in depth.

### F-22: ClassicChef emergencyWithdraw skips reward checkpointing

Severity: Low / accepted inherited MasterChef behavior.

Finding: `ClassicChef.emergencyWithdraw` does not checkpoint pool rewards before returning LP and zeroing the user's stake. If time elapsed since the last checkpoint, the emergency-withdrawing user forfeits rewards and remaining stakers may receive the next checkpoint's rewards over the reduced LP supply.

Dev response: Accepted for MasterChef parity. Pancake's ERC20 `MasterChef.emergencyWithdraw` follows the same emergency-only pattern: return LP without caring about rewards and zero user accounting without `updatePool`. Apex keeps this behavior so emergency withdrawal is minimal and reward-forfeiting by design.

### F-23: Direct veNFT safe transfers to ApexVault are unsupported

Severity: Low / accepted user-error behavior.

Finding: `ApexVault.onERC721Received` accepts veNFT safe transfers from the configured `VeApexToken` contract. A user who sends a veNFT directly to the Vault instead of calling `stake(...)` can strand it because no Vault position is recorded.

Dev response: Accepted. Direct veNFT transfers to the Vault are unsupported user error, like sending tokens or NFTs to the wrong address. Official frontend/SDK flows must use `stake(...)`, which records the position before transferring the veNFT. The Vault is upgradeable if governance ever chooses to add a rescue path.

### F-24: Public periphery cleanup inherits the upstream token-trust model

Severity: Low / inherited Pancake/Uniswap periphery behavior.

Finding: `SwapRouter` and `SmartRouter` expose payable swap functions plus public `refundETH`, `unwrapWETH9`, and `sweepToken` helpers. A raw caller that sends unnecessary ETH, or constructs a multihop WETH path badly, can leave ETH/WETH in the router for public cleanup. A deliberately malicious output-token contract can also call `refundETH` while the CL pool transfers output before its payment callback; for a native-WETH input, that can consume the in-flight ETH and make `pay` fall back to the caller's existing WETH allowance.

Dev response: Accepted as inherited behavior under the normal-token assumption. The pinned Pancake V3 and Uniswap V3 implementations use the same output-before-callback sequence and the same full-balance `refundETH` / native-WETH `pay` logic. Apex does not claim safe routing through adversarial token contracts; official token lists and frontend/SDK routes must exclude malicious or otherwise unsupported tokens. For normal assets, official paths use `ApexSmartRouter.*CallParameters(...)` or `ApexSmartRouter.swapCallParameters(...)`, which wrap swaps in a deadline/previous-blockhash `multicall` and append `REFUND_ETH`, `UNWRAP_WETH9`, or `SWEEP_TOKEN` cleanup when leftovers are possible.

### F-25: mintAndStake recipient can strand staked CL NFTs

Severity: Low / fixed.

Finding: `mintAndStake` credits the encoded beneficiary as the staked NFT owner in `CLMasterChef`. If that beneficiary is the Chef or NFP manager itself, the position can be stranded because only the credited owner can operate it.

Dev response: Fixed for Apex's native path. `NonfungiblePositionManager.mintAndStake` rejects the Chef and NFP manager as beneficiaries, and `ApexCLFarm.mintAndStakeCallParameters(...)` takes `account`, `stakingReceiver`, and `nonfungiblePositionManager` separately so the SDK cannot accidentally encode a protocol contract as the staked owner.

### F-26: FeeCenter receiver loop is governance-bounded

Severity: Low / accepted operational constraint.

Finding: `FeeCenter.pushAndSplitFees` splits each pushed token across every active receiver in one transaction. If governance added an unbounded number of receivers, the split loop could become too expensive.

Dev response: Accepted. Production design expects a small governance-managed receiver set, normally the configured reward output buckets. This is not a random-user DoS path because only Apex governance can add receivers. If the receiver set ever grows materially, governance should either cap it before launch config or upgrade to a cursor/range splitter before adding many receivers.

### F-27: Active farms may have zero emission allocation

Severity: Low / intentional operator semantics.

Finding: A farm can be active for fee routing while its allocation is zero, so `activeFarm` does not always mean the pool currently receives APEX emissions.

Dev response: Intentional. Apex separates "farm/fee-routing active" from "currently emission-bearing." Operators may pre-activate, pause, or keep a pool fee-routed with zero emissions. Frontends and indexers should use allocation/latest reward-rate views to display emission status rather than treating `activeFarm` as a nonzero APR flag.

### F-28: Classic pairs require standard ERC20 metadata

Severity: Low / accepted compatibility constraint.

Finding: Classic pair creation calls ERC20 metadata (`symbol()` and `decimals()`) and assumes sane decimals, so tokens with missing, malformed, or extreme metadata are unsupported.

Dev response: Accepted. Classic pools are intended for normal ERC20s with standard metadata and sane decimals. Weird-token support is out of scope for Classic pool creation; deployment/frontend allowlists should avoid unsupported tokens.

### F-29: Bytecode size headroom is tight

Severity: Informational / accepted release engineering risk.

Finding: Some deployment-critical contracts are close to the EIP-170 runtime size limit, so late code additions can break deployment.

Dev response: Accepted and tracked through build-size checks. This is not a runtime protocol vulnerability. Before freezing any launch or upgrade commit, run `forge build --sizes` and avoid adding nonessential code to size-sensitive contracts.

### F-30: FeeReceiver balance notify helpers revert when empty

Severity: Low / accepted operator behavior.

Finding: `FeeReceiver.notifyVaultBalance()` and `notifyVaultCompoundBalance()` revert when the receiver has zero output-token balance because the explicit notify functions reject zero amounts.

Dev response: Accepted. Operators should not include empty receivers in balance-notify batches. Reverting on zero is preferred because it catches keeper mistakes instead of silently doing nothing.

### F-31: Direct VeApexToken depositFor can stale Vault weight

Severity: Low / accepted integration constraint.

Finding: `VeApexToken.depositFor(tokenId, amount)` is permissionless and can add APEX to an existing lock even while the veNFT is staked in `ApexVault`. Because the Vault owns the NFT and stores its own reward weights, a direct `depositFor` increases the underlying lock but does not refresh Vault weight until a later Vault interaction.

Dev response: Accepted as unsupported integration behavior. Users and frontends should route amount increases for Vault-staked veNFTs through `ApexVault.increaseAmount(...)` or another Vault-aware flow. Direct `VeApexToken.depositFor` is a donation-style veNFT function and does not steal funds; at worst, the added amount under-earns until the Vault position is refreshed.

### F-32: Nonzero emission amount can round to zero rate

Severity: Low / fixed.

Finding: `rebalanceEmissions(amount, duration, weights)` could accept a nonzero amount with a duration large enough that `(amount * REWARD_PRECISION) / duration == 0`, increasing reward liability without producing emissions.

Dev response: Fixed. Emission windows now require `block.timestamp + duration <= type(uint32).max`, matching CL `LmPool`'s uint32 time domain, and any nonzero streamed reward amount must compute a nonzero reward rate before state is updated.

### F-33: Deployment wiring checks rely on canonical script

Severity: Informational / accepted deployment constraint.

Finding: Some deploy-critical wiring checks are enforced by `scripts/DeployApex.s.sol` rather than every constructor or initializer duplicating all semantic validations.

Dev response: Accepted. Apex launch deployments must use the canonical deploy script and its preflight/post-deploy validation. Noncanonical manual deployments are out of scope.

### F-34: Eternal emission end time can over-accrue finite funding

Severity: Medium / fixed.

Finding: Treating `rebalanceEmissions(amount, duration, weights)` as finite funded liability while returning an eternal end time let Classic/CL accounting accrue past the funded window if the operator did not renew.

Dev response: Fixed. `ApexController` now stores a finite `latestPeriodEndTime`, rolls only unelapsed rewards into the next window, and returns that end time to both chefs. `ClassicChef` now caps accrual at the returned end time, matching `LmPool` behavior. Regression tests cover Classic expiry, mid-window rollover, expired-window renewal, zero-amount rebalances, CL finite windows near the uint32 limit, and Classic fuzz cases proving pending rewards do not exceed the funded window.

### F-35: Farm deactivation wipes per-pool active-farm routing overrides

Severity: Low / intentional operator semantics.

Finding: Deactivating a Classic or CL farm restores inactive-pool fee settings. Classic resets the pair protocol fee to the default inactive protocol fee and the fee receiver to the factory's default receiver. CL resets both token protocol fees to the default inactive CL protocol fee. Any prior creator/custom per-pool fee-routing override must be re-applied if governance wants it after deactivation.

Dev response: Intentional. "Deactivate farm" means stop active farm routing and return the pool to default inactive economics. Reactivation is safe: it reuses existing registration state, Classic pid, and CL LmPool without duplicates. Regression tests cover deactivate/reactivate for Classic and CL, fee-routing reset behavior, inactive rebalance rejection, cross-chef redistribution after deactivation, and earning again after reactivation.

### F-36: Classic global setters are future-pair defaults, not live-pair propagation

Severity: Low / accepted inherited behavior.

Finding: `setClassicGlobalFee`, `setClassicGlobalProtocolFee`, and `setClassicGlobalFeeReceiver` update ClassicFactory-level defaults. Existing Classic pairs keep pair-local fee, protocol-fee, and fee-receiver values until explicitly changed through pair override functions.

Dev response: Accepted. This follows the Solidly-style pair-local configuration model: factory/global values are defaults for newly created pairs, and live pairs are changed with explicit per-pair overrides. A live-global fallback model was considered but rejected for now because it adds new behavior and audit surface.

### F-37: Some underlying owner/team admin surfaces are intentionally upgrade-only

Severity: Low / accepted bytecode-size tradeoff.

Finding: Canonical deployment makes `ApexController` the owner/team authority for several contracts. Some low-frequency underlying admin functions, such as extra CL fee-tier controls, CL whitelist controls, CLFactory owner transfer, Classic skim toggles, or VeApexToken team transfer, are not exposed as direct controller wrappers.

Dev response: Accepted. `ApexController` is close to the EIP-170 bytecode limit, so Apex intentionally avoids adding broad low-frequency wrappers that bloat the runtime. These operations are treated as upgrade-only governance actions unless a concrete launch need appears. This is an operational tradeoff, not a random-user exploit.

### F-38: `createLockFor` raw-mints veNFTs to the requested recipient

Severity: Informational / accepted veAERO parity.

Finding: `VeApexToken.createLockFor(value, duration, to)` can mint a veNFT to a contract recipient without calling `onERC721Received`. If the caller chooses a contract that cannot operate ERC721s, that caller-funded lock can be operationally stranded.

Dev response: Accepted. This matches current veAERO `VotingEscrow.createLockFor`, which routes through `_createLock` and raw `_mint`. Apex frontends and integrations should pass an EOA or a known veNFT-capable contract recipient. This is a caller/integration footgun, not an existing-user fund loss path.

### F-39: Classic stable `sync()` can commit reserves outside `_k()` arithmetic domain

Severity: Informational / accepted Solidly-style AMM parity.

Finding: For Classic stable pairs, a sufficiently large direct token donation followed by permissionless `sync()` can write balances into reserves that still fit `uint112` but later overflow the stable invariant `_k()` arithmetic. This can make quotes, swaps, and LP burns revert until reserves are corrected by an upgrade or migration.

Dev response: Accepted as inherited Classic AMM behavior. This follows the Solidly-style pair model: permissionless `sync()`, `uint112` reserve caps, stable quartic `_k()` math, and disabled-by-default `skim()`. The edge is economically unrealistic for normal canonical stable assets: a balanced 18-decimal or 6-decimal stable/stable pool needs roughly `15.5B` whole tokens per side after decimal normalization before `_k()` overflow is reachable. Apex will not add custom stable-pair arithmetic or reserve-domain checks before launch unless a concrete in-scope high-supply or malicious-token listing policy requires it.

### F-40: Controller emission liability can retain bounded raw-unit dust

Severity: Informational / accepted rounding behavior.

Finding: `ApexController.rewardLiability` is tracked in whole APEX units while controller emission rates and downstream Chef accounting floor intermediate divisions. After a fully elapsed emission window, a few raw APEX units can remain reserved as liability even when no meaningful reward remains claimable.

Dev response: Accepted. Rounding moves in the conservative direction: rewards never exceed funded emissions, and any residual stays backed in the controller rather than overpaying users. Fuzz tests cover full-window Classic and CL emissions across arbitrary amount/duration inputs and bound residual liability to at most 2 raw APEX units in those single-pool cases. Apex intentionally avoids a broad dust sweep because proving no user-attributable rewards remain across all farms is more dangerous than leaving tiny backed dust.

### F-41: Aggregator target must also be the documented allowance spender

Severity: Medium / operational invariant.

Finding: `FeeReceiver.executeSwap` grants an exact temporary allowance to the approved call target. Aggregator integrations are therefore valid only when the aggregator documents the same contract as both the ERC20 allowance spender and calldata entry point. In particular, 0x warns that approving its Settler can expose tokens to loss; only the AllowanceHolder endpoint may be used, and a quote must return the pinned AllowanceHolder as both the allowance spender and `transaction.to`. Kyber routes must likewise return the pinned MetaAggregationRouter as their router and allowance target.

Dev response: Enforced in production tooling. Swap plans pin the router address and code hash, use the fee receiver as both sender and recipient, grant only the exact input amount inside the atomic call, and assert that allowance returns to zero. Tooling must reject any API response whose allowance spender and call target differ; it must never substitute a Settler or arbitrary calldata target.

### F-42: Approved reward-token failure can delay unstaking

Severity: Low / governed integration liveness assumption.

Finding: `ApexVault.unstake` settles every configured reward before returning the veNFT. If an approved reward token later reverts on transfer because it is paused, blacklists the recipient, or otherwise stops behaving as an exact-transfer ERC20, the affected position cannot complete `unstake` through the current implementation.

Dev response: Accepted under the governed reward-token trust model. Governance must approve only exact-transfer, non-rebasing tokens whose transfer policy cannot unexpectedly block recipients, as already required by the reward-token assumptions above. If an approved token nevertheless fails permanently, the transparent proxy provides the recovery path through a reviewed Vault upgrade; the protocol will not add a fail-open reward skip that could silently discard user value before launch.

## Audit Scope And Release Context

The public auditor mirror is a source-review package, not the deployment authority. It intentionally excludes deployment configuration, broadcasts, live-chain manifests, signing inputs, and private release automation. If deployment/release integrity is in scope, request those artifacts separately; the canonical private flow validates chain configuration, proxy/admin wiring, factory and Chef relationships, initialization-code hashes, role handoff, and periphery immutables.

Private release promotion follows: complete deployment draft, canonical SHA-256 payload digest, external EIP-191 signature, and downstream signer-allowlist enforcement. Broadcast receipt-range checking is an additional consistency check, not proof by itself that every manifest address or bytecode value came from that broadcast. ABI bundles record digests and source provenance; consumers should independently bind the bundle to the reviewed source revision.

## Integration Assumptions

- Use SDK call-parameter helpers for normal user actions rather than hand-encoding raw ABI calls.
- Use `ClassicRouter` for Classic add/remove liquidity UX; frontends must not raw-transfer tokens or ETH to Classic pairs.
- Use the atomic Classic add-and-stake helpers when a newly minted LP position should enter `ClassicChef`; the beneficiary must be the intended user.
- For SmartRouter swaps, use deadline/previous-blockhash wrapped calldata from `ApexSmartRouter`.
- For active CL farm deposits, use `ApexCLFarm.mintAndStakeCallParameters(...)`; pass the user as `account`, not as a raw NFP `recipient`.
- For staked CL fee collection, use Chef `collectTo` helpers and do not expose raw collect/sweep flows as default UX.
- The SDK compound bucket helper must use the veNFT address, not zero address.
