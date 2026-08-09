# VERIFY — Bizantine cbBase USDC CORE (run before seeding TVL / opening)

## Identity (immutable — must be exact)
- [ ] `plasmaVault.name()` == "Bizantine cbBase USDC CORE"
- [ ] `plasmaVault.symbol()` == "bizcbBaseUSDC"
- [ ] `plasmaVault.asset()` == 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 (USDC)
- [ ] redemption delay > 0

## Substrates & fuses (launch config: Morpho=14, Aave=1)
- [ ] 2 supply fuses (Morpho 0xae93…410F, Aave 0x26fD…1625) + 2 balance fuses (Morpho 0x7916…73d5, Aave 0xf53f…0BA9) registered
- [ ] Morpho(14) substrates == the 6 cb market ids; Aave(1) substrate == USDC-as-bytes32
- [ ] Dependency graph: NONE registered (correct for plain supply; no market-7)
- [ ] No extra/unexpected fuses registered

## Caps (1e18 = 100%) — AGGREGATE only on-chain
- [ ] Morpho(14) 0.80 · Aave(1) 0.25
- [ ] Per-cb caps (50/25/22/8/6/5) confirmed loaded into IPOR Alpha policy + Hypernative (NOT on-chain)
- [ ] (Confirm market-limit protection is active if a separate activation call exists)

## Roles (grantRole roleId/account/delay)
- [ ] OWNER(1)=Governance Safe · ATOMIST(100)=Atomist, delay 86400/172800 · ALPHA(200)=IPOR · GUARDIAN(2)=Hypernative
- [ ] CLAIM_REWARDS(600)+TRANSFER_REWARDS(700)=IPOR Alpha · CONFIG_INSTANT_WITHDRAWAL(900)=Atomist (not Alpha)
- [ ] NEGATIVE: Alpha CANNOT addFuses/grantMarketSubstrates/setupMarketsLimits/updateFee/grantRole (expect revert)
- [ ] NEGATIVE: Alpha CANNOT move assets to an external address (expect revert)

## Oracle / fees / withdrawals
- [ ] priceOracleMiddleware set; priceOf(USDC) ~ 1:1
- [ ] perf fee 10% + mgmt fee (0.5%/0) to Bizantine recipient; IPOR DAO package applied
- [ ] instant-withdraw order = idle(auto)→Aave→Morpho:cbBTC→Morpho:cbETH; Tier2/3 morpho markets excluded
- [ ] scheduled withdrawal window == 172800 (48h) via WithdrawManager.updateWithdrawWindow

## Live ops
- [ ] Guardian dry-run: pause → deposits/withdraws blocked → force-exit to buffer → unpause restores (independent of Alpha key)
- [ ] Hypernative monitoring live; test alert reaches Bizantine ops channel
- [ ] Seed anchor TVL → NAV computes; shares mint at expected rate
- [ ] Small test rebalance across legs incl. Tier2/3 → gate PASS/FAIL correct vs live liquidity
