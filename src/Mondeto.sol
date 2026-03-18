// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Mondeto is UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Constants ---
    uint256 public constant HALVING_TIME = 182 days;

    // --- Immutables (set in constructor, baked into implementation bytecode) ---
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint16 public immutable WIDTH;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint16 public immutable HEIGHT;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 public immutable TOTAL_PIXELS;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 public immutable LAND_MASK_LENGTH;

    // --- Structs ---
    struct PixelData {
        address owner;
        uint8 saleCount;
    }

    struct OwnerProfile {
        uint24 color;
        bytes label;
        bytes url;
    }

    // --- State ---
    IERC20 public usdt;
    uint256 public deployTimestamp;
    uint256 public initialPrice;
    uint256 public minPrice;

    mapping(uint256 => PixelData) public pixels;
    mapping(address => OwnerProfile) public profiles;
    uint256[] public landMask;

    // --- Events ---
    event PixelsPurchased(address indexed buyer, uint256[] ids, uint256 totalCost);
    event ProfileUpdated(address indexed user, uint24 color, bytes label, bytes url);

    // --- Errors ---
    error InvalidPixelId(uint256 id);
    error InvalidCoordinates();
    error OutOfBounds();
    error NotLand(uint256 id);
    error LabelTooLong();
    error UrlTooLong();
    error InvalidMaskLength();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(uint16 _width, uint16 _height) {
        WIDTH = _width;
        HEIGHT = _height;
        TOTAL_PIXELS = uint256(_width) * _height;
        LAND_MASK_LENGTH = (TOTAL_PIXELS + 255) / 256;
        _disableInitializers();
    }

    function initialize(
        address _usdt,
        uint256 _initialPrice,
        uint256 _minPrice,
        uint256[] calldata _landMask
    ) external initializer {
        __Ownable_init(msg.sender);

        if (_landMask.length != LAND_MASK_LENGTH) revert InvalidMaskLength();

        usdt = IERC20(_usdt);
        deployTimestamp = block.timestamp;
        initialPrice = _initialPrice;
        minPrice = _minPrice;

        for (uint256 i; i < _landMask.length; ++i) {
            landMask.push(_landMask[i]);
        }
    }

    // --- Core ---

    function buyPixels(
        uint256[] calldata ids,
        uint24 color,
        string calldata label,
        string calldata url
    ) external nonReentrant {
        _validateProfile(label, url);

        uint256 elapsed = block.timestamp - deployTimestamp;
        uint256 totalCost;

        // Temporary aggregation arrays — worst case each pixel has unique owner
        address[] memory recipients = new address[](ids.length);
        uint256[] memory amounts = new uint256[](ids.length);
        uint256 recipientCount;

        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            if (id >= TOTAL_PIXELS) revert InvalidPixelId(id);
            if (!_isLand(id)) revert NotLand(id);

            PixelData storage px = pixels[id];
            uint256 price = _price(px.saleCount, elapsed);
            totalCost += price;

            address prevOwner = px.owner;
            address recipient = prevOwner == address(0) ? address(this) : prevOwner;

            // Aggregate payment
            bool found;
            for (uint256 j; j < recipientCount; ++j) {
                if (recipients[j] == recipient) {
                    amounts[j] += price;
                    found = true;
                    break;
                }
            }
            if (!found) {
                recipients[recipientCount] = recipient;
                amounts[recipientCount] = price;
                recipientCount++;
            }

            // Update pixel state
            px.owner = msg.sender;
            if (px.saleCount < 255) {
                px.saleCount++;
            }
        }

        // Execute transfers
        for (uint256 i; i < recipientCount; ++i) {
            usdt.safeTransferFrom(msg.sender, recipients[i], amounts[i]);
        }

        // Conditionally update profile
        if (color != 0 || bytes(label).length > 0 || bytes(url).length > 0) {
            _setProfile(msg.sender, color, label, url);
        }

        emit PixelsPurchased(msg.sender, ids, totalCost);
    }

    function updateProfile(uint24 color, string calldata label, string calldata url) external {
        _validateProfile(label, url);
        _setProfile(msg.sender, color, label, url);
    }

    // --- Views ---

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - deployTimestamp) / HALVING_TIME;
    }

    function pixelId(uint16 x, uint16 y) public view returns (uint256) {
        return uint256(y) * WIDTH + x;
    }

    function priceOf(uint16 x, uint16 y) external view returns (uint256) {
        if (x >= WIDTH || y >= HEIGHT) revert InvalidCoordinates();
        uint256 id = pixelId(x, y);
        return _price(pixels[id].saleCount, block.timestamp - deployTimestamp);
    }

    function isLand(uint16 x, uint16 y) external view returns (bool) {
        if (x >= WIDTH || y >= HEIGHT) revert InvalidCoordinates();
        return _isLand(pixelId(x, y));
    }

    /// @notice Returns pixel data for land pixels in a rectangle. Each pixel is 24 bytes packed:
    ///         [0:20] owner address, [20:21] saleCount, [21:24] color (uint24 big-endian).
    ///         Water pixels are skipped. Order matches pixelId order (row-major, left-to-right).
    function getPixelBatch(uint16 x, uint16 y, uint16 w, uint16 h) external view returns (bytes memory) {
        if (x + w > WIDTH || y + h > HEIGHT) revert OutOfBounds();

        // Count land pixels to allocate exact size
        uint256 landCount;
        for (uint16 row = y; row < y + h; ++row) {
            for (uint16 col = x; col < x + w; ++col) {
                if (_isLand(pixelId(col, row))) landCount++;
            }
        }

        bytes memory result = new bytes(landCount * 24);
        uint256 offset;
        address cachedOwner;
        uint24 cachedColor;

        for (uint16 row = y; row < y + h; ++row) {
            for (uint16 col = x; col < x + w; ++col) {
                uint256 id = pixelId(col, row);
                if (!_isLand(id)) continue;

                PixelData storage px = pixels[id];
                address owner = px.owner;
                uint8 sc = px.saleCount;
                uint24 color;
                if (owner != address(0)) {
                    if (owner != cachedOwner) {
                        cachedOwner = owner;
                        cachedColor = profiles[owner].color;
                    }
                    color = cachedColor;
                }
                assembly {
                    let ptr := add(add(result, 32), offset)
                    mstore(ptr, shl(96, owner))
                    mstore8(add(ptr, 20), sc)
                    mstore8(add(ptr, 21), shr(16, color))
                    mstore8(add(ptr, 22), shr(8, color))
                    mstore8(add(ptr, 23), color)
                }
                offset += 24;
            }
        }
        return result;
    }

    function rectanglePrice(uint16 x, uint16 y, uint16 w, uint16 h) external view returns (uint256) {
        if (x + w > WIDTH || y + h > HEIGHT) revert OutOfBounds();

        uint256 elapsed = block.timestamp - deployTimestamp;
        uint256 total;

        for (uint16 row = y; row < y + h; ++row) {
            for (uint16 col = x; col < x + w; ++col) {
                uint256 id = pixelId(col, row);
                total += _price(pixels[id].saleCount, elapsed);
            }
        }
        return total;
    }

    function selectionPrice(uint256[] calldata ids) external view returns (uint256) {
        uint256 elapsed = block.timestamp - deployTimestamp;
        uint256 total;
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] >= TOTAL_PIXELS) revert InvalidPixelId(ids[i]);
            total += _price(pixels[ids[i]].saleCount, elapsed);
        }
        return total;
    }

    // --- Admin ---

    function withdraw(address to, uint256 amount) external onlyOwner {
        usdt.safeTransfer(to, amount);
    }

    function setInitialPrice(uint256 _initialPrice) external onlyOwner {
        initialPrice = _initialPrice;
    }

    // --- Internal ---

    function _validateProfile(string calldata label, string calldata url) internal pure {
        if (bytes(label).length > 64) revert LabelTooLong();
        if (bytes(url).length > 64) revert UrlTooLong();
    }

    function _setProfile(address user, uint24 color, string calldata label, string calldata url) internal {
        OwnerProfile storage profile = profiles[user];
        profile.color = color;
        profile.label = bytes(label);
        profile.url = bytes(url);
        emit ProfileUpdated(user, color, bytes(label), bytes(url));
    }

    function _price(uint8 saleCount, uint256 elapsed) internal view returns (uint256) {
        uint256 epochStart = elapsed / HALVING_TIME;
        uint256 remainder = elapsed % HALVING_TIME;

        uint256 pStart = _discretePrice(saleCount, epochStart);
        if (remainder == 0) return pStart;
        if (pStart == type(uint256).max) return type(uint256).max;

        uint256 pEnd = _discretePrice(saleCount, epochStart + 1);

        // Linear interpolation between adjacent power-of-2 price levels
        return pStart - (pStart - pEnd) * remainder / HALVING_TIME;
    }

    function _discretePrice(uint8 saleCount, uint256 epoch) internal view returns (uint256) {
        if (saleCount >= epoch) {
            uint256 shift = saleCount - epoch;
            if (shift >= 128) return type(uint256).max;
            return initialPrice << shift;
        } else {
            uint256 shift = epoch - saleCount;
            if (shift >= 128) return minPrice;
            uint256 p = initialPrice >> shift;
            return p < minPrice ? minPrice : p;
        }
    }

    function _isLand(uint256 id) internal view returns (bool) {
        return landMask[id / 256] & (1 << (id % 256)) != 0;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
