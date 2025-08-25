// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ERC1155DualPosition
 * @notice ERC-1155 token representing dual investment positions
 * @dev Token ID encoding: keccak256(underlying, strike, expiry, direction, marketId)
 */
contract ERC1155DualPosition is ERC1155, Ownable, ReentrancyGuard {
    // Direction constants
    uint8 public constant DIRECTION_CALL = 0; // Bullish (above strike)
    uint8 public constant DIRECTION_PUT = 1; // Bearish (below strike)

    // Position data structure
    struct Position {
        address user;
        address cTokenIn; // Input cToken (collateral)
        address cTokenOut; // Output cToken (settlement asset)
        uint128 notional; // Notional amount
        uint64 expiry; // Expiry timestamp
        uint64 strike; // Strike price (18 decimals)
        uint8 direction; // 0 = call, 1 = put
        bool settled; // Settlement status
    }

    // Mappings
    mapping(uint256 => Position) public positions;
    mapping(address => bool) public authorizedMinters;

    // Events
    event PositionCreated(
        uint256 indexed tokenId,
        address indexed user,
        address cTokenIn,
        address cTokenOut,
        uint128 notional,
        uint64 expiry,
        uint64 strike,
        uint8 direction
    );

    event PositionSettled(uint256 indexed tokenId, address indexed user, bool aboveStrike, uint256 payout);

    modifier onlyAuthorized() {
        require(authorizedMinters[msg.sender], "Not authorized to mint");
        _;
    }

    constructor() ERC1155("") Ownable(msg.sender) {}

    /**
     * @notice Generate token ID for a position
     * @param underlying Underlying asset address
     * @param strike Strike price (18 decimals)
     * @param expiry Expiry timestamp
     * @param direction Position direction (0=call, 1=put)
     * @param marketId Market identifier
     */
    function generateTokenId(address underlying, uint64 strike, uint64 expiry, uint8 direction, uint256 marketId)
        public
        pure
        returns (uint256)
    {
        return uint256(keccak256(abi.encode(underlying, strike, expiry, direction, marketId)));
    }

    /**
     * @notice Generate token ID for a position that is unique per user
     * @dev This prevents different users from sharing the same tokenId
     */
    function generateTokenIdForUser(
        address user,
        address underlying,
        uint64 strike,
        uint64 expiry,
        uint8 direction,
        uint256 marketId
    ) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(underlying, strike, expiry, direction, marketId, user)));
    }

    /**
     * @notice Mint position tokens
     * @param to Address to mint to
     * @param tokenId Token ID to mint
     * @param amount Amount to mint
     * @param position Position data
     */
    function mintPosition(address to, uint256 tokenId, uint256 amount, Position memory position)
        external
        onlyAuthorized
        nonReentrant
    {
        require(to != address(0), "Cannot mint to zero address");
        require(amount > 0, "Amount must be greater than zero");
        require(position.expiry > block.timestamp, "Position already expired");
        require(position.direction == DIRECTION_CALL || position.direction == DIRECTION_PUT, "Invalid direction");

        // Store position data
        positions[tokenId] = position;

        // Mint the token
        _mint(to, tokenId, amount, "");

        emit PositionCreated(
            tokenId,
            position.user,
            position.cTokenIn,
            position.cTokenOut,
            position.notional,
            position.expiry,
            position.strike,
            position.direction
        );
    }

    /**
     * @notice Burn position tokens upon settlement
     * @param from Address to burn from
     * @param tokenId Token ID to burn
     * @param amount Amount to burn
     */
    function burnPosition(address from, uint256 tokenId, uint256 amount) external onlyAuthorized nonReentrant {
        require(balanceOf(from, tokenId) >= amount, "Insufficient balance");

        _burn(from, tokenId, amount);

        // Mark as settled if fully burned
        Position storage position = positions[tokenId];
        if (balanceOf(from, tokenId) == 0) {
            position.settled = true;
        }
    }

    /**
     * @notice Set authorized minter status
     * @param minter Address to authorize/deauthorize
     * @param authorized Authorization status
     */
    function setAuthorizedMinter(address minter, bool authorized) external onlyOwner {
        authorizedMinters[minter] = authorized;
    }

    /**
     * @notice Get position data
     * @param tokenId Token ID to query
     */
    function getPosition(uint256 tokenId) external view returns (Position memory) {
        return positions[tokenId];
    }

    /**
     * @notice Check if position is expired
     * @param tokenId Token ID to check
     */
    function isExpired(uint256 tokenId) external view returns (bool) {
        return block.timestamp >= positions[tokenId].expiry;
    }

    /**
     * @notice Check if position is settled
     * @param tokenId Token ID to check
     */
    function isSettled(uint256 tokenId) external view returns (bool) {
        return positions[tokenId].settled;
    }

    /**
     * @notice Set URI for metadata (optional)
     * @param newuri New URI string
     */
    function setURI(string memory newuri) external onlyOwner {
        _setURI(newuri);
    }

    /**
     * @dev Disable transfers to prevent partial splits and ensure each position remains tied to its original holder until settlement/burn.
     * Allows only mint (from == address(0)) and burn (to == address(0)).
     */
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal override {
        // Only allow mint (from == 0) and burn (to == 0)
        require(from == address(0) || to == address(0), "Transfers disabled");
        super._update(from, to, ids, values);
    }
}
