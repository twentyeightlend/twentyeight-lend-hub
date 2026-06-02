import { type Address, encodeAbiParameters, keccak256 } from "viem";

// ---- deployed addresses (HyperEVM mainnet, chainId 999) ----
export const ADDR = {
  core: "0x545C9C426d968329f95F21146291E0C727015852" as Address,
  usdc: "0xb88339CB7199b77E23DB6E890353E22632Ba630f" as Address,
  irm: "0xEA58bC25A7F096fcDFbFb3aDbEDabC9edF096C42" as Address,
  nestAdapter: "0x63BA0cf6b4bf32A1c4E3C1C9076a5dadB7F216c1" as Address,
  kittenAdapter: "0x295D025258E72dA9203F3aAA777Fe61B297af415" as Address,
};

export const USDC_DECIMALS = 6;
const ZERO = "0x0000000000000000000000000000000000000000" as Address;

// MarketParams tuple -> Id (must match the on-chain keccak(abi.encode(params)))
const MARKET_PARAMS_TUPLE = {
  type: "tuple",
  components: [
    { name: "loanToken", type: "address" },
    { name: "veAdapter", type: "address" },
    { name: "oracle", type: "address" },
    { name: "irm", type: "address" },
    { name: "lltv", type: "uint256" },
  ],
} as const;

export type MarketParams = {
  loanToken: Address;
  veAdapter: Address;
  oracle: Address;
  irm: Address;
  lltv: bigint;
};

export function marketParams(adapter: Address): MarketParams {
  return { loanToken: ADDR.usdc, veAdapter: adapter, oracle: ZERO, irm: ADDR.irm, lltv: 0n };
}
export function marketId(p: MarketParams) {
  return keccak256(encodeAbiParameters([MARKET_PARAMS_TUPLE], [p]));
}

export const MARKETS = [
  { key: "NEST", label: "veNEST", params: marketParams(ADDR.nestAdapter) },
  { key: "KITTEN", label: "veKITTEN", params: marketParams(ADDR.kittenAdapter) },
] as const;

// ---- ABIs (only what the UI uses) ----
export const erc20Abi = [
  { name: "balanceOf", type: "function", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "allowance", type: "function", stateMutability: "view", inputs: [{ type: "address" }, { type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "approve", type: "function", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "bool" }] },
] as const;

export const coreAbi = [
  { name: "supply", type: "function", stateMutability: "nonpayable", inputs: [MARKET_PARAMS_TUPLE, { name: "assets", type: "uint256" }, { name: "onBehalf", type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "withdraw", type: "function", stateMutability: "nonpayable", inputs: [MARKET_PARAMS_TUPLE, { name: "assets", type: "uint256" }, { name: "onBehalf", type: "address" }, { name: "receiver", type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "supplyShares", type: "function", stateMutability: "view", inputs: [{ type: "bytes32" }, { type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "market", type: "function", stateMutability: "view", inputs: [{ type: "bytes32" }],
    outputs: [{ type: "uint128" }, { type: "uint128" }, { type: "uint128" }, { type: "uint128" }, { type: "uint128" }, { type: "uint128" }] },
] as const;

export const irmAbi = [
  { name: "aprAtUtilization", type: "function", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "uint256" }] },
] as const;
