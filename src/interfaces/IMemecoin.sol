// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20Upgradeable} from '@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol';

interface IMemecoin is IERC20Upgradeable {
    function initialize(
        string calldata name_,
        string calldata symbol_,
        string calldata tokenUri_
    ) external;

    function mint(
        address _to,
        uint _amount
    ) external;

    function burn(
        uint value
    ) external;

    function burnFrom(
        address account,
        uint value
    ) external;

    function setMetadata(
        string calldata name_,
        string calldata symbol_
    ) external;

    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function tokenURI() external view returns (string memory);

    function clock() external view returns (uint48);

    function creator() external view returns (address);

    function treasury() external view returns (address payable);
}
