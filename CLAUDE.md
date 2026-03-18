# Mondeto

A 300x200 pixel world map on Celo where every land pixel is ownable on-chain. Pixels are colored by owner, creating a territorial mosaic. Uses USDT as currency, targets MiniPay.

## Build & Test

```sh
forge build
forge test
forge test --gas-report   # check buyPixels gas scaling
```

Generate land mask from the world map image (requires Pillow):
```sh
uv run --with Pillow python3 map/generate_land_mask.py
```

Regenerate `world_map_bw.png` from the source SVG (requires cairosvg + Pillow):
```sh
cd map && uv run convert_map.py
```

## Architecture

**Proxy pattern**: UUPS (OpenZeppelin). The proxy address is the one users interact with. The implementation contract has `_disableInitializers()` in its constructor — never call `initialize()` on the implementation directly.

**State lives in the proxy**, not the implementation. When upgrading:
- Deploy new implementation
- Call `upgradeToAndCall(newImpl, "")` from the owner account
- New implementation must inherit from `Mondeto` and not change existing storage layout (only append new state variables)

## Price Formula — The Most Subtle Part

```
price = initialPrice << (saleCount - epoch)    when saleCount >= epoch
price = initialPrice >> (epoch - saleCount)    when saleCount < epoch, floored at minPrice
```

**Why relative epoch matters**: `epoch = (block.timestamp - deployTimestamp) / HALF_YEAR`. If you used absolute `block.timestamp / HALF_YEAR`, epoch would be ~108+ at deploy time, making all pixels nearly free immediately. The relative epoch starts at 0 and increments every 182 days after deploy.

**What this means economically**: Each sale doubles the price. Every 182 days without a sale, the price halves. A pixel bought once (saleCount=1) returns to `initialPrice` after one epoch, then keeps halving. This creates a natural "use it or lose it" pressure — land you buy will decay in value toward `minPrice` if nobody re-buys it.

**`setInitialPrice` is retroactive**: Changing `initialPrice` changes the price of ALL pixels instantly, since it's the base of every price calculation. This is intentional but dangerous — use with care.

**saleCount is uint8**: Saturates at 255. This is fine economically — at saleCount 128 with epoch 0, the price would be `initialPrice * 2^128`, an astronomically large number that nobody would pay.

## Payment Flow

- Buying an **unowned** pixel: USDT goes to the **contract itself** (treasury). Owner withdraws via `withdraw()`.
- Buying an **owned** pixel: USDT goes to the **previous owner**. There is no royalty/fee — 100% goes to the seller.
- **Self-buy** is allowed (saleCount increments, net zero transfer).
- **Bulk buys** aggregate payments per unique recipient before executing transfers. This means buying 50 pixels from the same owner does 1 transfer, not 50. The aggregation uses O(n²) linear scan — fine for expected batch sizes (<100), would be expensive for thousands.

## Land Mask

Not all pixels are buyable. Water pixels (oceans) are excluded.

- `map/Blank_world_map_Equal_Earth_projection.svg` is the upstream source (Wikipedia Equal Earth projection).
- `map/convert_map.py` renders the SVG to `map/world_map_bw.png` (grayscale threshold, crop empty columns). Countries are gray #c0c0c0 in the SVG; the script thresholds at brightness > 240 to separate land from ocean.
- `map/world_map_bw.png` is the working source of truth. Black = land, white = water.
- `map/generate_land_mask.py` converts the PNG to 235 `uint256` words (60,000 bits packed). Threshold: brightness < 128.
- Bit packing: pixel ID `n` is bit `n % 256` of word `n / 256`.
- `setLandMask()` costs ~4.7M gas — call once after deploy.
- The mask is **mutable** by the owner. If you update `world_map_bw.png`, regenerate and re-set.
- Currently 19,818 land pixels out of 60,000.

## Profile System

Each address has one profile (color, label, url). There are two ways it gets set:

1. `updateProfile()` — direct call, always overwrites.
2. `buyPixels()` — **only** updates profile if at least one of `color`, `label`, or `url` is non-zero/non-empty. If all three are zero/empty, the existing profile is preserved. This lets users buy pixels without accidentally blanking their profile.

Label and URL are capped at 64 bytes each (not characters — matters for multibyte UTF-8).

## Deployment

```sh
# .env
USDT_ADDRESS=0x...     # Celo USDT contract
INITIAL_PRICE=100000   # 0.10 USDT (6 decimals)
MIN_PRICE=1            # 0.000001 USDT

forge script script/Deploy.s.sol --rpc-url celo --broadcast
```

After deploy, call `setLandMask()` with the data from `map/land_mask.json`. The deploy script has a placeholder for this — you need to wire it up or call it separately via cast.

## Upgrade Checklist

1. New contract must inherit from `Mondeto` (or replicate its storage layout exactly)
2. **Never reorder or remove existing state variables** — only append new ones after `landMask`
3. Constants (`WIDTH`, `HEIGHT`, etc.) are fine — they compile into bytecode, not storage
4. `usdt` and `deployTimestamp` are regular storage (not `immutable`) because of the proxy pattern
5. Test the upgrade in a fork before mainnet: deploy V2, call `upgradeToAndCall`, verify old state survives

## OpenZeppelin v5 Compatibility Note

OZ v5 removed dedicated "Upgradeable" versions of stateless contracts. `ReentrancyGuard` and `UUPSUpgradeable` use namespaced storage (`@custom:stateless`), making them proxy-safe without separate upgradeable variants. Only `OwnableUpgradeable` (which has actual storage) comes from the upgradeable package. If you see imports from `@openzeppelin/contracts/` (not `contracts-upgradeable/`) for these, that's intentional.

## Target Chain

Celo mainnet. USDT on Celo is a standard ERC-20 with 6 decimals. All price values in the contract are in USDT's smallest unit (1 = 0.000001 USDT).
