// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IWrapVe, IWrapVoter, IWrapBribe} from "../../src/ReceiptWrapper.sol";
import {MockERC20} from "./Mocks.sol";

contract MockWrapVe is IWrapVe {
    mapping(uint256 => TokenState) internal _state;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => bool) public transferable;

    function mintLock(uint256 tokenId, address owner, uint256 amount, bool permanent) external {
        _state[tokenId] = TokenState({
            locked: LockedBalance({amount: int128(uint128(amount)), end: permanent ? 0 : block.timestamp + 365 days, isPermanentLocked: permanent}),
            isVoted: false,
            isAttached: false,
            lastTranferBlock: 0,
            pointEpoch: 0
        });
        ownerOf[tokenId] = owner;
        transferable[tokenId] = true;
    }

    function setAttached(uint256 tokenId, bool a) external {
        _state[tokenId].isAttached = a;
    }

    function setTransferable(uint256 tokenId, bool t) external {
        transferable[tokenId] = t;
    }

    function getNftState(uint256 tokenId) external view returns (TokenState memory) {
        return _state[tokenId];
    }

    function isTransferable(uint256 tokenId) external view returns (bool) {
        return transferable[tokenId];
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "not owner");
        ownerOf[tokenId] = to;
    }

    function approve(address, uint256) external {}

    function merge(uint256 from, uint256 to) external {
        _state[to].locked.amount += _state[from].locked.amount;
        _state[from].locked.amount = 0;
        ownerOf[from] = address(0);
    }
}

contract MockWrapBribe is IWrapBribe {
    address public reward;

    constructor(address _reward) {
        reward = _reward;
    }

    function rewardsList() external view returns (address[] memory r) {
        r = new address[](1);
        r[0] = reward;
    }
}

contract MockWrapVoter is IWrapVoter {
    uint256 public voteCount;
    uint256 public lastVotedToken;

    address public pool;
    address public gauge;
    address public intBribe;
    address public rewardToken;
    uint256 public rewardAmount;

    function config(address _pool, address _gauge, address _intBribe, address _reward, uint256 _amt) external {
        pool = _pool;
        gauge = _gauge;
        intBribe = _intBribe;
        rewardToken = _reward;
        rewardAmount = _amt;
    }

    function vote(uint256 tokenId, address[] calldata, uint256[] calldata) external {
        ++voteCount;
        lastVotedToken = tokenId;
    }

    function poolVoteLength(uint256) external view returns (uint256) {
        return pool == address(0) ? 0 : 1;
    }

    function poolVote(uint256, uint256) external view returns (address) {
        return pool;
    }

    function poolToGauge(address) external view returns (address) {
        return gauge;
    }

    function gaugesState(address)
        external
        view
        returns (bool, bool, address, address, address, uint256, uint256, uint256)
    {
        return (true, true, intBribe, address(0), address(0), 0, 0, 0);
    }

    function claimBribes(address[] calldata, address[][] calldata, uint256) external {
        if (rewardAmount != 0) MockERC20(rewardToken).mint(msg.sender, rewardAmount);
    }
}
