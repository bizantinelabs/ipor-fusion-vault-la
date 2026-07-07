# VERIFY — Bizantine cbBase USDC CORE (run before seeding TVL / opening)

## Identity (immutable — must be exact)
- [ ] `plasmaVault.name()` == "Bizantine cbBase USDC CORE"
- [ ] `plasmaVault.symbol()` == "bizcbBaseUSDC"
- [ ] `plasmaVault.asset()` == 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 (USDC)
- [ ] redemption delay > 0

## Substrates & fuses
- [ ] 8 supply fuses + 8 balance fuses registered (ids 1–6,10,11) — Option A; or aggregate set — Option B
- [ ] Each marketId's substrate == expected (Morpho market id bytes32; venue = USDC address as bytes32)
- [ ] No extra/unexpected fuses registered

## Caps (1e18 = 100%)
- [ ] cbBTC 0.50 · cbETH 0.25 · cbXRP 0.22 · cbDOGE 0.08 · cbADA 0.06 · cbLTC 0.05 · Compound 0.20 · Aave 0.25
- [ ] (Confirm market-limit protection is active if a separate activation call exists)

## Roles (grantRole roleId/account/delay)
- [ ] OWNER(1)=Governance Safe · ATOMIST(100)=Atomist, delay 86400/172800 · ALPHA(200)=IPOR · GUARDIAN(2)=Hypernative
- [ ] CLAIM_REWARDS(600)+TRANSFER_REWARDS(700)=IPOR Alpha · CONFIG_INSTANT_WITHDRAWAL(900)=Atomist (not Alpha)
- [ ] NEGATIVE: Alpha CANNOT addFuses/grantMarketSubstrates/setupMarketsLimits/updateFee/grantRole (expect revert)
- [ ] NEGATIVE: Alpha CANNOT move assets to an external address (expect revert)

## Oracle / fees / withdrawals
- [ ] priceOracleMiddleware set; priceOf(USDC) ~ 1:1
- [ ] perf fee 10% + mgmt fee (0.5%/0) to Bizantine recipient; IPOR DAO package applied
- [ ] instant-withdraw order = idle→Aave→Compound→cbBTC→cbETH; Tier2/3 (3–6) excluded
- [ ] scheduled withdrawal window > 0 set on WithdrawManager

## Live ops
- [ ] Guardian dry-run: pause → deposits/withdraws blocked → force-exit to buffer → unpause restores (independent of Alpha key)
- [ ] Hypernative monitoring live; test alert reaches Bizantine ops channel
- [ ] Seed anchor TVL → NAV computes; shares mint at expected rate
- [ ] Small test rebalance across legs incl. Tier2/3 → gate PASS/FAIL correct vs live liquidity
