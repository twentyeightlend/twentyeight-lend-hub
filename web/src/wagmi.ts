import { createConfig, fallback, http } from "wagmi";
import { injected } from "wagmi/connectors";
import { defineChain } from "viem";

export const hyperEVM = defineChain({
  id: 999,
  name: "HyperEVM",
  nativeCurrency: { name: "HYPE", symbol: "HYPE", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.hyperliquid.xyz/evm"] } },
  blockExplorers: { default: { name: "Hyperscan", url: "https://www.hyperscan.com" } },
  contracts: { multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" } },
});

// Primary RPC from a gitignored env (keyed/dedicated endpoint, supports getLogs); falls back to
// verified free public RPCs (chainId 999). The env URL is never committed; set it in web/.env.local.
const PRIMARY = import.meta.env.VITE_RPC_URL as string | undefined;
const PUBLIC_RPCS = [
  "https://rpc.hyperliquid.xyz/evm",
  "https://hyperliquid.drpc.org",
  "https://rpc.hypurrscan.io",
  "https://rpc.purroofgroup.com",
];
const RPC_URLS = [PRIMARY, ...PUBLIC_RPCS].filter(Boolean) as string[];

export const config = createConfig({
  chains: [hyperEVM],
  connectors: [injected()],
  transports: { [hyperEVM.id]: fallback(RPC_URLS.map((u) => http(u))) },
});

declare module "wagmi" {
  interface Register {
    config: typeof config;
  }
}
