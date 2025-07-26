const { ethers } = require("hardhat");
const { expect } = require("chai");
const { TickMath, encodeSqrtRatioX96 } = require("@uniswap/v3-sdk");

describe("Pool", function () {
    let factory, tokenA, tokenB, token0, token1, tickLower, tickUpper, fee, pool;
    let lp, swap, liquidityDelta, sqrtPriceX96;
    it("createPool", async function () {
        // 初始化一个池子，价格上限是 40000，下限是 1，初始化价格是 10000，费率是 0.3%
        const Factory = await ethers.getContractFactory("Factory");
        factory = await Factory.deploy();
        await factory.waitForDeployment();
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
        // 创建池子
        await factory.createPool(token0, token1, tickLower, tickUpper, fee);
        const poolAddr = await factory.getPool(token0, token1, 0);
        // 获取池子合约实例
        pool = await ethers.getContractAt("Pool", poolAddr);
        // 计算一个初始化的价格，按照 1 个 token0 换 10000 个 token1 来算，其实就是 10000
        sqrtPriceX96 = encodeSqrtRatioX96(10000, 1).toString();
        await pool.initialize(sqrtPriceX96);
        expect(await pool.token0()).to.eq(token0.target);
        expect(await pool.token1()).to.eq(token1.target);
        expect(await pool.tickLower()).to.eq(tickLower);
        expect(await pool.tickUpper()).to.eq(tickUpper);
        expect(await pool.fee()).to.eq(fee.toString());
        expect(await pool.sqrtPriceX96()).to.eq(sqrtPriceX96);
    });

    it("mint and burn and collect", async function () {
        const LP = await ethers.getContractFactory("TestLP");
        lp = await LP.deploy();
        await lp.waitForDeployment();

        // 给流动性提供者(LP)铸造代币
        const initBalanceValue = 100000000000n * 10n ** 18n;
        await token0.mint(lp.target, initBalanceValue);
        await token1.mint(lp.target, initBalanceValue);

        // 给池子提供流动性
        // mint 多一些流动性，确保交易可以完全完成
        liquidityDelta = 1000000000000000000000000000n;
        await lp.mint(
            lp.target,
            liquidityDelta,
            pool.target,
            token0.target,
            token1.target
        );

        //
        expect(await token0.balanceOf(pool.target)).to.eq(initBalanceValue - (await token0.balanceOf(lp.target)));
        expect(await token1.balanceOf(pool.target)).to.eq(initBalanceValue - (await token1.balanceOf(lp.target)));

        // 
        const position = await pool.positions(lp.target);
        expect(position).to.deep.eq([1000000000000000000000000000n, 0n, 0n, 0n, 0n]);
        expect(await pool.liquidity()).to.eq(1000000000000000000000000000n);
    });

    it("swap", async function () {
        const Swap = await ethers.getContractFactory("TestSwap");
        swap = await Swap.deploy();
        await swap.waitForDeployment();


        const lpToken0 = await token0.balanceOf(lp.target);
        expect(lpToken0).to.equal(99995000161384542080378486215n);
        const lpToken1 = await token1.balanceOf(lp.target);
        expect(lpToken1).to.equal(1000000000000000000000000000n);

        // 通过testSwap完成交易
        const minPrice = 1000;
        const minSqrtPriceX96 = BigInt(
            encodeSqrtRatioX96(minPrice, 1).toString()
        );

        // 向testSwap(用户)合约转入token0
        await token0.mint(swap.target, 300n * 10n ** 18n);
        expect(await token0.balanceOf(swap.target)).to.eq(300n * 10n ** 18n);
        expect(await token1.balanceOf(swap.target)).to.eq(0n);

        const tx = await swap.testSwap(swap.target, 100n * 10n ** 18n, minSqrtPriceX96, pool.target, token0.target, token1.target);
        const receipt = await tx.wait();

        // 解析所有事件
        const events = receipt.logs
            .map(log => {
                try {
                    return pool.interface.parseLog(log);
                } catch {
                    return null;
                }
            })
            .filter(e => e !== null);

        // 查找特定事件
        const swapEvent = events.find(e => e.name === "Swap");
        expect(swapEvent.args.amount0).to.eq(100000000000000000000n); // 换入100个token0
        expect(swapEvent.args.amount1).to.eq(-996990060009101709255958n); // 换出这么多token1

        const costToken0 = 300n * 10n ** 18n - (await token0.balanceOf(swap.target));
        const receivedToken1 = await token1.balanceOf(swap.target);
        const newPrice = await pool.sqrtPriceX96();
        const liquidity = await pool.liquidity();
        expect(newPrice).to.equal(7922737261735934252089901697281n);
        expect(sqrtPriceX96).to.equal(newPrice + 78989690499507264493336319n); // 价格下跌
        expect(liquidity).to.equal(liquidityDelta); // 流动性不变

        // 用户消耗了 100 个 token0
        expect(costToken0).to.equal(100n * 10n ** 18n);
        // 用户获得了大约 100 * 10000 个 token1
        expect(receivedToken1).to.equal(996990060009101709255958n);

        // 手续费
        await lp.burn(liquidityDelta, pool.target);
        expect(await token0.balanceOf(lp.target)).to.equal(99995000161384542080378486215n);
        // 提取token
        await lp.collect(lp.target, pool.target);
        // 判断 token 是否返回给 lp，并且大于原来的数量，因为收到了手续费，并且有交易换入了 token0
        // 初始的 token0 是 const initBalanceValue = 100000000000n * 10n ** 18n;
        expect(await token0.balanceOf(lp.target)).to.equal(100000000099999999999999999998n);
    });
});