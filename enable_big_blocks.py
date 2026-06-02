#!/usr/bin/env python3
"""Enable (or disable) HyperEVM big blocks for a deployer account held in an encrypted
foundry keystore.

The private key is decrypted in memory, used once to sign the HyperCore
evmUserModify(usingBigBlocks=...) action, and is NEVER written to disk, env, or logs.
Run this locally only.

Requires:  pip install hyperliquid-python-sdk eth-account
Usage:     python enable_big_blocks.py [--off] [path-to-keystore-file]
           default keystore: %USERPROFILE%/tw28-keys/deployer  (~/tw28-keys/deployer)
"""
import json
import os
import sys
from getpass import getpass

try:
    from eth_account import Account
    from hyperliquid.exchange import Exchange
    from hyperliquid.utils import constants
except ImportError:
    sys.exit("missing deps -> run: pip install hyperliquid-python-sdk eth-account")


def main():
    args = [a for a in sys.argv[1:]]
    enable = True
    if "--off" in args:
        enable = False
        args.remove("--off")

    default = os.path.join(os.path.expanduser("~"), "tw28-keys", "deployer")
    path = args[0] if args else default
    if not os.path.isfile(path):
        sys.exit(f"keystore not found: {path}")

    with open(path, "r") as f:
        keystore = json.load(f)

    pw = getpass("Keystore password: ")
    try:
        pk = Account.decrypt(keystore, pw)
    except Exception:
        sys.exit("wrong password / cannot decrypt keystore")
    finally:
        pw = None  # best-effort drop

    acct = Account.from_key(pk)
    pk = None  # drop raw key reference (acct retains it internally for signing)
    print(f"deployer address: {acct.address}")
    print(f"action: set usingBigBlocks = {enable}")

    if input("proceed? [y/N] ").strip().lower() != "y":
        sys.exit("aborted")

    # Pass empty meta/spot_meta so Info.__init__ skips spot-token metadata processing
    # (it IndexErrors on the current spot list). use_big_blocks needs no asset metadata.
    exchange = Exchange(
        acct,
        constants.MAINNET_API_URL,
        meta={"universe": []},
        spot_meta={"universe": [], "tokens": []},
    )
    res = exchange.use_big_blocks(enable)
    print("response:", res)
    if isinstance(res, dict) and res.get("status") == "ok":
        print(f"OK -> big blocks {'ENABLED' if enable else 'DISABLED'} for {acct.address}")
    else:
        print("WARNING: unexpected response; verify before deploying.")


if __name__ == "__main__":
    main()
