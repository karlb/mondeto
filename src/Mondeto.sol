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
    uint16 public constant WIDTH = 300;
    uint16 public constant HEIGHT = 200;
    uint256 public constant TOTAL_PIXELS = 60_000;
    uint256 public constant HALF_YEAR = 182 days;
    uint256 public constant LAND_MASK_LENGTH = 235;

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

    struct PixelView {
        uint256 id;
        address owner;
        uint8 saleCount;
        uint256 price;
        uint24 color;
        bool isLand;
    }

    // --- State ---
    IERC20 public usdt;
    uint256 public deployTimestamp;
    uint256 public initialPrice;
    uint256 public minPrice;

    mapping(uint256 => PixelData) public pixels;
    mapping(address => OwnerProfile) public profiles;
    uint256[235] public landMask;

    // --- Events ---
    event PixelsPurchased(address indexed buyer, uint256[] ids, uint256 totalCost);
    event ProfileUpdated(address indexed user, uint24 color, bytes label, bytes url);
    event LandMaskSet();

    // --- Errors ---
    error InvalidPixelId(uint256 id);
    error NotLand(uint256 id);
    error LabelTooLong();
    error UrlTooLong();
    error InvalidMaskLength();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _usdt, uint256 _initialPrice, uint256 _minPrice) external initializer {
        __Ownable_init(msg.sender);

        usdt = IERC20(_usdt);
        deployTimestamp = block.timestamp;
        initialPrice = _initialPrice;
        minPrice = _minPrice;
    }

    // --- Core ---

    function buyPixels(
        uint256[] calldata ids,
        uint24 color,
        string calldata label,
        string calldata url
    ) external nonReentrant {
        if (bytes(label).length > 64) revert LabelTooLong();
        if (bytes(url).length > 64) revert UrlTooLong();

        uint256 epoch = currentEpoch();
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
            uint256 price = _price(px.saleCount, epoch);
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
            OwnerProfile storage profile = profiles[msg.sender];
            profile.color = color;
            profile.label = bytes(label);
            profile.url = bytes(url);
            emit ProfileUpdated(msg.sender, color, bytes(label), bytes(url));
        }

        emit PixelsPurchased(msg.sender, ids, totalCost);
    }

    function updateProfile(uint24 color, string calldata label, string calldata url) external {
        if (bytes(label).length > 64) revert LabelTooLong();
        if (bytes(url).length > 64) revert UrlTooLong();

        OwnerProfile storage profile = profiles[msg.sender];
        profile.color = color;
        profile.label = bytes(label);
        profile.url = bytes(url);

        emit ProfileUpdated(msg.sender, color, bytes(label), bytes(url));
    }

    // --- Views ---

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - deployTimestamp) / HALF_YEAR;
    }

    function pixelId(uint16 x, uint16 y) public pure returns (uint256) {
        return uint256(y) * WIDTH + x;
    }

    function priceOf(uint16 x, uint16 y) external view returns (uint256) {
        require(x < WIDTH && y < HEIGHT, "Invalid coords");
        uint256 id = pixelId(x, y);
        return _price(pixels[id].saleCount, currentEpoch());
    }

    function isLand(uint16 x, uint16 y) external view returns (bool) {
        require(x < WIDTH && y < HEIGHT, "Invalid coords");
        return _isLand(pixelId(x, y));
    }

    function getPixelBatch(uint16 x, uint16 y, uint16 w, uint16 h) external view returns (PixelView[] memory) {
        require(x + w <= WIDTH && y + h <= HEIGHT, "Out of bounds");

        uint256 epoch = currentEpoch();
        PixelView[] memory result = new PixelView[](uint256(w) * h);
        uint256 idx;

        for (uint16 row = y; row < y + h; ++row) {
            for (uint16 col = x; col < x + w; ++col) {
                uint256 id = pixelId(col, row);
                PixelData storage px = pixels[id];
                address owner = px.owner;
                uint24 color;
                if (owner != address(0)) {
                    color = profiles[owner].color;
                }
                result[idx] = PixelView({
                    id: id,
                    owner: owner,
                    saleCount: px.saleCount,
                    price: _price(px.saleCount, epoch),
                    color: color,
                    isLand: _isLand(id)
                });
                idx++;
            }
        }
        return result;
    }

    function rectanglePrice(uint16 x, uint16 y, uint16 w, uint16 h) external view returns (uint256) {
        require(x + w <= WIDTH && y + h <= HEIGHT, "Out of bounds");

        uint256 epoch = currentEpoch();
        uint256 total;

        for (uint16 row = y; row < y + h; ++row) {
            for (uint16 col = x; col < x + w; ++col) {
                uint256 id = pixelId(col, row);
                total += _price(pixels[id].saleCount, epoch);
            }
        }
        return total;
    }

    function selectionPrice(uint256[] calldata ids) external view returns (uint256) {
        uint256 epoch = currentEpoch();
        uint256 total;
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] >= TOTAL_PIXELS) revert InvalidPixelId(ids[i]);
            total += _price(pixels[ids[i]].saleCount, epoch);
        }
        return total;
    }

    // --- Admin ---

    function setLandMask(uint256[] calldata mask) external onlyOwner {
        if (mask.length != LAND_MASK_LENGTH) revert InvalidMaskLength();
        for (uint256 i; i < LAND_MASK_LENGTH; ++i) {
            landMask[i] = mask[i];
        }
        emit LandMaskSet();
    }

    function withdraw(address to, uint256 amount) external onlyOwner {
        usdt.safeTransfer(to, amount);
    }

    function setInitialPrice(uint256 _initialPrice) external onlyOwner {
        initialPrice = _initialPrice;
    }

    // --- Internal ---

    function _price(uint8 saleCount, uint256 epoch) internal view returns (uint256) {
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
