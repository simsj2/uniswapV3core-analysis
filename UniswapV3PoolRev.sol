// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6; // Exact pragma avoids issue with compiler.

import './interfaces/IUniswapV3Pool.sol';  // Interface defined which contains many smaller pieces for this contract to interact with.

import './NoDelegateCall.sol'; // NoDelegateCall prevents against certain smart contract hacks.

import './libraries/LowGasSafeMath.sol';  // Allows contract to perform artihmetic without worrying about over/underflows as well as reduces gas.
import './libraries/SafeCast.sol'; // Allows contract to safely cast between types.
import './libraries/Tick.sol'; // Contains functions and calculations for ticks.
import './libraries/TickBitmap.sol'; // Stores a mapping of where all the ticks are.
import './libraries/Position.sol'; // Represents how much liquidity a person has between their upper and lower tick limits.
import './libraries/Oracle.sol'; // Provides price data for tokens in pool.

import './libraries/FullMath.sol'; // Math that allows for overflow without loss of preceision. Useful when dealingn with large numbers in Solidity.
import './libraries/FixedPoint128.sol'; // Handles 128-bit binary fixed point numbers.
import './libraries/TransferHelper.sol'; // Transfer function for ERC-20s that return TF if a transaction fails instead of false. 
import './libraries/TickMath.sol'; // Calculates which tick a price is associated with and vice versa.
import './libraries/LiquidityMath.sol'; // Changes liquidity in pool depending on if user increases or removes it.
import './libraries/SqrtPriceMath.sol'; // Contains math functions for price and liquidity. Square root math and storing them as a Q64.96 are important because solidity isn't great at calculating them with precision.
import './libraries/SwapMath.sol';  // Calculates the amount in, amount out, fee, etc. for a swap.

import './interfaces/IUniswapV3PoolDeployer.sol';
import './interfaces/IUniswapV3Factory.sol';
import './interfaces/IERC20Minimal.sol'; // Reduced down ERC20 interface.
import './interfaces/callback/IUniswapV3MintCallback.sol'; // 
import './interfaces/callback/IUniswapV3SwapCallback.sol';
import './interfaces/callback/IUniswapV3FlashCallback.sol';

