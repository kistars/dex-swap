// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "./Pool.sol";
import "./interfaces/IFactory.sol";

// 主要功能是创建交易池（Pool）, 不同的交易对包括相同交易对只要价格上下限和手续费不同就会创建一个新的交易池
contract Factory is IFactory {
    //
    mapping(address => mapping(address => address[])) public pools;
    //
    Parameters public override parameters;

    function sortToken(address tokenA, address tokenB) private pure returns (address, address) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    //
    function createPool(address tokenA, address tokenB, int24 tickLower, int24 tickUpper, uint24 fee)
        external
        returns (address pool)
    {
        require(tokenA != tokenB, "Identical address");

        address token0;
        address token1;

        // sort
        (token0, token1) = sortToken(tokenA, tokenB);

        // 判读交易池是否已存在
        address[] memory existingPools = pools[token0][token1];
        for (uint256 i = 0; i < existingPools.length; i++) {
            IPool currentPool = IPool(existingPools[i]);
            if (
                currentPool.tickLower() == tickLower && currentPool.tickUpper() == tickUpper && currentPool.fee() == fee
            ) {
                return existingPools[i];
            }
        }

        // save pool info
        parameters = Parameters(address(this), tokenA, tokenB, tickLower, tickUpper, fee);

        // generate create2 salt
        bytes32 salt = keccak256(abi.encode(token0, token1, tickLower, tickUpper, fee));
        //
        pool = address(new Pool{salt: salt}());

        // save
        pools[token0][token1].push(pool);
        //
        delete parameters;

        // event
        emit PoolCreated(token0, token1, uint32(existingPools.length), tickLower, tickUpper, fee, pool);
    }

    function getPool(address tokenA, address tokenB, uint32 index) external view returns (address) {
        require(tokenA != tokenB, "Identical address");
        require(tokenA != address(0) && tokenB != address(0), "zero address");

        address token0;
        address token1;

        (token0, token1) = sortToken(tokenA, tokenB);

        return pools[token0][token1][index];
    }
}
