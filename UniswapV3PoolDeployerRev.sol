// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6; // Exact avoids compiler issues

import './interfaces/IUniswapV3PoolDeployer.sol'; // PoolDeployer interfaces specifies all internal functions the contract can interact with.

import './UniswapV3Pool.sol';

contract UniswapV3PoolDeployer is IUniswapV3PoolDeployer { // Also doesn't inherit UniswapV3Pool?
    struct Parameters { // Struct includes the factory address as well as important information for pool, including: token addresses, fee amount, and tickspacing.
        address factory;
        address token0;
        address token1;
        uint24 fee;
        int24 tickSpacing;
    }

    /// @inheritdoc IUniswapV3PoolDeployer
    Parameters public override parameters; // Overrides parameters function from interface and creates new variable for Parameters struct.

    /// @dev Deploys a pool with the given parameters by transiently setting the parameters storage slot and then
    /// clearing it after deploying the pool.
    /// @param factory The contract address of the Uniswap V3 factory
    /// @param token0 The first token of the pool by address sort order
    /// @param token1 The second token of the pool by address sort order
    /// @param fee The fee collected upon every swap in the pool, denominated in hundredths of a bip
    /// @param tickSpacing The spacing between usable ticks
    function deploy(
        address factory,
        address token0,
        address token1,
        uint24 fee,
        int24 tickSpacing
    ) internal returns (address pool) { // Create a pool using same parameters from strcut and returns the new address.
        parameters = Parameters({factory: factory, token0: token0, token1: token1, fee: fee, tickSpacing: tickSpacing}); // Temporarily assigns pool inputs to parameters.
        pool = address(new UniswapV3Pool{salt: keccak256(abi.encode(token0, token1, fee))}()); // Unique line of code used to generate new pool address while saving gas. UniswapV3Pool serves as the template, the salt keyword specifies a new contract to be created,
                                                                                               // the hash serves as input for the address being created, and notice no parameters are actually passed into the new contract. The parameters are external and temporary
                                                                                               // which makes the address generation less computationally intensive and therefore cheaper.
        delete parameters; // Deleting parameters helps save gas.
    }
}