contract UniswapV3Pool is IUniswapV3Pool, NoDelegateCall { // Inherits this contract's interface and NoDelegateCall.
    using LowGasSafeMath for uint256; // Using X for Y inherits all functions for X to be used with type Y.
    using LowGasSafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using Tick for mapping(int24 => Tick.Info); // Tick.Info references the Info struct in Tick.sol which has all of the information associated with each tick.
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info); //Position.Info references the Info struct in Position.sol which has all of the information associated with the user's position.
    using Position for Position.Info;
    using Oracle for Oracle.Observation[65535]; // 65535 is the number of observations that can be stored. These observations help Uniswap natively calculate the price of a token.

    /// @inheritdoc IUniswapV3PoolImmutables
    address public immutable override factory; // Defines and overrides some of the basic variables seen so far and makes them immutable.
    /// @inheritdoc IUniswapV3PoolImmutables
    address public immutable override token0;
    /// @inheritdoc IUniswapV3PoolImmutables
    address public immutable override token1;
    /// @inheritdoc IUniswapV3PoolImmutables
    uint24 public immutable override fee;

    /// @inheritdoc IUniswapV3PoolImmutables
    int24 public immutable override tickSpacing;

    /// @inheritdoc IUniswapV3PoolImmutables
    uint128 public immutable override maxLiquidityPerTick;

    struct Slot0 { // Gas optimizing struct which allows a user to increase the cardinality of observations (number of observations used for price oracle) if willing to pay for it.
        // the current price
        uint160 sqrtPriceX96;
        // the current tick
        int24 tick;
        // the most-recently updated index of the observations array
        uint16 observationIndex;
        // the current maximum number of observations that are being stored
        uint16 observationCardinality;
        // the next maximum number of observations to store, triggered in observations.write
        uint16 observationCardinalityNext;
        // the current protocol fee as a percentage of the swap fee taken on withdrawal
        // represented as an integer denominator (1/x)%
        uint8 feeProtocol;
        // whether the pool is locked
        bool unlocked;
    }
    /// @inheritdoc IUniswapV3PoolState
    Slot0 public override slot0; // Overrides the struct defined in the interface.

    /// @inheritdoc IUniswapV3PoolState
    uint256 public override feeGrowthGlobal0X128;
    /// @inheritdoc IUniswapV3PoolState
    uint256 public override feeGrowthGlobal1X128;

    // Accumulated protocol fees in token0/token1 units
    struct ProtocolFees {
        uint128 token0;
        uint128 token1;
    }
    /// @inheritdoc IUniswapV3PoolState
    ProtocolFees public override protocolFees;

    /// @inheritdoc IUniswapV3PoolState
    uint128 public override liquidity;

    /// @inheritdoc IUniswapV3PoolState
    mapping(int24 => Tick.Info) public override ticks; // Overrides the mappings from above with new names.
    /// @inheritdoc IUniswapV3PoolState
    mapping(int16 => uint256) public override tickBitmap;
    /// @inheritdoc IUniswapV3PoolState
    mapping(bytes32 => Position.Info) public override positions;
    /// @inheritdoc IUniswapV3PoolState
    Oracle.Observation[65535] public override observations;

    /// @dev Mutually exclusive reentrancy protection into the pool to/from a method. This method also prevents entrance
    /// to a function before the pool is initialized. The reentrancy guard is required throughout the contract because
    /// we use balance checks to determine the payment status of interactions such as mint, swap and flash.
    modifier lock() { // Modifier helps protect against hacks by locking the pool.
        require(slot0.unlocked, 'LOK');
        slot0.unlocked = false; // Setting value to false before function is run ensures function can't be called again since the require statement would fail.
        _;
        slot0.unlocked = true;
    }

    /// @dev Prevents calling a function from anyone except the address returned by IUniswapV3Factory#owner()
    modifier onlyFactoryOwner() { // Modifier that only lets the owner call a function.
        require(msg.sender == IUniswapV3Factory(factory).owner());
        _;
    }

    constructor() { // And 100 lines in, the constructor haha...
        int24 _tickSpacing; // Defines variable since only tickSpacing was declared earlier.
        (factory, token0, token1, fee, _tickSpacing) = IUniswapV3PoolDeployer(msg.sender).parameters(); // Loads the given parameters from the pool deployer interface. Msg.sender is the PoolDeployer contract.
        tickSpacing = _tickSpacing;

        maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(_tickSpacing); // Establishes the max liquidity per tick based off of tick spacing and liquidity provided.
    }

    /// @dev Common checks for valid tick inputs.
    function checkTicks(int24 tickLower, int24 tickUpper) private pure {
        require(tickLower < tickUpper, 'TLU');
        require(tickLower >= TickMath.MIN_TICK, 'TLM');
        require(tickUpper <= TickMath.MAX_TICK, 'TUM');
    }

    /// @dev Returns the block timestamp truncated to 32 bits, i.e. mod 2**32. This method is overridden in tests.
    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp); // truncation is desired
    }

    /// @dev Get the pool's balance of token0
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
    /// check
    function balance0() private view returns (uint256) {
        (bool success, bytes memory data) = // If call succeeds, the success bool is set to true and vice versa. All other data returned from the call stored in dynamically sized bytes array called data.
            token0.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this))); // Staticcall enforces a read-only call which helps avoid reentrancy vulnerabilities. The information enclosed within abi.encodeWithSelector gets converted to something readable by the EVM. This is an example of how to make a call to an external function in a single line of Solidity
        require(success && data.length >= 32); // Makes sure the right thing is returned.
        return abi.decode(data, (uint256)); // Abi.decode converts the data to something human-readable.
    }

    /// @dev Get the pool's balance of token1
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
    /// check
    function balance1() private view returns (uint256) { // Same as above, but for token 1.
        (bool success, bytes memory data) =
            token1.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    /// @inheritdoc IUniswapV3PoolDerivedState
    function snapshotCumulativesInside(int24 tickLower, int24 tickUpper) // Provides a "snapshot" of the returned information with the upper and lower ticks as parameters.
        external
        view
        override
        noDelegateCall
        returns (
            int56 tickCumulativeInside,
            uint160 secondsPerLiquidityInsideX128,
            uint32 secondsInside
        )
    {
        checkTicks(tickLower, tickUpper); // Calls checkTicks function to make sure the parameters are valid.

        int56 tickCumulativeLower; // Defines some local variables.
        int56 tickCumulativeUpper;
        uint160 secondsPerLiquidityOutsideLowerX128;
        uint160 secondsPerLiquidityOutsideUpperX128;
        uint32 secondsOutsideLower;
        uint32 secondsOutsideUpper;

        {
            Tick.Info storage lower = ticks[tickLower]; // Updates ticks mapping to associate the lower tick with the information in the Tick.Info struct.
            Tick.Info storage upper = ticks[tickUpper]; // Same as above except for the upper tick.
            bool initializedLower; 
            (tickCumulativeLower, secondsPerLiquidityOutsideLowerX128, secondsOutsideLower, initializedLower) = ( // Updates the new variables with information from the lower struct. 
                lower.tickCumulativeOutside,
                lower.secondsPerLiquidityOutsideX128,
                lower.secondsOutside,
                lower.initialized
            );
            require(initializedLower); // Bool variables default to false.

            bool initializedUpper;
            (tickCumulativeUpper, secondsPerLiquidityOutsideUpperX128, secondsOutsideUpper, initializedUpper) = ( // Updates the new variables with information from the lower struct.
                upper.tickCumulativeOutside,
                upper.secondsPerLiquidityOutsideX128,
                upper.secondsOutside,
                upper.initialized
            );
            require(initializedUpper);
        }

        Slot0 memory _slot0 = slot0; // Loads Slot0 into memory and creates a local variable to represent it named _slot0.

        if (_slot0.tick < tickLower) { // If the current tick is outside of the lower bound.
            return (
                tickCumulativeLower - tickCumulativeUpper,
                secondsPerLiquidityOutsideLowerX128 - secondsPerLiquidityOutsideUpperX128,
                secondsOutsideLower - secondsOutsideUpper
            );
        } else if (_slot0.tick < tickUpper) { // If the current tick is between the upper and lower bounds.
            uint32 time = _blockTimestamp();
            (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) =
                observations.observeSingle( // Observation taken 0 seconds ago from blockTimestamp.
                    time,
                    0,
                    _slot0.tick,
                    _slot0.observationIndex,
                    liquidity,
                    _slot0.observationCardinality
                );
            return (
                tickCumulative - tickCumulativeLower - tickCumulativeUpper,
                secondsPerLiquidityCumulativeX128 -
                    secondsPerLiquidityOutsideLowerX128 -
                    secondsPerLiquidityOutsideUpperX128,
                time - secondsOutsideLower - secondsOutsideUpper
            );
        } else { // If the current tick is outside of the upper bound.
            return (
                tickCumulativeUpper - tickCumulativeLower,
                secondsPerLiquidityOutsideUpperX128 - secondsPerLiquidityOutsideLowerX128,
                secondsOutsideUpper - secondsOutsideLower
            );
        }
    }

    /// @inheritdoc IUniswapV3PoolDerivedState
    function observe(uint32[] calldata secondsAgos) // Similar to previous observation except this one can be taken at variable number of seconds ago.
        external
        view
        override
        noDelegateCall
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        return
            observations.observe(
                _blockTimestamp(),
                secondsAgos, // This is what differs from observeSingle().
                slot0.tick,
                slot0.observationIndex,
                liquidity,
                slot0.observationCardinality
            );
    }

    /// @inheritdoc IUniswapV3PoolActions
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) // Increases the number of price and liquidity observations for 
        external
        override
        lock
        noDelegateCall
    {
        uint16 observationCardinalityNextOld = slot0.observationCardinalityNext; // Uses observationCardinalityNext from the current slot0 as the old observationCardinalityNext.
        uint16 observationCardinalityNextNew =
            observations.grow(observationCardinalityNextOld, observationCardinalityNext); // The provided parameter is used as the new observationCardinalityNext.
        slot0.observationCardinalityNext = observationCardinalityNextNew; // Updates slot0.
        if (observationCardinalityNextOld != observationCardinalityNextNew)
            emit IncreaseObservationCardinalityNext(observationCardinalityNextOld, observationCardinalityNextNew); // Emits change.
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @dev not locked because it initializes unlocked
    function initialize(uint160 sqrtPriceX96) external override { // Sets the initial price of the pool where the price is sqrt(amountToken1/amountToken0) as a Q64.96
        require(slot0.sqrtPriceX96 == 0, 'AI'); // Default value of uints and ints is 0. Checks if pool has already been initialized.

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96); // Finds the tick associated with the sqrt price.

        (uint16 cardinality, uint16 cardinalityNext) = observations.initialize(_blockTimestamp()); // Sets the time of the initialization and cardinality and cardinalityNext to 1.

        slot0 = Slot0({ // Updates slot0 with the initial data and unlocks the pool.
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            observationIndex: 0,
            observationCardinality: cardinality,
            observationCardinalityNext: cardinalityNext,
            feeProtocol: 0,
            unlocked: true
        });

        emit Initialize(sqrtPriceX96, tick); // Emits initial sqrt price and its associated tick.
    }

    struct ModifyPositionParams { // Struct that tracts the following pool modifications.
        // the address that owns the position
        address owner;
        // the lower and upper tick of the position
        int24 tickLower;
        int24 tickUpper;
        // any change in liquidity
        int128 liquidityDelta;
    }

    /// @dev Effect some changes to a position
    /// @param params the position details and the change to the position's liquidity to effect
    /// @return position a storage pointer referencing the position with the given owner and tick range
    /// @return amount0 the amount of token0 owed to the pool, negative if the pool should pay the recipient
    /// @return amount1 the amount of token1 owed to the pool, negative if the pool should pay the recipient
    function _modifyPosition(ModifyPositionParams memory params)
        private // Can only be called by functions within this contract.
        noDelegateCall
        returns (
            Position.Info storage position,
            int256 amount0,
            int256 amount1
        )
    {
        checkTicks(params.tickLower, params.tickUpper); // Checks validity of ticks from params.

        Slot0 memory _slot0 = slot0; // SLOAD for gas optimization

        position = _updatePosition( // Takes the ModifyPositio0nParams and calls _updatePosition with them.
            params.owner,
            params.tickLower,
            params.tickUpper,
            params.liquidityDelta,
            _slot0.tick // Uses the slot0 tick from memory.
        );

        if (params.liquidityDelta != 0) { // This block of code is only executed if there's actually been a change to the position liquidity.
            if (_slot0.tick < params.tickLower) {
                // current tick is below the passed range; liquidity can only become in range by crossing from left to
                // right, when we'll need _more_ token0 (it's becoming more valuable) so user must provide it
                amount0 = SqrtPriceMath.getAmount0Delta( // Returns the amount of token0 required to cover params.liquidityDelta.
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            } else if (_slot0.tick < params.tickUpper) {
                // current tick is inside the passed range
                uint128 liquidityBefore = liquidity; // SLOAD for gas optimization

                // write an oracle entry
                (slot0.observationIndex, slot0.observationCardinality) = observations.write( // Adds an observation to the observations array and returns an updated index and cardinality.
                    _slot0.observationIndex, 
                    _blockTimestamp(),
                    _slot0.tick,
                    liquidityBefore,
                    _slot0.observationCardinality,
                    _slot0.observationCardinalityNext
                );

                amount0 = SqrtPriceMath.getAmount0Delta( // Calculates the amount of token0 for the given liquidity between prices.
                    _slot0.sqrtPriceX96,
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
                amount1 = SqrtPriceMath.getAmount1Delta( // Calculates the amount of token1 for the given liquidity between prices.
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    _slot0.sqrtPriceX96,
                    params.liquidityDelta
                );

                liquidity = LiquidityMath.addDelta(liquidityBefore, params.liquidityDelta); // Calculates the amount of liquidity being provided.
            } else {
                // current tick is above the passed range; liquidity can only become in range by crossing from right to
                // left, when we'll need _more_ token1 (it's becoming more valuable) so user must provide it
                amount1 = SqrtPriceMath.getAmount1Delta( // When outside of the range to the right, only token1 can be supplied.
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            }
        }
    }

    /// @dev Gets and updates a position with the given liquidity delta
    /// @param owner the owner of the position
    /// @param tickLower the lower tick of the position's tick range
    /// @param tickUpper the upper tick of the position's tick range
    /// @param tick the current tick, passed to avoid sloads
    function _updatePosition( // Called from the _modifyPosition function and updates the user's position to reflect the changes.
        address owner,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta,
        int24 tick
    ) private returns (Position.Info storage position) {
        position = positions.get(owner, tickLower, tickUpper); // Gets information associated with the current position.

        uint256 _feeGrowthGlobal0X128 = feeGrowthGlobal0X128; // SLOAD for gas optimization
        uint256 _feeGrowthGlobal1X128 = feeGrowthGlobal1X128; // SLOAD for gas optimization

        // if we need to update the ticks, do it
        bool flippedLower; // Flipped refers to whether the tick has changed from initialized to uninitialized or vice versa.
        bool flippedUpper;
        if (liquidityDelta != 0) { // If liquidity's been provided:
            uint32 time = _blockTimestamp();
            (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) = 
                observations.observeSingle( // Takes a snapshot at the current timestamp.
                    time,
                    0,
                    slot0.tick,
                    slot0.observationIndex,
                    liquidity,
                    slot0.observationCardinality
                );

            flippedLower = ticks.update( // Returns a bool.
                tickLower,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                false, // False for lower.
                maxLiquidityPerTick
            );
            flippedUpper = ticks.update(
                tickUpper,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                true, // True for upper.
                maxLiquidityPerTick
            );

            if (flippedLower) { // If the tick's been flipped, update its state.
                tickBitmap.flipTick(tickLower, tickSpacing);
            }
            if (flippedUpper) {
                tickBitmap.flipTick(tickUpper, tickSpacing);
            }
        }

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = // Gets the amount of fees accrued to each token.
            ticks.getFeeGrowthInside(tickLower, tickUpper, tick, _feeGrowthGlobal0X128, _feeGrowthGlobal1X128);

        position.update(liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128); // Updates the position with the amount of fees and liquidity.

        // clear any tick data that is no longer needed
        if (liquidityDelta < 0) {
            if (flippedLower) {
                ticks.clear(tickLower);
            }
            if (flippedUpper) {
                ticks.clear(tickUpper);
            }
        }
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @dev noDelegateCall is applied indirectly via _modifyPosition
    function mint( // Adds liquidity to position.
        address recipient, // Paramaters are user address, upper and lower ticks, and the amount of liquidity being supplied.
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external override lock returns (uint256 amount0, uint256 amount1) { // Overrides mint function from IUniswapV3PoolActions, check to make sure the pool's been initialized, then returns the calculated amount of each token for the pool.
        require(amount > 0);
        (, int256 amount0Int, int256 amount1Int) = // Returns nothing for Position.Info
            _modifyPosition(
                ModifyPositionParams({ // Uses the mint parameters for calling the _modifyPosition function.
                    owner: recipient, // Should be msg.sender.
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: int256(amount).toInt128() // uint128 is changed to an int256 and then SafeCast back down to an int128.
                })
            );

        amount0 = uint256(amount0Int); // Changes from signed to unsigned integers.
        amount1 = uint256(amount1Int);

        uint256 balance0Before; // Initializes variables.
        uint256 balance1Before;
        if (amount0 > 0) balance0Before = balance0(); // If liquidity is supplied, set the balance of token0 to balance0Before.
        if (amount1 > 0) balance1Before = balance1();
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data); // Makes user pay calculated token amounts.
        if (amount0 > 0) require(balance0Before.add(amount0) <= balance0(), 'M0'); // If liquidity supplied, make sure the amount of token0 is less than the current balance. Would only be greater than if balance was negative.
        if (amount1 > 0) require(balance1Before.add(amount1) <= balance1(), 'M1');

        emit Mint(msg.sender, recipient, tickLower, tickUpper, amount, amount0, amount1); // Emits mint event.
    }

    /// @inheritdoc IUniswapV3PoolActions
    function collect( // Function called if liquidity's being removed.
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested, // Token amounts are requested separately.
        uint128 amount1Requested
    ) external override lock returns (uint128 amount0, uint128 amount1) { // Same as mint function.
        // we don't need to checkTicks here, because invalid positions will never have non-zero tokensOwed{0,1}
        Position.Info storage position = positions.get(msg.sender, tickLower, tickUpper); // Retrieves position information from the struct.

        amount0 = amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : amount0Requested; // More concise if-else statement. If requesting tokens, will return some or all of the fee amount accrued for the token.
        amount1 = amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : amount1Requested;  

        if (amount0 > 0) { // If token0 fees being collected, updates the position struct to reflect amount withdrawn.
            position.tokensOwed0 -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0); // safeTransfers amount to recipient.
        }
        if (amount1 > 0) { // Same for token1.
            position.tokensOwed1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        emit Collect(msg.sender, recipient, tickLower, tickUpper, amount0, amount1); // Emits collect event.
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @dev noDelegateCall is applied indirectly via _modifyPosition
    function burn( // Top half of burn function essentially the exact opposite of the mint function.
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        (Position.Info storage position, int256 amount0Int, int256 amount1Int) =
            _modifyPosition(
                ModifyPositionParams({
                    owner: msg.sender,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: -int256(amount).toInt128() // Main difference is the liquidity delta is negative.
                })
            );

        amount0 = uint256(-amount0Int); // Converts amounts back to uint256 and flips the sign.
        amount1 = uint256(-amount1Int);

        if (amount0 > 0 || amount1 > 0) { // If there's any amount of tokens left, the remaining amount is added to your tokensOwed position.
            (position.tokensOwed0, position.tokensOwed1) = (
                position.tokensOwed0 + uint128(amount0),
                position.tokensOwed1 + uint128(amount1)
            );
        }

        emit Burn(msg.sender, tickLower, tickUpper, amount, amount0, amount1); // Emits burn event.
    }

    struct SwapCache { // Struct for information cached before the swap.
        // the protocol fee for the input token
        uint8 feeProtocol;
        // liquidity at the beginning of the swap
        uint128 liquidityStart;
        // the timestamp of the current block
        uint32 blockTimestamp;
        // the current value of the tick accumulator, computed only if we cross an initialized tick
        int56 tickCumulative;
        // the current value of seconds per liquidity accumulator, computed only if we cross an initialized tick
        uint160 secondsPerLiquidityCumulativeX128;
        // whether we've computed and cached the above two accumulators
        bool computedLatestObservation;
    }

    // the top level state of the swap, the results of which are recorded in storage at the end
    struct SwapState { // Basically stores the swap "position" information.
        // the amount remaining to be swapped in/out of the input/output asset
        int256 amountSpecifiedRemaining;
        // the amount already swapped out/in of the output/input asset
        int256 amountCalculated;
        // current sqrt(price)
        uint160 sqrtPriceX96;
        // the tick associated with the current price
        int24 tick;
        // the global fee growth of the input token
        uint256 feeGrowthGlobalX128;
        // amount of input token paid as protocol fee
        uint128 protocolFee;
        // the current liquidity in range
        uint128 liquidity;
    }

    struct StepComputations {
        // the price at the beginning of the step
        uint160 sqrtPriceStartX96;
        // the next tick to swap to from the current tick in the swap direction
        int24 tickNext;
        // whether tickNext is initialized or not
        bool initialized;
        // sqrt(price) for the next tick (1/0)
        uint160 sqrtPriceNextX96;
        // how much is being swapped in in this step
        uint256 amountIn;
        // how much is being swapped out
        uint256 amountOut;
        // how much fee is being paid in
        uint256 feeAmount;
    }

    /// @inheritdoc IUniswapV3PoolActions
    function swap(
        address recipient,
        bool zeroForOne, // True if swapping token0 for token1.
        int256 amountSpecified, // Amount being swapped. The amount being negative is for exact outputs and vice versa for inputs.
        uint160 sqrtPriceLimitX96, // Price limit. Can't be less than the limit if swapping zero for one and vice versa for swapping one for zero.
        bytes calldata data
    ) external override noDelegateCall returns (int256 amount0, int256 amount1) { // Same as the previous functions.
        require(amountSpecified != 0, 'AS'); // Swap amount must be non-zero.

        Slot0 memory slot0Start = slot0; // Loads Slot0 into memory under the name slot0Start.

        require(slot0Start.unlocked, 'LOK'); // Make sure the pools unlocked.
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO // If swapping zero for one, make sure the price is greater than the limit and the limit is greater than the min ratio. 
                : sqrtPriceLimitX96 > slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO, // If swapping one for zero, make sure the price is less than the limit and the limit is less than the max ratio.
            'SPL'
        );

        slot0.unlocked = false; // Locks the pool.

        SwapCache memory cache = // Loads the struct into memory.
            SwapCache({ // Loads information into the SwapCache struct.
                liquidityStart: liquidity,
                blockTimestamp: _blockTimestamp(),
                feeProtocol: zeroForOne ? (slot0Start.feeProtocol % 16) : (slot0Start.feeProtocol >> 4), // The protocol fee taken for each swap depending on which token is being swapped for which. If zero for one, it looks like the fee is modulo 16, and if not, is equivalent to the fee divided by 16?
                secondsPerLiquidityCumulativeX128: 0,
                tickCumulative: 0,
                computedLatestObservation: false
            });

        bool exactInput = amountSpecified > 0; // amoundSpecified integer is positive for exact inputs.

        SwapState memory state =
            SwapState({ // Loads information into the SwapState.
                amountSpecifiedRemaining: amountSpecified,
                amountCalculated: 0, // Zero since no amount has been swapped yet.
                sqrtPriceX96: slot0Start.sqrtPriceX96,
                tick: slot0Start.tick,
                feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128, // Fees accumulated for input token.
                protocolFee: 0, // Also zero since the swap hasn't occurred yet.
                liquidity: cache.liquidityStart // Retrieve liquidity info from the cache.
            });

        // continue swapping as long as we haven't used the entire input/output and haven't reached the price limit
        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
            StepComputations memory step; // Local variable step to represent the step struct.

            step.sqrtPriceStartX96 = state.sqrtPriceX96; // Load sqrtPrice into step struct for computation.

            (step.tickNext, step.initialized) = tickBitmap.nextInitializedTickWithinOneWord( // Loads the next tick to swap to/from and checks if that tick has been initialized.
                state.tick, // Gets tick from state associated with current price.
                tickSpacing,
                zeroForOne
            );

            // ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds
            if (step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK; // If overshot, set the next tick as the min tick.
            } else if (step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK; // If overshot, set the next tick as the max tick.
            }

            // get the price for the next tick
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

            // compute values to swap to the target tick, price limit, or point where input/output amount is exhausted
            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep( // The heart of the swap function. Parameters loaded from state for the calculations.
                state.sqrtPriceX96,
                (zeroForOne ? step.sqrtPriceNextX96 < sqrtPriceLimitX96 : step.sqrtPriceNextX96 > sqrtPriceLimitX96) // Second parameter is the price that can't be exceeded.
                    ? sqrtPriceLimitX96
                    : step.sqrtPriceNextX96, 
                state.liquidity,
                state.amountSpecifiedRemaining, // Amount remaining to be swapped.
                fee // Fee taken from input amount.
            );

            if (exactInput) {
                state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount).toInt256(); // After paying the amountIn and fee, subtract that total amount from the amountSpecifiedRemainging.
                state.amountCalculated = state.amountCalculated.sub(step.amountOut.toInt256()); // The amountOut is subtracted from amountCalculated
            } else {
                state.amountSpecifiedRemaining += step.amountOut.toInt256(); // Opposite calculations performed if the exactOutput was specified.
                state.amountCalculated = state.amountCalculated.add((step.amountIn + step.feeAmount).toInt256());
            }

            // if the protocol fee is on, calculate how much is owed, decrement feeAmount, and increment protocolFee
            if (cache.feeProtocol > 0) {
                uint256 delta = step.feeAmount / cache.feeProtocol; // How much protocol fee is owed. Remember that feeProtocol is in the form (1/x)%.
                step.feeAmount -= delta;
                state.protocolFee += uint128(delta);
            }

            // update global fee tracker
            if (state.liquidity > 0) // If there's liquidity being provided, calculate the total amount of fees and update.
                state.feeGrowthGlobalX128 += FullMath.mulDiv(step.feeAmount, FixedPoint128.Q128, state.liquidity);

            // shift tick if we reached the next price
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // if the tick is initialized, run the tick transition
                if (step.initialized) {
                    // check for the placeholder value, which we replace with the actual value the first time the swap
                    // crosses an initialized tick
                    if (!cache.computedLatestObservation) { // If the initialized tick hasn't been crossed.
                        (cache.tickCumulative, cache.secondsPerLiquidityCumulativeX128) = observations.observeSingle( // Takes a snapshot. 
                            cache.blockTimestamp,
                            0,
                            slot0Start.tick,
                            slot0Start.observationIndex,
                            cache.liquidityStart,
                            slot0Start.observationCardinality
                        );
                        cache.computedLatestObservation = true; // Set to true since tickCumulative and secondsPerLiquidityCumulativeX0128 have been computed and cached.
                    }
                    int128 liquidityNet = // Amount of liquidity added or subtracted when tick is crossed.
                        ticks.cross( // Changes to the next tick when price moves enough.
                            step.tickNext,
                            (zeroForOne ? state.feeGrowthGlobalX128 : feeGrowthGlobal0X128), // Both equivalent to fee growth for token0 when zeroForOne is true.
                            (zeroForOne ? feeGrowthGlobal1X128 : state.feeGrowthGlobalX128), // Both equivalent to fee growth for token1 when zeroForOne is false.
                            cache.secondsPerLiquidityCumulativeX128, // Loaded from cache. These next two variables should be zero here.
                            cache.tickCumulative,
                            cache.blockTimestamp
                        );
                    // if we're moving leftward, we interpret liquidityNet as the opposite sign
                    // safe because liquidityNet cannot be type(int128).min
                    if (zeroForOne) liquidityNet = -liquidityNet;

                    state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet); // Updates state so that liquidity equals the previous value plus the amount added/subtracted since crossing a tick.
                }

                state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext; // Depending on the direction of the swap, the next closest tick becomes the current one.
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) { //  If the price hasn't reached the next tick:
                // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }
        
        // update tick and write an oracle entry if the tick change
        if (state.tick != slot0Start.tick) { // There's been a tick change.
            (uint16 observationIndex, uint16 observationCardinality) =
                observations.write( // Observation taken with information from the beginning of the swap.
                    slot0Start.observationIndex,
                    cache.blockTimestamp,
                    slot0Start.tick,
                    cache.liquidityStart,
                    slot0Start.observationCardinality,
                    slot0Start.observationCardinalityNext
                );
            (slot0.sqrtPriceX96, slot0.tick, slot0.observationIndex, slot0.observationCardinality) = ( // Updates slot0 with the current swap information.
                state.sqrtPriceX96,
                state.tick,
                observationIndex,
                observationCardinality
            );
        } else {
            // otherwise just update the price
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }

        // update liquidity if it changed
        if (cache.liquidityStart != state.liquidity) liquidity = state.liquidity;

        // update fee growth global and, if necessary, protocol fees
        // overflow is acceptable, protocol has to withdraw before it hits type(uint128).max fees
        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128; // Remember when zeroForOne is true, feeGrowthGlobalX is essentially feeGrowthGlobal0.
            if (state.protocolFee > 0) protocolFees.token0 += state.protocolFee; // ProtocolFee gets added to whichever token was the input.
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) protocolFees.token1 += state.protocolFee;
        }

        (amount0, amount1) = zeroForOne == exactInput // Updates token swap amounts. The remaining amount of token0 after swapping is subtracted from the amount intended to be swapped. The amountCalculated is how much token1 has been swapped out already.
            ? (amountSpecified - state.amountSpecifiedRemaining, state.amountCalculated)
            : (state.amountCalculated, amountSpecified - state.amountSpecifiedRemaining);

        // do the transfers and collect payment
        if (zeroForOne) {
            if (amount1 < 0) TransferHelper.safeTransfer(token1, recipient, uint256(-amount1)); // Transfers the amountCalculated from the swap to the user. Amount1 should be negative.

            uint256 balance0Before = balance0(); // Balance of token0.
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data); // Makes user pay calculated token amounts.
            require(balance0Before.add(uint256(amount0)) <= balance0(), 'IIA'); // The balance before plus the swapped amount should equal the current balance.
        } else {
            if (amount0 < 0) TransferHelper.safeTransfer(token0, recipient, uint256(-amount0)); // Reverse of that above if swapping token1 for token0.

            uint256 balance1Before = balance1();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            require(balance1Before.add(uint256(amount1)) <= balance1(), 'IIA');
        }

        emit Swap(msg.sender, recipient, amount0, amount1, state.sqrtPriceX96, state.liquidity, state.tick); // Emits swap event.
        slot0.unlocked = true; //  Unlocks pool.
    }

    /// @inheritdoc IUniswapV3PoolActions
    function flash( // Essentially a flash loan where user can be lent tokens and have to pay them back with a fee in the same transaction.
        address recipient,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external override lock noDelegateCall {
        uint128 _liquidity = liquidity; // The liquidity in range stored as a local variable.
        require(_liquidity > 0, 'L'); 

        uint256 fee0 = FullMath.mulDivRoundingUp(amount0, fee, 1e6); // Multiplies amount0 by fee and divides by 1e6 with full precision.
        uint256 fee1 = FullMath.mulDivRoundingUp(amount1, fee, 1e6);
        uint256 balance0Before = balance0(); // Stores the current balances before the loan.
        uint256 balance1Before = balance1(); 

        if (amount0 > 0) TransferHelper.safeTransfer(token0, recipient, amount0); // Transfers the token amounts if they're input as non-zero.
        if (amount1 > 0) TransferHelper.safeTransfer(token1, recipient, amount1);

        IUniswapV3FlashCallback(msg.sender).uniswapV3FlashCallback(fee0, fee1, data); // Makes user pay back the token amounts plus fees.

        uint256 balance0After = balance0(); // Stores the current balance after the loan.
        uint256 balance1After = balance1();

        require(balance0Before.add(fee0) <= balance0After, 'F0'); // Makes sure they were paid back.
        require(balance1Before.add(fee1) <= balance1After, 'F1');

        // sub is safe because we know balanceAfter is gt balanceBefore by at least fee
        uint256 paid0 = balance0After - balance0Before; //  Calculates the amount that's been paid as the balance difference before and after the loan.
        uint256 paid1 = balance1After - balance1Before;

        if (paid0 > 0) { // If fees have been paid, take a portion of the fees for the protocol.
            uint8 feeProtocol0 = slot0.feeProtocol % 16; //  Fees paid to the protocol are a proportion of the fee amount charged by the LP.
            uint256 fees0 = feeProtocol0 == 0 ? 0 : paid0 / feeProtocol0; // The amount of fees paid to the protocl for token0.
            if (uint128(fees0) > 0) protocolFees.token0 += uint128(fees0); // Updates protocolFees.token0 if fees were paid to the protocol for token0.
            feeGrowthGlobal0X128 += FullMath.mulDiv(paid0 - fees0, FixedPoint128.Q128, _liquidity); // Updates feeGrowthGlobal0128 to reflect amount of fees paid to the LPs.
        }
        if (paid1 > 0) { // Same as above except for token1. Not entirely sure why fees paid to the protocol for token1 are right shift 4 instead of modulo 16.
            uint8 feeProtocol1 = slot0.feeProtocol >> 4;
            uint256 fees1 = feeProtocol1 == 0 ? 0 : paid1 / feeProtocol1;
            if (uint128(fees1) > 0) protocolFees.token1 += uint128(fees1);
            feeGrowthGlobal1X128 += FullMath.mulDiv(paid1 - fees1, FixedPoint128.Q128, _liquidity);
        }

        emit Flash(msg.sender, recipient, amount0, amount1, paid0, paid1); // Emits flash event.
    }

    /// @inheritdoc IUniswapV3PoolOwnerActions
    function setFeeProtocol(uint8 feeProtocol0, uint8 feeProtocol1) external override lock onlyFactoryOwner { // Lets the owner (UNI governance) set the protocol fee. 
        require(
            (feeProtocol0 == 0 || (feeProtocol0 >= 4 && feeProtocol0 <= 10)) && // Protocol fee for each token has to be either 0 or between 4 and 10, which means between 10% and 25% of the swap fee.
                (feeProtocol1 == 0 || (feeProtocol1 >= 4 && feeProtocol1 <= 10))
        );
        uint8 feeProtocolOld = slot0.feeProtocol; // Records the old protocol fee.
        slot0.feeProtocol = feeProtocol0 + (feeProtocol1 << 4); // Again, not sure why right shift is used for token1.
        emit SetFeeProtocol(feeProtocolOld % 16, feeProtocolOld >> 4, feeProtocol0, feeProtocol1); //  Emits SetFeeProtocol event.
    }

    /// @inheritdoc IUniswapV3PoolOwnerActions
    function collectProtocol( // Allows the owner to collect the accrued protocol fees.
        address recipient,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override lock onlyFactoryOwner returns (uint128 amount0, uint128 amount1) {
        amount0 = amount0Requested > protocolFees.token0 ? protocolFees.token0 : amount0Requested; // Doesn't let the user ask for more than there is.
        amount1 = amount1Requested > protocolFees.token1 ? protocolFees.token1 : amount1Requested;

        if (amount0 > 0) {
            if (amount0 == protocolFees.token0) amount0--; // ensure that the slot is not cleared, for gas savings. If the full amount were withdrawn, the slot would clear and the gas cost the next time fees were accrued would be higher.
            protocolFees.token0 -= amount0; // Updates protocolFee balance for token0.
            TransferHelper.safeTransfer(token0, recipient, amount0); // Transfers (almost) the requested amount to the user.
        }
        if (amount1 > 0) {
            if (amount1 == protocolFees.token1) amount1--; // ensure that the slot is not cleared, for gas savings
            protocolFees.token1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        emit CollectProtocol(msg.sender, recipient, amount0, amount1); // Emits CollectProtocol event.
    }
}