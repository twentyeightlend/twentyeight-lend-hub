// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketParams} from "../libraries/Types.sol";

/// @title ICreditLineManager
/// @notice Computes the max borrowable (loan-token units) for a veNFT position.
/// @dev This is where twentyeight-lend beats 40acres: the credit line is derived from
///      ON-CHAIN reward data (vote share x per-gauge fees), not a number pushed by an
///      off-chain relayer. Pure view => permissionlessly verifiable.
interface ICreditLineManager {
    /// @notice Max borrowable for `tokenId` in `mp`'s loanToken, using the conservative
    ///         trailing-MIN weekly cashflow x N_epochs (yield tier) and/or the
    ///         haircut principal value (term tier).
    function creditLine(MarketParams calldata mp, uint256 tokenId) external view returns (uint256);
}
