// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./libraries/SqrtPriceMath.sol";
import "./libraries/TickMath.sol";
import "./libraries/LiquidityMath.sol";
import "./libraries/LowGasSafeMath.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/SwapMath.sol";
import "./libraries/FixedPoint128.sol";
import "./libraries/SafeCast.sol";

import "./interfaces/IPool.sol";
import "./interfaces/IFactory.sol";

contract Pool is IPool {
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for int256;
    using LowGasSafeMath for uint160;

    address public immutable override factory;
    address public immutable override token0;
    address public immutable override token1;
    uint24 public immutable override fee;
    int24 public immutable override tickLower;
    int24 public immutable override tickUpper;

    /// @inheritdoc IPool
    uint160 public override sqrtPriceX96;
    /// @inheritdoc IPool
    int24 public override tick;
    /// @inheritdoc IPool
    uint128 public override liquidity;

    // 从池子创建以来累计收取到的手续费
    /// @inheritdoc IPool
    uint256 public override feeGrowthGlobal0X128;
    /// @inheritdoc IPool
    uint256 public override feeGrowthGlobal1X128;

    // 交易中需要临时存储的变量
    struct SwapState {
        // the amount remaining to be swapped in/out of the input/output asset
        int256 amountSpecifiedRemaining;
        // the amount already swapped out/in of the output/input asset
        int256 amountCalculated;
        // current sqrt(price)
        uint160 sqrtPriceX96;
        // the global fee growth of the input token
        uint256 feeGrowthGlobalX128;
        // 该交易中用户转入的 token0 的数量
        uint256 amountIn;
        // 该交易中用户转出的 token1 的数量
        uint256 amountOut;
        // 该交易中的手续费，如果 zeroForOne 是 ture，则是用户转入 token0，单位是 token0 的数量，反正是 token1 的数量
        uint256 feeAmount;
    }

    constructor() {
        (factory, token0, token1, tickLower, tickUpper, fee) = IFactory(msg.sender).parameters();
    }

    function initialize(uint160 _sqrtPriceX96) external {
        // 初始化 Pool 的 sqrtPriceX96
        sqrtPriceX96 = _sqrtPriceX96;
    }

    // 增加流动性
    /// @param recipient: 流动性权益接受者
    /// @param amount: 提供的流动性值
    function mint(address recipient, uint128 amount, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        // 基于增加的流动性amount，计算出需要转入池子多少amount0和amount1
        (int256 amount0Int, int256 amount1Int) = _modifyPosition(int128(amount));

        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);

        // 当前池子中两种代币余额
        uint256 balance0Before;
        uint256 balance1Before;
        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();

        // 将两种代币转入池子
        IMintCallback(msg.sender).mintCallback(amount0, amount1, data);

        // 检查代币是否转成功
        if (amount0 > 0) {
            require(balance0Before.add(amount0) <= balance0(), "M0");
        }
        if (amount0 > 0) {
            require(balance1Before.add(amount1) <= balance1(), "M1");
        }

        emit Mint(msg.sender, recipient, amount, amount0, amount1);
    }

    /// @dev Get the pool's balance of token0
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
    /// check
    function balance0() private view returns (uint256) {
        (bool success, bytes memory data) =
            token0.staticcall(abi.encodeWithSelector(IERC20.balanceOf.selector, address(this)));
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    /// @dev Get the pool's balance of token1
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
    /// check
    function balance1() private view returns (uint256) {
        (bool success, bytes memory data) =
            token1.staticcall(abi.encodeWithSelector(IERC20.balanceOf.selector, address(this)));
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    // 减少流动性
    /// @param amount: 移除流动性的值
    function burn(uint128 amount) external returns (uint256 amount0, uint256 amount1) {
        require(amount > 0, "Burn amount must be greater than 0");

        // 修改position的信息
        (int256 amount0Int, int256 amount1Int) = _modifyPosition(-int128(amount));

        // 获得需要更改的代币数量
        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        emit Burn(msg.sender, amount, amount0, amount1);
    }

    // 修改头寸（持仓）
    function _modifyPosition(int128 liquidityDelta) private returns (int256 amount0, int256 amount1) {
        // 更具变化的流动性，计算变化的token0, token1数量
        amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickUpper), liquidityDelta);
        amount1 = SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(tickLower), sqrtPriceX96, liquidityDelta);

        // pool总流动性
        liquidity = LiquidityMath.addDelta(liquidity, liquidityDelta);
    }

    // 交换代币
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1) {
        require(amountSpecified != 0, "AS");

        // zeroForOne: 如果从 token0 交换 token1 则为 true，从 token1 交换 token0 则为 false
        // 判断当前价格是否满足交易的条件
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < sqrtPriceX96 && sqrtPriceLimitX96 > TickMath.MIN_SQRT_PRICE
                : sqrtPriceLimitX96 > sqrtPriceX96 && sqrtPriceLimitX96 < TickMath.MAX_SQRT_PRICE,
            "SPL"
        );

        // amountSpecified 大于 0 代表用户指定了输入 token 的数量，（用多少个token换）
        // 小于 0 代表用户指定了输出 token 的数量，（要获得多少个token）
        bool exactInput = amountSpecified > 0;

        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: sqrtPriceX96,
            feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128,
            amountIn: 0,
            amountOut: 0,
            feeAmount: 0
        });

        // 计算交易的上下限，基于 tick 计算价格
        uint160 sqrtPriceX96Lower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceX96Upper = TickMath.getSqrtPriceAtTick(tickUpper);
        // 计算用户交易价格的限制，如果是 zeroForOne 是 true，说明用户会换入 token0，会压低 token0 的价格（也就是池子的价格）
        // 所以要限制最低价格不能低于 sqrtPriceX96Lower
        uint160 sqrtPriceX96PoolLimit = zeroForOne ? sqrtPriceX96Lower : sqrtPriceX96Upper;

        // 计算交易的具体数值
        (state.sqrtPriceX96, state.amountIn, state.amountOut, state.feeAmount) = SwapMath.computeSwapStep(
            sqrtPriceX96,
            (zeroForOne ? sqrtPriceX96PoolLimit.max(sqrtPriceLimitX96) : sqrtPriceX96PoolLimit.min(sqrtPriceLimitX96)),
            liquidity,
            amountSpecified,
            fee
        );

        // 更新新的价格
        sqrtPriceX96 = state.sqrtPriceX96;
        tick = TickMath.getTickAtSqrtPrice(state.sqrtPriceX96);

        // 计算手续费
        state.feeGrowthGlobalX128 += FullMath.mulDiv(state.feeAmount, FixedPoint128.Q128, liquidity);

        // 更新手续费相关信息
        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
        }

        // 计算交易后用户手里的 token0 和 token1 的数量
        if (exactInput) {
            state.amountSpecifiedRemaining -= SafeCast.toInt256(state.amountIn + state.feeAmount);
            state.amountCalculated = state.amountCalculated.sub(SafeCast.toInt256(state.amountOut));
        } else {
            state.amountSpecifiedRemaining += SafeCast.toInt256(state.amountOut);
            state.amountCalculated = state.amountCalculated.add(SafeCast.toInt256(state.amountIn + state.feeAmount));
        }

        (amount0, amount1) = zeroForOne == exactInput
            ? (amountSpecified - state.amountSpecifiedRemaining, state.amountCalculated)
            : (state.amountCalculated, amountSpecified - state.amountSpecifiedRemaining);

        if (zeroForOne) {
            // callback 中需要给 Pool 转入 token
            uint256 balance0Before = balance0();
            ISwapCallback(msg.sender).swapCallback(amount0, amount1, data);
            require(balance0Before.add(uint256(amount0)) <= balance0(), "IIA");

            // 转 Token 给用户
            if (amount1 < 0) {
                TransferHelper.safeTransfer(token1, recipient, uint256(-amount1));
            }
        } else {
            // callback 中需要给 Pool 转入 token
            uint256 balance1Before = balance1();
            ISwapCallback(msg.sender).swapCallback(amount0, amount1, data);
            require(balance1Before.add(uint256(amount1)) <= balance1(), "IIA");

            // 转 Token 给用户
            if (amount0 < 0) {
                TransferHelper.safeTransfer(token0, recipient, uint256(-amount0));
            }
        }

        emit Swap(msg.sender, recipient, amount0, amount1, sqrtPriceX96, liquidity, tick);
    }
}
