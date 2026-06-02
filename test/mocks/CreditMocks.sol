// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPyth} from "../../src/interfaces/IPyth.sol";

contract MockDecToken {
    uint8 public decimals;

    constructor(uint8 d) {
        decimals = d;
    }
}

contract MockPyth is IPyth {
    mapping(bytes32 => Price) internal _p;
    mapping(bytes32 => bool) internal _set;

    function setPrice(bytes32 id, int64 price, uint64 conf, int32 expo) external {
        _p[id] = Price({price: price, conf: conf, expo: expo, publishTime: 1});
        _set[id] = true;
    }

    function getPriceNoOlderThan(bytes32 id, uint256) external view returns (Price memory) {
        require(_set[id], "no price"); // simulates stale/missing
        return _p[id];
    }
}

contract MockKittenVoter {
    uint256 public period;
    address[] internal _pools;
    mapping(address => address) public vrOf;

    function setPeriod(uint256 p) external {
        period = p;
    }

    function setPools(address[] calldata pools) external {
        delete _pools;
        for (uint256 i; i < pools.length; ++i) {
            _pools.push(pools[i]);
        }
    }

    function setGauge(address pool, address vr) external {
        vrOf[pool] = vr;
    }

    function getCurrentPeriod() external view returns (uint256) {
        return period;
    }

    /// @dev Same pools every queried period (sufficient for trailing-MIN tests).
    function getTokenIdVotes(uint256, uint256)
        external
        view
        returns (address[] memory pools, uint256[] memory votes)
    {
        pools = _pools;
        votes = new uint256[](_pools.length);
    }

    function getGauge(address pool)
        external
        view
        returns (address, bool, address, bool, address)
    {
        return (address(0), false, vrOf[pool], true, address(0));
    }
}

contract MockKittenVotingReward {
    // earned[period][token] => amount (net-of-claim, like the real contract)
    mapping(uint256 => mapping(address => uint256)) public earned;
    mapping(uint256 => mapping(address => uint256)) public claimed;

    function setEarned(uint256 p, address token, uint256 amt) external {
        earned[p][token] = amt;
    }

    function setClaimed(uint256 p, address token, uint256 amt) external {
        claimed[p][token] = amt;
    }

    function earnedForPeriod(uint256 p, uint256, address token) external view returns (uint256) {
        return earned[p][token];
    }

    function tokenIdRewardClaimedInPeriod(uint256 p, uint256, address token) external view returns (uint256) {
        return claimed[p][token];
    }
}

contract MockNestVoter {
    uint256 public epochTimestamp;
    address[] internal _pools;
    mapping(address => address) public poolToGauge;
    mapping(address => address) public gaugeInt;
    mapping(address => address) public gaugeExt;
    mapping(uint256 => mapping(address => uint256)) public weights; // epoch=>pool=>total
    mapping(uint256 => mapping(address => uint256)) public myVotes; // tokenId=>pool=>votes

    function setEpoch(uint256 e) external {
        epochTimestamp = e;
    }

    function setPool(address pool, address gauge, address intB, address extB) external {
        _pools.push(pool);
        poolToGauge[pool] = gauge;
        gaugeInt[gauge] = intB;
        gaugeExt[gauge] = extB;
    }

    function setWeight(uint256 epoch, address pool, uint256 w) external {
        weights[epoch][pool] = w;
    }

    function setVotes(uint256 tokenId, address pool, uint256 v) external {
        myVotes[tokenId][pool] = v;
    }

    function poolVoteLength(uint256) external view returns (uint256) {
        return _pools.length;
    }

    function poolVote(uint256, uint256 i) external view returns (address) {
        return _pools[i];
    }

    function gaugesState(address gauge)
        external
        view
        returns (bool, bool, address, address, address, uint256, uint256, uint256)
    {
        return (true, true, gaugeInt[gauge], gaugeExt[gauge], address(0), 0, 0, 0);
    }

    function votes(uint256 tokenId, address pool) external view returns (uint256) {
        return myVotes[tokenId][pool];
    }

    function weightsPerEpoch(uint256 epoch, address pool) external view returns (uint256) {
        return weights[epoch][pool];
    }
}

contract MockNestBribe {
    // rewardsPerEpoch[epoch][token]
    mapping(uint256 => mapping(address => uint256)) public rpe;
    // historical vote weight: balAt[epoch][tokenId], totalAt[epoch]
    mapping(uint256 => mapping(uint256 => uint256)) public balAt;
    mapping(uint256 => uint256) public totalAt;

    function setReward(uint256 epoch, address token, uint256 amt) external {
        rpe[epoch][token] = amt;
    }

    function setVote(uint256 epoch, uint256 tokenId, uint256 bal, uint256 total) external {
        balAt[epoch][tokenId] = bal;
        totalAt[epoch] = total;
    }

    function balanceOfAt(uint256 tokenId, uint256 epoch) external view returns (uint256) {
        return balAt[epoch][tokenId];
    }

    function totalSupplyAt(uint256 epoch) external view returns (uint256) {
        return totalAt[epoch];
    }

    function rewardData(address token, uint256 epoch)
        external
        view
        returns (uint256 periodFinish, uint256 rewardsPerEpoch, uint256 lastUpdateTime)
    {
        return (0, rpe[epoch][token], 0);
    }
}
