// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;
pragma abicoder v2;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./libraries/LiquidityAmounts.sol";
import "./libraries/TickMath.sol";
import "./libraries/FixedPoint128.sol";

import "./interfaces/IPositionManager.sol";
import "./interfaces/IPool.sol";
import "./interfaces/IPoolManager.sol";

contract PositionManager is IPositionManager, ERC721 {
    // 保存 PoolManager 合约地址
    IPoolManager public poolManager;

    /// @dev The ID of the next token that will be minted. Skips 0
    uint176 private _nextId = 1;

    constructor(address _poolManger) ERC721("WTFSwapPosition", "WTFP") {
        poolManager = IPoolManager(_poolManger);
    }

    // 用一个 mapping 来存放所有 Position 的信息
    mapping(uint256 => PositionInfo) public positions;

    // 获取全部的 Position 信息
    function getAllPositions() external view override returns (PositionInfo[] memory positionInfo) {
        positionInfo = new PositionInfo[](_nextId - 1);
        for (uint32 i = 0; i < _nextId - 1; i++) {
            positionInfo[i] = positions[i + 1];
        }
        return positionInfo;
    }

    function getSender() public view returns (address) {
        return msg.sender;
    }

    function _blockTimestamp() internal view virtual returns (uint256) {
        return block.timestamp;
    }

    modifier checkDeadline(uint256 deadline) {
        require(_blockTimestamp() <= deadline, "Transaction too old");
        _;
    }

    // 内部函数：计算流动性
    function _calculateLiquidity(address pool, uint256 amount0Desired, uint256 amount1Desired)
        internal
        view
        returns (uint128 liquidity)
    {
        IPool poolContract = IPool(pool);
        uint160 sqrtPriceX96 = poolContract.sqrtPriceX96();
        uint160 sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(poolContract.tickLower());
        uint160 sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(poolContract.tickUpper());

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, amount0Desired, amount1Desired
        );
    }

    // 内部函数：创建Position信息
    function _createPositionInfo(
        uint256 positionId,
        address recipient,
        address token0,
        address token1,
        uint32 index,
        uint128 liquidity,
        address pool
    ) internal view returns (PositionInfo memory) {
        IPool poolContract = IPool(pool);
        (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128,,) =
            poolContract.getPosition(address(this));

        return PositionInfo({
            id: positionId,
            owner: recipient,
            token0: token0,
            token1: token1,
            index: index,
            fee: poolContract.fee(),
            liquidity: liquidity,
            tickLower: poolContract.tickLower(),
            tickUpper: poolContract.tickUpper(),
            tokensOwed0: 0,
            tokensOwed1: 0,
            feeGrowthInside0LastX128: feeGrowthInside0LastX128,
            feeGrowthInside1LastX128: feeGrowthInside1LastX128
        });
    }

    function mint(MintParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 positionId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        // 获取Pool地址
        address _pool = poolManager.getPool(params.token0, params.token1, params.index);
        IPool pool = IPool(_pool);

        // 计算流动性
        liquidity = _calculateLiquidity(_pool, params.amount0Desired, params.amount1Desired);

        // 准备回调数据
        bytes memory data = abi.encode(params.token0, params.token1, params.index, msg.sender);

        // 调用Pool的mint方法
        (amount0, amount1) = pool.mint(address(this), liquidity, data);

        // 铸造NFT
        positionId = _nextId++;
        _mint(params.recipient, positionId);

        // 创建并存储Position信息
        positions[positionId] = _createPositionInfo(
            positionId, params.recipient, params.token0, params.token1, params.index, liquidity, _pool
        );
    }

    modifier isAuthorizedForToken(uint256 tokenId) {
        address owner = ERC721.ownerOf(tokenId);
        require(_isAuthorized(owner, msg.sender, tokenId), "Not approved");
        _;
    }

    function burn(uint256 positionId)
        external
        override
        isAuthorizedForToken(positionId)
        returns (uint256 amount0, uint256 amount1)
    {
        PositionInfo storage position = positions[positionId];
        // 通过 isAuthorizedForToken 检查 positionId 是否有权限
        // 移除流动性，但是 token 还是保留在 pool 中，需要再调用 collect 方法才能取回 token
        // 通过 positionId 获取对应 LP 的流动性
        uint128 _liquidity = position.liquidity;
        // 调用 Pool 的方法给 LP 退流动性
        address _pool = poolManager.getPool(position.token0, position.token1, position.index);
        IPool pool = IPool(_pool);
        (amount0, amount1) = pool.burn(_liquidity);

        // 计算这部分流动性产生的手续费
        // todo: 这里可以优化
        (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128,,) = pool.getPosition(address(this));

        position.tokensOwed0 += uint128(amount0)
            + uint128(
                FullMath.mulDiv(
                    feeGrowthInside0LastX128 - position.feeGrowthInside0LastX128, position.liquidity, FixedPoint128.Q128
                )
            );

        position.tokensOwed1 += uint128(amount1)
            + uint128(
                FullMath.mulDiv(
                    feeGrowthInside1LastX128 - position.feeGrowthInside1LastX128, position.liquidity, FixedPoint128.Q128
                )
            );

        // 更新 position 的信息
        position.feeGrowthInside0LastX128 = feeGrowthInside0LastX128;
        position.feeGrowthInside1LastX128 = feeGrowthInside1LastX128;
        position.liquidity = 0;
    }

    function collect(uint256 positionId, address recipient)
        external
        override
        isAuthorizedForToken(positionId)
        returns (uint256 amount0, uint256 amount1)
    {
        // 通过 isAuthorizedForToken 检查 positionId 是否有权限
        // 调用 Pool 的方法给 LP 退流动性
        PositionInfo storage position = positions[positionId];
        address _pool = poolManager.getPool(position.token0, position.token1, position.index);
        IPool pool = IPool(_pool);
        (amount0, amount1) = pool.collect(recipient, position.tokensOwed0, position.tokensOwed1);

        // position 已经彻底没用了，销毁
        position.tokensOwed0 = 0;
        position.tokensOwed1 = 0;
        _burn(positionId);
    }

    function mintCallback(uint256 amount0, uint256 amount1, bytes calldata data) external override {
        // 检查 callback 的合约地址是否是 Pool
        (address token0, address token1, uint32 index, address payer) =
            abi.decode(data, (address, address, uint32, address));
        address _pool = poolManager.getPool(token0, token1, index);
        require(_pool == msg.sender, "Invalid callback caller");

        // 在这里给 Pool 打钱，需要用户先 approve 足够的金额，这里才会成功
        if (amount0 > 0) {
            IERC20(token0).transferFrom(payer, msg.sender, amount0);
        }
        if (amount1 > 0) {
            IERC20(token1).transferFrom(payer, msg.sender, amount1);
        }
    }
}
