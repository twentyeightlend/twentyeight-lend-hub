import { createConfig, http } from "wagmi";
import { injected } from "wagmi/connectors";
import { defineChain } from "viem";

export const hyperEVM = defineChain({
  id: 999,
  name: "HyperEVM",
  nativeCurrency: { name: "HYPE", symbol: "HYPE", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.hyperliquid.xyz/evm"] } },
  blockExplorers: { default: { name: "Hyperscan", url: "https://www.hyperscan.com" } },
});

export const config = createConfig({
  chains: [hyperEVM],
  connectors: [injected()],
  transports: { [hyperEVM.id]: http() },
});

declare module "wagmi" {
  interface Register {
    config: typeof config;
  }
}
