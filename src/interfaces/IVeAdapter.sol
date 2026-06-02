// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IVeAdapter
/// @notice Per-protocol shim that lets the immutable LendingCore treat NEST (Dromos),
///         KITTEN (Velodrome/Algebra) and future ve protocols uniformly.
/// @dev The adapter is the CUSTODIAN of the collateral veNFT while a loan is open: it is
///      the only place that knows the protocol-specific Voter/bribe wiring, so harvesting
///      and (re)voting must flow through it. All mutating entrypoints MUST be gated to the
///      bound LendingCore (onlyCore) in the concrete implementation.
interface IVeAdapter {
    /// @notice Emergency switch. When true, the bound ve protocol's proxies are considered
    ///         compromised (e.g. an unexpected implementation upgrade) and the core must block
    ///         new risk (borrow/deposit/harvest/vote) while still allowing exits.
    function paused() external view returns (bool);

    /// @notice The locked ERC20 underlying the veNFT (NEST or KITTEN).
    function underlyingToken() external view returns (address);

    /// @notice The vote-escrow ERC721 this adapter custodies.
    function votingEscrow() external view returns (address);

    // ---------------------------------------------------------------------
    // Intake / recovery
    // ---------------------------------------------------------------------

    /// @notice Pull `tokenId` from `from` into adapter custody. Reverts if the veNFT
    ///         is not acceptable collateral (see {isAcceptableCollateral}).
    /// @dev Implementation MUST strip any outstanding approvals on intake.
    function custody(uint256 tokenId, address from) external;

    /// @notice Return a fully-repaid veNFT to `to`.
    function recoverUnderlying(uint256 tokenId, address to) external;

    // ---------------------------------------------------------------------
    // Collateral assessment
    // ---------------------------------------------------------------------

    /// @notice True if the lock never expires (e.g. ~97% of veNEST). Permanent locks
    ///         have no maturity, so only the self-repaying tier applies to them.
    function isPermanentLock(uint256 tokenId) external view returns (bool);

    /// @notice Unlock timestamp; 0 (or type(uint256).max) for permanent locks.
    function lockEnd(uint256 tokenId) external view returns (uint256);

    /// @notice Underlying token amount locked in the veNFT.
    function lockedAmount(uint256 tokenId) external view returns (uint256);

    /// @notice Current decayed voting power of the veNFT.
    function currentVotingPower(uint256 tokenId) external view returns (uint256);

    /// @notice Gate run at deposit time. Rejects managed/attached/expired/non-standard
    ///         escrow states (see Debita #535: non-NORMAL escrowType is CRITICAL).
    function isAcceptableCollateral(uint256 tokenId)
        external
        view
        returns (bool ok, string memory reason);

    // ---------------------------------------------------------------------
    // Cashflow (the underwriting fuel)
    // ---------------------------------------------------------------------

    /// @notice View estimate of currently-claimable reward tokens for `tokenId`
    ///         (trading fees + bribes across the gauges it voted).
    function harvestableYield(uint256 tokenId)
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts);

    /// @notice Claim all rewards for `tokenId` to `to`. Returns what was actually claimed.
    /// @dev Called only by the SelfRepayEngine via the core.
    function harvest(uint256 tokenId, address to)
        external
        returns (address[] memory tokens, uint256[] memory amounts);

    // ---------------------------------------------------------------------
    // Governance passthrough
    // ---------------------------------------------------------------------

    /// @notice Cast/refresh votes for a custodied veNFT. Keeping the position voting is
    ///         required to keep earning fees (Velodrome C4 #185). `voteData` is
    ///         protocol-specific (decoded by the adapter).
    function vote(uint256 tokenId, bytes calldata voteData) external;
}
