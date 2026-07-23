// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC165, IERC7802} from '@optimism/interfaces/L2/IERC7802.sol';
import {ISemver} from '@optimism/interfaces/universal/ISemver.sol';
import {Predeploys} from '@optimism/src/libraries/Predeploys.sol';
import {Unauthorized} from '@optimism/src/libraries/errors/CommonErrors.sol';

import {
    IERC20PermitUpgradeable,
    IERC20Upgradeable,
    IERC5805Upgradeable
} from '@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol';
import {
    ERC20PermitUpgradeable,
    ERC20Upgradeable,
    ERC20VotesUpgradeable
} from '@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol';
import {SafeCastUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol';
import {IERC20} from '@openzeppelin/contracts/interfaces/IERC20.sol';

import {Flaunch} from '@flaunch/Flaunch.sol';

import {IMemecoin} from '@flaunch-interfaces/IMemecoin.sol';

/**
 * The ERC20 memecoin created when a new token is flaunched.
 */
contract Memecoin is ERC20PermitUpgradeable, ERC20VotesUpgradeable, IERC7802, IMemecoin, ISemver {
    error MintAddressIsZero();
    error CallerNotFlaunch();
    error Permit2AllowanceIsFixedAtInfinity();

    /// Emitted when the metadata is updated for the token
    event MetadataUpdated(string _name, string _symbol);

    /// Token name
    string private _name;

    /// Token symbol
    string private _symbol;

    /// Token URI
    string public tokenURI;

    /// The respective Flaunch ERC721 for this contract
    Flaunch public flaunch;

    /// @dev The canonical Permit2 address.
    /// For signature-based allowance granting for single transaction ERC20 `transferFrom`.
    /// To enable, override `_givePermit2InfiniteAllowance()`.
    /// [Github](https://github.com/Uniswap/permit2)
    /// [Etherscan](https://etherscan.io/address/0x000000000022D473030F116dDEE9F6B43aC78BA3)
    address internal constant _PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /**
     * Calling this in the constructor will prevent the contract from being initialized or
     * reinitialized. It is recommended to use this to lock implementation contracts that
     * are designed to be called through proxies.
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * Sets our initial token metadata, registers our inherited contracts
     *
     * @param name_ The name for the token
     * @param symbol_ The symbol for the token
     * @param tokenUri_ The URI for the token
     */
    function initialize(
        string calldata name_,
        string calldata symbol_,
        string calldata tokenUri_
    ) public override initializer {
        // Initialises our token based on the implementation
        _name = name_;
        _symbol = symbol_;
        tokenURI = tokenUri_;

        flaunch = Flaunch(msg.sender);

        // Initialise our voting related extensions
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
        __ERC20Votes_init();
    }

    /**
     * Allows our creating contract to mint additional ERC20 tokens when required.
     *
     * @param _to The recipient of the minted token
     * @param _amount The number of tokens to mint
     */
    function mint(
        address _to,
        uint _amount
    ) public virtual override onlyFlaunch {
        if (_to == address(0)) {
            revert MintAddressIsZero();
        }
        _mint(_to, _amount);
    }

    /**
     * Destroys a `value` amount of tokens from the caller.
     *
     * See {ERC20-_burn}.
     */
    function burn(
        uint value
    ) public override {
        _burn(msg.sender, value);
    }

    function _mint(
        address to,
        uint amount
    ) internal override(ERC20Upgradeable, ERC20VotesUpgradeable) {
        super._mint(to, amount);
    }

    function _burn(
        address account,
        uint amount
    ) internal override(ERC20Upgradeable, ERC20VotesUpgradeable) {
        super._burn(account, amount);
    }

    /**
     * Destroys a `value` amount of tokens from `account`, deducting from
     * the caller's allowance.
     *
     * See {ERC20-_burn} and {ERC20-allowance}.
     */
    function burnFrom(
        address account,
        uint value
    ) public override {
        _spendAllowance(account, msg.sender, value);
        _burn(account, value);
    }

    /**
     * Allows a contract owner to update the name and symbol of the ERC20 token so
     * that if one is created with malformed, unintelligible or offensive data then
     * we can replace it.
     *
     * @param name_ The new name for the token
     * @param symbol_ The new symbol for the token
     */
    function setMetadata(
        string calldata name_,
        string calldata symbol_
    ) public override onlyFlaunch {
        _name = name_;
        _symbol = symbol_;

        emit MetadataUpdated(_name, _symbol);
        emit EIP712DomainChanged();
    }

    /**
     * Returns the name of the token.
     */
    function name() public view override(ERC20Upgradeable, IMemecoin) returns (string memory) {
        return _name;
    }

    /**
     * Returns the symbol of the token, usually a shorter version of the name.
     */
    function symbol() public view override(ERC20Upgradeable, IMemecoin) returns (string memory) {
        return _symbol;
    }

    /**
     * Returns the dynamic token name used by the EIP-712 domain separator.
     *
     * @dev Keep this in sync with {name} so renamed memecoins can still use permit signatures.
     */
    function _EIP712Name() internal view override returns (string memory) {
        return _name;
    }

    /**
     * Use timestamp based checkpoints for voting.
     */
    function clock() public view virtual override(ERC20VotesUpgradeable, IMemecoin) returns (uint48) {
        return SafeCastUpgradeable.toUint48(block.timestamp);
    }

    /**
     * The clock is timestamp based.
     */
    function CLOCK_MODE() public view virtual override returns (string memory) {
        return 'mode=timestamp&from=default';
    }

    /**
     * Finds the "creator" of the memecoin, which equates to the owner of the {Flaunch} ERC721. This
     * means that if the NFT is traded, then the new holder would become the creator.
     *
     * @dev This also means that if the token is burned we can expect a zero-address response
     *
     * @return creator_ The "creator" of the memecoin
     */
    function creator() public view override returns (address creator_) {
        uint tokenId = flaunch.tokenId(address(this));

        // Handle case where the token has been burned. This is wrapped in a try/catch as we don't
        // want to revert if the token has a zero address owner (the default ERC721 logic).
        try flaunch.ownerOf(tokenId) returns (address owner) {
            creator_ = owner;
        } catch {}
    }

    /**
     * Finds the {MemecoinTreasury} contract associated with the memecoin.
     *
     * @dev This will still be non-zero even if the held token is burned.
     *
     * @return The address of the {MemecoinTreasury}
     */
    function treasury() public view override returns (address payable) {
        uint tokenId = flaunch.tokenId(address(this));
        return flaunch.memecoinTreasury(tokenId);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          PERMIT2                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * Returns whether to fix the Permit2 contract's allowance at infinity.
     */
    function _givePermit2InfiniteAllowance() internal view virtual returns (bool) {
        return true;
    }

    /**
     * Override to support Permit2 infinite allowance.
     */
    function allowance(
        address owner,
        address spender
    ) public view override(ERC20Upgradeable, IERC20Upgradeable) returns (uint) {
        if (_givePermit2InfiniteAllowance()) {
            if (spender == _PERMIT2) {
                return type(uint).max;
            }
        }
        return super.allowance(owner, spender);
    }

    /**
     * Override to support Permit2 infinite allowance.
     */
    function approve(
        address spender,
        uint amount
    ) public override(ERC20Upgradeable, IERC20Upgradeable) returns (bool) {
        if (_givePermit2InfiniteAllowance()) {
            if (spender == _PERMIT2 && amount != type(uint).max) {
                revert Permit2AllowanceIsFixedAtInfinity();
            }
        }
        return super.approve(spender, amount);
    }

    /**
     * Override required functions from inherited contracts.
     */
    function _afterTokenTransfer(
        address from,
        address to,
        uint amount
    ) internal override(ERC20Upgradeable, ERC20VotesUpgradeable) {
        super._afterTokenTransfer(from, to, amount);

        // Auto self-delegation if the recipient hasn't delegated yet
        if (to != address(0) && delegates(to) == address(0)) {
            _delegate(to, to);
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      SuperchainERC20                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * Semantic version of the SuperchainERC20 that is implemented.
     *
     * @custom:semver 1.0.2
     *
     * @return string String representation of the implemented version
     */
    function version() external view virtual returns (string memory) {
        return '1.0.2';
    }

    /**
     * Allows the SuperchainTokenBridge to mint tokens.
     *
     * @param _to Address to mint tokens to.
     * @param _amount Amount of tokens to mint.
     */
    function crosschainMint(
        address _to,
        uint _amount
    ) external onlySuperchain {
        _mint(_to, _amount);
        emit CrosschainMint(_to, _amount, msg.sender);
    }

    /**
     * Allows the SuperchainTokenBridge to burn tokens.
     *
     * @param _from Address to burn tokens from.
     * @param _amount Amount of tokens to burn.
     */
    function crosschainBurn(
        address _from,
        uint _amount
    ) external onlySuperchain {
        _burn(_from, _amount);
        emit CrosschainBurn(_from, _amount, msg.sender);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     Interface Support                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * Define our supported interfaces through contract extension.
     *
     * @dev Implements IERC165 via IERC7802
     */
    function supportsInterface(
        bytes4 _interfaceId
    ) public view virtual override returns (bool) {
        return
        // Base token interfaces
        (_interfaceId == type(IERC20).interfaceId || _interfaceId == type(IERC20Upgradeable).interfaceId
                // Permit interface
                || _interfaceId == type(IERC20PermitUpgradeable).interfaceId
                // ERC20VotesUpgradable interface
                || _interfaceId == type(IERC5805Upgradeable).interfaceId
                // Superchain interfaces
                || _interfaceId == type(IERC7802).interfaceId || _interfaceId == type(IERC165).interfaceId
                // Memecoin interface
                || _interfaceId == type(IMemecoin).interfaceId);
    }

    /**
     * Ensures that only it's respective Flaunch contract is making the call.
     */
    modifier onlyFlaunch() {
        if (msg.sender != address(flaunch)) {
            revert CallerNotFlaunch();
        }
        _;
    }

    /**
     * Ensures that only the Superchain is making the call.
     */
    modifier onlySuperchain() {
        if (msg.sender != Predeploys.SUPERCHAIN_TOKEN_BRIDGE) {
            revert Unauthorized();
        }
        _;
    }
}
