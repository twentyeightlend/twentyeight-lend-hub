// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IVeAdapter} from "../../src/interfaces/IVeAdapter.sol";
import {ICreditLineManager} from "../../src/interfaces/ICreditLineManager.sol";
import {MarketParams} from "../../src/libraries/Types.sol";

contract MockERC20 {
    string public name = "Mock USDC";
    string public symbol = "mUSDC";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

/// @dev Minimal adapter: tracks custody, no real veNFT logic.
contract MockVeAdapter is IVeAdapter {
    address public immutable under;
    mapping(uint256 => address) public heldFor;
    address public reward; // when set, harvest sweeps the adapter's reward balance to `to`

    constructor(address _under) {
        under = _under;
    }

    function setReward(address r) external {
        reward = r;
    }

    bool public paused;

    function setPaused(bool p) external {
        paused = p;
    }

    function underlyingToken() external view returns (address) {
        return under;
    }

    function votingEscrow() external pure returns (address) {
        return address(0xBEEF);
    }

    function custody(uint256 tokenId, address from) external {
        heldFor[tokenId] = from;
    }

    function recoverUnderlying(uint256 tokenId, address) external {
        heldFor[tokenId] = address(0);
    }

    bool public permanent;
    uint256 public lockEndVal = type(uint256).max;

    function setPermanent(bool p) external {
        permanent = p;
    }

    function setLockEnd(uint256 e) external {
        lockEndVal = e;
    }

    function isPermanentLock(uint256) external view returns (bool) {
        return permanent;
    }

    function lockEnd(uint256) external view returns (uint256) {
        return lockEndVal;
    }

    function lockedAmount(uint256) external pure returns (uint256) {
        return 1_000e18;
    }

    function currentVotingPower(uint256) external pure returns (uint256) {
        return 1_000e18;
    }

    function isAcceptableCollateral(uint256) external pure returns (bool, string memory) {
        return (true, "");
    }

    function harvestableYield(uint256)
        external
        pure
        returns (address[] memory t, uint256[] memory a)
    {
        t = new address[](0);
        a = new uint256[](0);
    }

    function harvest(uint256, address to)
        external
        returns (address[] memory t, uint256[] memory a)
    {
        if (reward == address(0)) {
            return (new address[](0), new uint256[](0));
        }
        uint256 bal = MockERC20(reward).balanceOf(address(this));
        t = new address[](1);
        a = new uint256[](1);
        t[0] = reward;
        a[0] = bal;
        if (bal != 0) MockERC20(reward).transfer(to, bal);
    }

    uint256 public voteCount;
    bytes public lastVoteData;

    function vote(uint256, bytes calldata data) external {
        ++voteCount;
        lastVoteData = data;
    }
}

/// @dev Swaps tokenIn->tokenOut at a fixed rate (rateBps/10000 of amountIn, decimals aside).
///      Must be pre-funded with tokenOut. Used to test SelfRepayEngine.
contract MockSwapRouter {
    uint256 public rateNum; // out = in * rateNum / rateDen
    uint256 public rateDen;
    bool public enforceMinOut; // false simulates a sandwiching AMM that ignores minOut

    constructor(uint256 _num, uint256 _den, bool _enforce) {
        rateNum = _num;
        rateDen = _den;
        enforceMinOut = _enforce;
    }

    function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 minOut, bytes calldata)
        external
        returns (uint256 out)
    {
        MockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        out = (amountIn * rateNum) / rateDen;
        if (enforceMinOut) require(out >= minOut, "router minOut");
        MockERC20(tokenOut).transfer(msg.sender, out);
    }
}

contract MockCreditManager is ICreditLineManager {
    uint256 public line;

    constructor(uint256 _line) {
        line = _line;
    }

    function set(uint256 _line) external {
        line = _line;
    }

    function creditLine(MarketParams calldata, uint256) external view returns (uint256) {
        return line;
    }
}
