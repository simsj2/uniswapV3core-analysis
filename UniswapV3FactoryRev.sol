// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6; // Exact pragma used to avoid issues with compiler

import './interfaces/IUniswapV3Factory.sol'; // Imports interface specifying all the functions this contract can interact with.

import './UniswapV3PoolDeployer.sol'; // Imports other core contracts.
import './NoDelegateCall.sol';

import './UniswapV3Pool.sol';

/// @title Canonical Uniswap V3 factory
/// @notice Deploys Uniswap V3 pools and manages ownership and control over pool protocol fees
contract UniswapV3Factory is IUniswapV3Factory, UniswapV3PoolDeployer, NoDelegateCall { // Doesn't appear to inherit UniswapV3pool? Could possibly eliminate?
    /// @inheritdoc IUniswapV3Factory
    address public override owner; // Uses override since other contracts use the address owner

    /// @inheritdoc IUniswapV3Factory
    mapping(uint24 => int24) public override feeAmountTickSpacing; // Uses 24 since fee amounts are denominated in hundreths of a bip. 1 bip = .0001, so fee amount is approx = .000001 or 1e-6. Each deimal place is equal to 4 integers, so 4 integers times six decimal places is 24.
    /// @inheritdoc IUniswapV3Factory
    mapping(address => mapping(address => mapping(uint24 => address))) public override getPool; // Mapping containing all information for a pool. Uses override since getPool is a function used in the IUniswapV3Factory contract.

    constructor() {
        owner = msg.sender;
        emit OwnerChanged(address(0), msg.sender); // Shows that msg.sender created the factory.

        feeAmountTickSpacing[500] = 10; // Updates mapping which associates each fee tier with a tick spacing.
        emit FeeAmountEnabled(500, 10); // Emits event showing update.
        feeAmountTickSpacing[3000] = 60;
        emit FeeAmountEnabled(3000, 60);
        feeAmountTickSpacing[10000] = 200;
        emit FeeAmountEnabled(10000, 200);
    }

    /// @inheritdoc IUniswapV3Factory
    function createPool(
        address tokenA, // Function creates a pool with two tokens and a fee amount. All of these entered on front end.
        address tokenB,
        uint24 fee
    ) external override noDelegateCall returns (address pool) { // noDelegateCall modifier used to prevent DelegateCall from being used which helps prevent against some smart contract hacks.
        require(tokenA != tokenB);
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA); // Passes tokenA and tokenB as token0 and token1 depending on the address.
        require(token0 != address(0));
        int24 tickSpacing = feeAmountTickSpacing[fee]; // Sets tickspacing by using fee amount with feeAmountTickSpacing mapping.
        require(tickSpacing != 0);
        require(getPool[token0][token1][fee] == address(0)); // Makes sure pool doesn't already exist.
        pool = deploy(address(this), token0, token1, fee, tickSpacing); // Calls deploy function in UniswapV3PoolDeployer which deploys the pool and then assigns the address to the variable "pool".
        getPool[token0][token1][fee] = pool;
        /// populate mapping in the reverse direction, deliberate choice to avoid the cost of comparing addresses.
        getPool[token1][token0][fee] = pool; // Updates getPool mapping which now stores tokens, fee amount, and pool address.
        emit PoolCreated(token0, token1, fee, tickSpacing, pool);
    }

    /// @inheritdoc IUniswapV3Factory
    function setOwner(address _owner) external override { // Checks if msg.sender is the owner, then allows them to set a new owner if they are.
        require(msg.sender == owner);
        emit OwnerChanged(owner, _owner);
        owner = _owner;
    }

    /// @inheritdoc IUniswapV3Factory
    function enableFeeAmount(uint24 fee, int24 tickSpacing) public override { // Allows owner to set a new fee amount/tickspacing pair.
        require(msg.sender == owner);
        require(fee < 1000000); // Fee amount laughably has to be less than 100%.
        // tick spacing is capped at 16384 to prevent the situation where tickSpacing is so large that
        // TickBitmap#nextInitializedTickWithinOneWord overflows int24 container from a valid tick
        // 16384 ticks represents a >5x price change with ticks of 1 bips
        require(tickSpacing > 0 && tickSpacing < 16384);
        require(feeAmountTickSpacing[fee] == 0); // Pair can't have been created already.

        feeAmountTickSpacing[fee] = tickSpacing; // Sets pair and emits it.
        emit FeeAmountEnabled(fee, tickSpacing);
    }
}