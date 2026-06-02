// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC4626} from "solady/tokens/ERC4626.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {LendingCore} from "./LendingCore.sol";
import {MarketParams, Id, Market, MarketParamsLib} from "./libraries/Types.sol";
import {SharesMathLib} from "./libraries/SharesMathLib.sol";

/// @title LenderVault
/// @notice ERC-4626 wrapper over a single market's lender side. Depositors get a fungible,
///         composable receipt while the underlying loanToken is supplied to LendingCore and
///         earns borrower interest. Inherits solady's virtual-shares inflation protection.
contract LenderVault is ERC4626 {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    LendingCore public immutable core;
    address internal immutable _asset;
    string internal _name;
    string internal _symbol;

    // MarketParams stored field-wise (immutable) to rebuild on demand.
    address internal immutable _loanToken;
    address internal immutable _veAdapter;
    address internal immutable _oracle;
    address internal immutable _irm;
    uint256 internal immutable _lltv;

    constructor(address _core, MarketParams memory p, string memory name_, string memory symbol_) {
        core = LendingCore(_core);
        _asset = p.loanToken;
        _loanToken = p.loanToken;
        _veAdapter = p.veAdapter;
        _oracle = p.oracle;
        _irm = p.irm;
        _lltv = p.lltv;
        _name = name_;
        _symbol = symbol_;
        SafeTransferLib.safeApproveWithRetry(p.loanToken, _core, type(uint256).max);
    }

    function marketParams() public view returns (MarketParams memory p) {
        p = MarketParams({
            loanToken: _loanToken,
            veAdapter: _veAdapter,
            oracle: _oracle,
            irm: _irm,
            lltv: _lltv
        });
    }

    function asset() public view override returns (address) {
        return _asset;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /// @dev Vault holds no idle asset; its assets are its claim on the core market.
    function totalAssets() public view override returns (uint256) {
        Id id = marketParams().id();
        (uint128 tsa, uint128 tss,,,,) = core.market(id);
        uint256 shares = core.supplyShares(id, address(this));
        return shares.toAssetsDown(tsa, tss);
    }

    /// @dev Solady has pulled `assets` loanToken into this vault — forward them to the core.
    function _afterDeposit(uint256 assets, uint256) internal override {
        core.supply(marketParams(), assets, address(this));
    }

    /// @dev Pull `assets` back from the core before solady pays out the redeemer.
    function _beforeWithdraw(uint256 assets, uint256) internal override {
        core.withdraw(marketParams(), assets, address(this), address(this));
    }
}
