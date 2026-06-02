// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Identifies an isolated market. Hash of MarketParams.
type Id is bytes32;

/// @notice Immutable parameters that fully define an isolated market.
/// @dev Mirrors the Morpho Blue ethos: the market is the hash of these params,
///      so the same (loanToken, veAdapter, oracle, irm, lltv) tuple always maps
///      to one market and nothing about it can be mutated after creation.
/// @param loanToken     ERC20 borrowers draw (e.g. native USDC 0xb883...).
/// @param veAdapter     IVeAdapter binding this market to one ve protocol (NEST or KITTEN).
/// @param oracle        Price source for the principal tier. address(0) => yield-only market.
/// @param irm           Interest rate model. address(0) => 0% interest (pure self-repay).
/// @param lltv          Liquidation LTV (WAD). Unused when oracle == address(0).
struct MarketParams {
    address loanToken;
    address veAdapter;
    address oracle;
    address irm;
    uint256 lltv;
}

/// @notice Mutable aggregate state of a market.
struct Market {
    uint128 totalSupplyAssets;
    uint128 totalSupplyShares;
    uint128 totalBorrowAssets;
    uint128 totalBorrowShares;
    uint128 lastUpdate;
    uint128 fee; // WAD, share of interest taken to treasury
}

/// @notice A single borrower position, keyed by the custodied veNFT.
/// @dev One veNFT == one position. `borrower` owns the right to repay/withdraw it.
/// @param borrower         Owner of the position (not necessarily the original depositor).
/// @param borrowShares     Borrow shares owed against this veNFT.
/// @param creditLine       Cached max borrowable (loanToken units) from cashflow underwriting.
/// @param creditLineExpiry Timestamp after which creditLine must be refreshed before borrowing.
struct Position {
    address borrower;
    uint128 borrowShares;
    uint128 creditLine;
    uint64 creditLineExpiry;
}

library MarketParamsLib {
    /// @dev keccak of the 5-word struct. Same layout as Morpho for tooling familiarity.
    function id(MarketParams memory p) internal pure returns (Id) {
        return Id.wrap(keccak256(abi.encode(p)));
    }
}
