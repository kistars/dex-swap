// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Factory.sol";
import "./interfaces/IPoolManager.sol";

contract PoolManager is Factory, IPoolManager {
    Pair[] public pairs;

    // 创建池子
    function createAndInitializePoolIfNecessary(CreateAndInitializeParams calldata params)
        external
        payable
        returns (address poolAddress)
    {
        require(params.token0 < params.token1);
        // 调用Factory的方法
        poolAddress = this.createPool(params.token0, params.token1, params.tickLower, params.tickUpper, params.fee);

        //
        IPool pool = IPool(poolAddress);

        //
        uint256 index = pools[pool.token0()][pool.token1()].length;

        if (pool.sqrtPriceX96() == 0) {
            pool.initialize(params.sqrtPriceX96);
            if (index == 1) {
                // 第一个创建的池子
                pairs.push(Pair({token0: pool.token0(), token1: pool.token1()}));
            }
        }
    }

    function getAllPools() external view returns (PoolInfo[] memory poolsInfo) {
        uint256 len = 0;
        for (uint32 i = 0; i < pairs.length; i++) {
            len += pools[pairs[i].token0][pairs[i].token1].length;
        }

        // 再填充数据
        poolsInfo = new PoolInfo[](len);
        uint256 index = 0;
        for (uint32 i = 0; i < pairs.length; i++) {
            address[] memory addresses = pools[pairs[i].token0][pairs[i].token1];
            for (uint32 j = 0; j < addresses.length; j++) {
                IPool pool = IPool(addresses[j]);
                poolsInfo[index] = PoolInfo({
                    pool: addresses[j],
                    token0: pool.token0(),
                    token1: pool.token1(),
                    index: j,
                    fee: pool.fee(),
                    feeProtocol: 0,
                    tickLower: pool.tickLower(),
                    tickUpper: pool.tickUpper(),
                    tick: pool.tick(),
                    sqrtPriceX96: pool.sqrtPriceX96(),
                    liquidity: pool.liquidity()
                });

                index++;
            }
        }
        return poolsInfo;
    }

    function getPairs() external view returns (Pair[] memory) {
        return pairs;
    }
}
