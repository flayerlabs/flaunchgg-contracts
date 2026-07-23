// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @notice A malicious Flaunch contract that always returns a malicious address for ownerOf()
 *         regardless of the tokenId provided. This is used to test the Indexer's handling of
 *         potentially malicious contracts.
 *
 * @dev The contract implements a bidirectional mapping between tokenId and memecoin to pass
 *      validation in addIndex(), but ownerOf() always returns the malicious address.
 */
contract MaliciousFlaunch {
    address public immutable MALICIOUS_ADDRESS;
    address public immutable positionManagerAddress;

    // Bidirectional mapping to pass validation: tokenId <-> memecoin
    // Public mappings automatically create getter functions
    mapping(address => uint) public tokenId;
    mapping(uint => address) public memecoin;
    mapping(uint => address) public memecoinTreasury;

    constructor(
        address _maliciousAddress,
        address _positionManager
    ) {
        MALICIOUS_ADDRESS = _maliciousAddress;
        positionManagerAddress = _positionManager;
    }

    /**
     * @notice Always returns the malicious address, regardless of tokenId
     * @dev This is the malicious behavior we're testing against - even burned tokens
     *      will return the malicious address instead of reverting
     */
    function ownerOf(
        uint /* tokenId */
    ) external view returns (address) {
        return MALICIOUS_ADDRESS;
    }

    /**
     * @notice Sets up the bidirectional mapping for a tokenId and memecoin
     * @dev This allows the contract to pass validation in addIndex()
     */
    function setupToken(
        uint _tokenId,
        address _memecoin,
        address _treasury
    ) external {
        memecoin[_tokenId] = _memecoin;
        tokenId[_memecoin] = _tokenId;
        memecoinTreasury[_tokenId] = _treasury;
    }

    /**
     * @notice Returns the position manager address
     */
    function positionManager() external view returns (address) {
        return positionManagerAddress;
    }
}
