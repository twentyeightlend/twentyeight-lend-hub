// Minimal ABIs for keeper interactions. MarketParams is the (loanToken,veAdapter,oracle,irm,lltv)
// tuple; viem encodes it as a struct argument.
export const MARKET_PARAMS = {
    type: "tuple",
    components: [
        { name: "loanToken", type: "address" },
        { name: "veAdapter", type: "address" },
        { name: "oracle", type: "address" },
        { name: "irm", type: "address" },
        { name: "lltv", type: "uint256" }
    ]
};

export const SWAP = {
    type: "tuple[]",
    components: [
        { name: "tokenIn", type: "address" },
        { name: "minOut", type: "uint256" },
        { name: "data", type: "bytes" }
    ]
};

export const lendingCoreAbi = [
    { type: "event", name: "SupplyCollateral", inputs: [
        { name: "id", type: "bytes32", indexed: true },
        { name: "tokenId", type: "uint256", indexed: true },
        { name: "onBehalf", type: "address", indexed: true }
    ]},
    { type: "event", name: "WithdrawCollateral", inputs: [
        { name: "id", type: "bytes32", indexed: true },
        { name: "tokenId", type: "uint256", indexed: true },
        { name: "receiver", type: "address", indexed: false }
    ]},
    { name: "position", type: "function", stateMutability: "view",
      inputs: [{ type: "bytes32" }, { type: "uint256" }],
      outputs: [{ name: "borrower", type: "address" }, { name: "borrowShares", type: "uint128" },
                { name: "creditLine", type: "uint128" }, { name: "creditLineExpiry", type: "uint64" }] },
    { name: "vote", type: "function", stateMutability: "nonpayable",
      inputs: [MARKET_PARAMS, { name: "tokenId", type: "uint256" }, { name: "voteData", type: "bytes" }], outputs: [] },
    { name: "refreshCreditLine", type: "function", stateMutability: "nonpayable",
      inputs: [MARKET_PARAMS, { name: "tokenId", type: "uint256" }], outputs: [{ type: "uint256" }] }
];

export const selfRepayEngineAbi = [
    { name: "selfRepay", type: "function", stateMutability: "nonpayable",
      inputs: [MARKET_PARAMS, { name: "tokenId", type: "uint256" }, { ...SWAP, name: "swaps" }], outputs: [] }
];

export const marketAbi = [
    { type: "event", name: "Borrow", inputs: [
        { name: "borrower", type: "address", indexed: true },
        { name: "receiver", type: "address", indexed: false },
        { name: "assets", type: "uint256", indexed: false },
        { name: "shares", type: "uint256", indexed: false }
    ]},
    { type: "event", name: "SupplyCollateral", inputs: [
        { name: "onBehalf", type: "address", indexed: true },
        { name: "amount", type: "uint256", indexed: false }
    ]},
    { type: "event", name: "Liquidate", inputs: [
        { name: "borrower", type: "address", indexed: true },
        { name: "liquidator", type: "address", indexed: true },
        { name: "repaid", type: "uint256", indexed: false },
        { name: "seized", type: "uint256", indexed: false },
        { name: "badDebt", type: "uint256", indexed: false }
    ]},
    { name: "totalSupplyAssets", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint128" }] },
    { name: "totalBorrowAssets", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint128" }] },
    { name: "isHealthy", type: "function", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "bool" }] },
    { name: "position", type: "function", stateMutability: "view", inputs: [{ type: "address" }],
      outputs: [{ name: "collateral", type: "uint128" }, { name: "borrowShares", type: "uint128" }] },
    { name: "accrueInterest", type: "function", stateMutability: "nonpayable", inputs: [], outputs: [] },
    { name: "totalCollateral", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
    { name: "harvestCollateralRewards", type: "function", stateMutability: "nonpayable", inputs: [], outputs: [] },
    { name: "liquidate", type: "function", stateMutability: "nonpayable",
      inputs: [{ name: "borrower", type: "address" }, { name: "seizeRequested", type: "uint256" }],
      outputs: [{ type: "uint256" }, { type: "uint256" }] }
];

// Both NEST (Dromos) and KITTEN voters expose poolVoteLength(tokenId) — used to detect whether a
// custodied position currently has votes (0 => needs (re)voting, e.g. after custody/epoch reset).
export const voterReadAbi = [
    { name: "poolVoteLength", type: "function", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "uint256" }] }
];

export const pythAbi = [
    { name: "updatePriceFeeds", type: "function", stateMutability: "payable", inputs: [{ name: "updateData", type: "bytes[]" }], outputs: [] },
    { name: "getUpdateFee", type: "function", stateMutability: "view", inputs: [{ name: "updateData", type: "bytes[]" }], outputs: [{ type: "uint256" }] }
];
