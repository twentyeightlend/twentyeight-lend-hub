// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

contract MockAlgebraPlugin {
    int56 public cumPast; // oldest (twapWindow ago)
    int56 public cumShort; // shortWindow ago
    int56 public cumNow; // now
    bool public initialized = true;

    function setCumulatives(int56 past, int56 short_, int56 now_) external {
        cumPast = past;
        cumShort = short_;
        cumNow = now_;
    }

    function setInitialized(bool v) external {
        initialized = v;
    }

    function isInitialized() external view returns (bool) {
        return initialized;
    }

    function getTimepoints(uint32[] calldata)
        external
        view
        returns (int56[] memory tc, uint88[] memory vc)
    {
        tc = new int56[](3);
        tc[0] = cumPast;
        tc[1] = cumShort;
        tc[2] = cumNow;
        vc = new uint88[](3);
    }
}

contract MockVeTwap {
    uint256 public p;

    function setPrice(uint256 _p) external {
        p = _p;
    }

    function priceUsd1e18() external view returns (uint256) {
        return p;
    }
}

contract MockOracle {
    uint256 public p;
    bool public reverts;

    function setPrice(uint256 _p) external {
        p = _p;
    }

    function setReverts(bool v) external {
        reverts = v;
    }

    function price() external view returns (uint256) {
        require(!reverts, "oracle down");
        return p;
    }
}

contract MintableERC20 {
    string public name = "Mock";
    string public symbol = "MCK";
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint8 d) {
        decimals = d;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
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

contract MockAlgebraPool {
    address public plugin;
    address public token0;
    address public token1;
    int24 internal spotTick;

    constructor(address _plugin, address _token0, address _token1) {
        plugin = _plugin;
        token0 = _token0;
        token1 = _token1;
    }

    function setSpotTick(int24 t) external {
        spotTick = t;
    }

    function globalState() external view returns (uint160, int24, uint16, uint8, uint16, bool) {
        return (0, spotTick, 0, 0, 0, true);
    }
}
