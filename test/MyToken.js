const { ethers } = require("hardhat");
const { expect } = require("chai");
const { TickMath, encodeSqrtRatioX96 } = require("@uniswap/v3-sdk");

describe("Factory", function () {
    const tokenA = "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984";
    const tokenB = "0xEcd0D12E21805803f70de03B72B1C162dB0898d9";
    const tokenC = "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599";
    const tokenD = "0x6B175474E89094C44Da98b954EedeAC495271d0F";

    it("createPool", async function () {
        const Factory = await ethers.getContractFactory("Factory");
        const factory = await Factory.deploy();
        await factory.waitForDeployment()

        const tx = await factory.createPool(tokenA, tokenB, 1, 100000, 3000);
        const receipt = await tx.wait();
        const event = receipt.logs.find(log => log.eventName === "PoolCreated");
        expect(event.args.pool).to.match(/^0x[a-fA-F0-9]{40}$/);
        expect(event.args.token0).to.equal(tokenA);
        expect(event.args.token1).to.equal(tokenB);
        expect(event.args.tickLower).to.equal(1);
        expect(event.args.tickUpper).to.equal(100000);
        expect(event.args.fee).to.equal(3000);
    });

    it("getPairs & getAllPools", async function () {
        const PoolManager = await ethers.getContractFactory("PoolManager");
        const poolManager = await PoolManager.deploy();
        await poolManager.waitForDeployment();

        await poolManager.createAndInitializePoolIfNecessary(
            {
                token0: tokenA,
                token1: tokenB,
                fee: 3000,
                tickLower: TickMath.getTickAtSqrtRatio(encodeSqrtRatioX96(1, 1)),
                tickUpper: TickMath.getTickAtSqrtRatio(encodeSqrtRatioX96(10000, 1)),
                sqrtPriceX96: BigInt(encodeSqrtRatioX96(100, 1).toString()),
            }
        );

        await poolManager.createAndInitializePoolIfNecessary(
            {
                token0: tokenC,
                token1: tokenD,
                fee: 3000,
                tickLower: TickMath.getTickAtSqrtRatio(encodeSqrtRatioX96(100, 1)),
                tickUpper: TickMath.getTickAtSqrtRatio(encodeSqrtRatioX96(5000, 1)),
                sqrtPriceX96: BigInt(encodeSqrtRatioX96(200, 1).toString()),
            }
        );

        const pairs = await poolManager.getPairs()
        expect(pairs.length).to.equal(2);
        expect(pairs[0].token0).to.equal(tokenA);
        expect(pairs[0].token1).to.equal(tokenB);
        expect(pairs[1].token0).to.equal(tokenC);
        expect(pairs[1].token1).to.equal(tokenD);
        // 获取所有池子
        const pools = await poolManager.getAllPools();
        expect(pools.length).to.equal(2);
        expect(pools[0].token0).to.equal(tokenA);
        expect(pools[0].token1).to.equal(tokenB);
        expect(pools[0].sqrtPriceX96).to.equal(BigInt(encodeSqrtRatioX96(100, 1).toString()));
        expect(pools[0].tickLower).to.equal(0);
        expect(pools[0].tickUpper).to.equal(92108);
        expect(pools[0].fee).to.equal(3000);
        //
        expect(pools[1].token0).to.equal(tokenC);
        expect(pools[1].token1).to.equal(tokenD);
        expect(pools[1].sqrtPriceX96).to.equal(BigInt(encodeSqrtRatioX96(200, 1).toString()));
        expect(pools[1].tickLower).to.equal(46054);
        expect(pools[1].tickUpper).to.equal(85176);
        expect(pools[1].fee).to.equal(3000);
    })
});