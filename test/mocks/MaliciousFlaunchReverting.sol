// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @notice A malicious Flaunch contract that always reverts when ownerOf() is called.
 *         This is used to test the Indexer's handling of contracts that revert on ownerOf().
 *
 * @dev The contract implements a bidirectional mapping between tokenId and memecoin to pass
 *      validation in addIndex(), but ownerOf() always reverts.
 */
contract MaliciousFlaunchReverting {
    address public immutable positionManagerAddress;

    address public immutable revertSenderAddress;

    // Bidirectional mapping to pass validation: tokenId <-> memecoin
    // Public mappings automatically create getter functions
    mapping(address => uint) public tokenId;
    mapping(uint => address) public memecoin;
    mapping(uint => address) public memecoinTreasury;

    constructor(
        address _positionManager,
        address _revertSender
    ) {
        positionManagerAddress = _positionManager;
        revertSenderAddress = _revertSender;
    }

    /**
     * @notice Always reverts, regardless of tokenId
     * @dev This is the malicious behavior we're testing against
     */
    function ownerOf(
        uint /* tokenId */
    ) external view returns (address) {
        if (msg.sender == revertSenderAddress) {
            revert('MaliciousFlaunch: ownerOf always reverts');
        }

        return address(this);
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
