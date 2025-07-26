
const { ethers } = require("hardhat");
const { expect } = require("chai");
const { TickMath, encodeSqrtRatioX96, NonfungiblePositionManager } = require("@uniswap/v3-sdk");

describe("Pool", function () {
    let poolMgr, tokenA, tokenB, token0, token1, tickLower, tickUpper, fee, pool;
    let lp, swap, liquidityDelta, sqrtPriceX96, poolAddr, positionMgr;
    it("createPool", async function () {
        const [sender] = await ethers.getSigners();
        // 初始化一个池子，价格上限是 40000，下限是 1，初始化价格是 10000，费率是 0.3%
        const PoolMgr = await ethers.getContractFactory("PoolManager");
        poolMgr = await PoolMgr.deploy();
        await poolMgr.waitForDeployment();
        // 部署tokenA
        const TokenA = await ethers.getContractFactory("TestToken");
        tokenA = await TokenA.deploy();
        await tokenA.waitForDeployment();
        // 部署tokenB
        const TokenB = await ethers.getContractFactory("TestToken");
        tokenB = await TokenB.deploy();
        await tokenB.waitForDeployment();
        // sort
        token0 = tokenA.target < tokenB.target ? tokenA : tokenB;
        token1 = tokenA.target < tokenB.target ? tokenB : tokenA;
        tickLower = TickMath.getTickAtSqrtRatio(encodeSqrtRatioX96(1, 1));
        tickUpper = TickMath.getTickAtSqrtRatio(encodeSqrtRatioX96(40000, 1));
        fee = 3000; // 0.3%
        // 计算一个初始化的价格，按照 1 个 token0 换 10000 个 token1 来算，其实就是 10000
        sqrtPriceX96 = encodeSqrtRatioX96(10000, 1).toString();
        // 创建池子
        await poolMgr.createAndInitializePoolIfNecessary(
            {
                token0: token0.target,
                token1: token1.target,
                fee: fee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                sqrtPriceX96: BigInt(encodeSqrtRatioX96(10000, 1).toString()),
            }
        );
        // 获取池子合约实例
        poolAddr = await poolMgr.getPool(token0.target, token1.target, 0);
        pool = await ethers.getContractAt("Pool", poolAddr);
        await pool.initialize(sqrtPriceX96);
        // 部署positionMgr
        const PositionMgr = await ethers.getContractFactory("PositionManager");
        positionMgr = await PositionMgr.deploy(poolMgr.target);
        await positionMgr.waitForDeployment();
    });
});