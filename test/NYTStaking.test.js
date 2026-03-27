const { expect } = require('chai');
const hre = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('NYTStaking', function () {
  let ethers;
  let nyt, staking, owner, staker, staker2;
  let STAKE_AMOUNT;

  before(async function () {
    ethers = hre.ethers;
  });

  beforeEach(async function () {
    STAKE_AMOUNT = ethers.parseEther('5000');
    [owner, staker, staker2] = await ethers.getSigners();

    const NYT = await ethers.getContractFactory('NYT');
    nyt = await NYT.deploy(owner.address, owner.address);
    await nyt.waitForDeployment();
    await nyt.initializeAllocations(
      owner.address,
      owner.address,
      owner.address,
      owner.address,
    );

    const NYTStaking = await ethers.getContractFactory('NYTStaking');
    staking = await NYTStaking.deploy(await nyt.getAddress());
    await staking.waitForDeployment();

    await nyt.transfer(staker.address, STAKE_AMOUNT * 2n);
    await nyt.transfer(staker2.address, STAKE_AMOUNT);
    await nyt.connect(staker).approve(await staking.getAddress(), STAKE_AMOUNT * 2n);
    await nyt.connect(staker2).approve(await staking.getAddress(), STAKE_AMOUNT);
  });

  // ─── Tiers ────────────────────────────────────────────────────────────────
  describe('Tier configuration', function () {
    it('tier 0 is 30 days with 12% APY', async function () {
      const t = await staking.tiers(0);
      expect(t.duration).to.equal(30n * 24n * 60n * 60n);
      expect(t.apyBP).to.equal(1200n);
      expect(t.minStake).to.equal(ethers.parseEther('100'));
    });

    it('tier 3 is 365 days with 100% APY', async function () {
      const t = await staking.tiers(3);
      expect(t.duration).to.equal(365n * 24n * 60n * 60n);
      expect(t.apyBP).to.equal(10000n);
      expect(t.minStake).to.equal(ethers.parseEther('5000'));
    });
  });

  // ─── Staking ──────────────────────────────────────────────────────────────
  describe('Staking', function () {
    it('staker can stake in tier 3', async function () {
      await staking.connect(staker).stake(STAKE_AMOUNT, 3);
      const ids = await staking.getUserStakes(staker.address);
      expect(ids.length).to.equal(1);
    });

    it('emits Staked event', async function () {
      await expect(staking.connect(staker).stake(STAKE_AMOUNT, 3))
        .to.emit(staking, 'Staked');
    });

    it('transfers NYT to staking contract', async function () {
      const balBefore = await nyt.balanceOf(staker.address);
      await staking.connect(staker).stake(STAKE_AMOUNT, 3);
      expect(await nyt.balanceOf(staker.address)).to.equal(balBefore - STAKE_AMOUNT);
    });

    it('updates totalWeightedStake', async function () {
      await staking.connect(staker).stake(STAKE_AMOUNT, 3); // 3x multiplier = 30000 BP
      const expected = STAKE_AMOUNT * 30000n / 10000n;
      expect(await staking.totalWeightedStake()).to.equal(expected);
    });

    it('reverts below minimum stake', async function () {
      const tooLittle = ethers.parseEther('4999');
      await nyt.connect(staker).approve(await staking.getAddress(), tooLittle);
      await expect(staking.connect(staker).stake(tooLittle, 3))
        .to.be.revertedWith('Staking: below minimum');
    });

    it('reverts with invalid tier index', async function () {
      await expect(staking.connect(staker).stake(STAKE_AMOUNT, 4))
        .to.be.revertedWith('Staking: invalid tier');
    });
  });

  // ─── Revenue deposit ──────────────────────────────────────────────────────
  describe('Revenue deposit', function () {
    it('owner can deposit ETH revenue', async function () {
      const deposit = ethers.parseEther('1');
      await staking.connect(owner).depositRevenue({ value: deposit });
      expect(await staking.rewardPool()).to.equal(deposit);
    });

    it('emits RevenueDeposited event', async function () {
      await expect(staking.connect(owner).depositRevenue({ value: ethers.parseEther('1') }))
        .to.emit(staking, 'RevenueDeposited');
    });

    it('non-owner cannot deposit revenue', async function () {
      await expect(staking.connect(staker).depositRevenue({ value: ethers.parseEther('1') }))
        .to.be.revertedWithCustomError(staking, 'OwnableUnauthorizedAccount');
    });

    it('receive() adds to reward pool', async function () {
      const deposit = ethers.parseEther('0.5');
      await owner.sendTransaction({ to: await staking.getAddress(), value: deposit });
      expect(await staking.rewardPool()).to.equal(deposit);
    });
  });

  // ─── Rewards ──────────────────────────────────────────────────────────────
  describe('Reward accumulation', function () {
    beforeEach(async function () {
      await staking.connect(staker).stake(STAKE_AMOUNT, 3);
      await staking.connect(owner).depositRevenue({ value: ethers.parseEther('10') });
    });

    it('pendingReward is negligible immediately after staking', async function () {
      const ids = await staking.getUserStakes(staker.address);
      // Allow up to 1 second of accrual — reward for 1s out of 365 days is tiny
      const oneSecondMax = ethers.parseEther('10') * 1n / (365n * 24n * 60n * 60n);
      expect(await staking.pendingReward(ids[0])).to.be.lte(oneSecondMax + 1n);
    });

    it('pendingReward grows over time', async function () {
      await time.increase(30 * 24 * 60 * 60);
      const ids = await staking.getUserStakes(staker.address);
      expect(await staking.pendingReward(ids[0])).to.be.gt(0n);
    });

    it('staker can claim rewards', async function () {
      await time.increase(30 * 24 * 60 * 60);
      const ids = await staking.getUserStakes(staker.address);
      const reward = await staking.pendingReward(ids[0]);

      const balBefore = await ethers.provider.getBalance(staker.address);
      const tx = await staking.connect(staker).claimRewards(ids[0]);
      const receipt = await tx.wait();
      const gasUsed = receipt.gasUsed * receipt.gasPrice;
      const balAfter = await ethers.provider.getBalance(staker.address);

      expect(balAfter + gasUsed).to.be.closeTo(balBefore + reward, ethers.parseEther('0.0001'));
    });

    it('emits RewardClaimed event', async function () {
      await time.increase(30 * 24 * 60 * 60);
      const ids = await staking.getUserStakes(staker.address);
      await expect(staking.connect(staker).claimRewards(ids[0]))
        .to.emit(staking, 'RewardClaimed');
    });

    it('non-staker cannot claim another user stake', async function () {
      const ids = await staking.getUserStakes(staker.address);
      await expect(staking.connect(staker2).claimRewards(ids[0]))
        .to.be.revertedWith('Staking: not your stake');
    });
  });

  // ─── Unstaking ────────────────────────────────────────────────────────────
  describe('Unstaking', function () {
    beforeEach(async function () {
      await staking.connect(staker).stake(STAKE_AMOUNT, 0); // 30-day tier
      await staking.connect(owner).depositRevenue({ value: ethers.parseEther('1') });
    });

    it('unstake after lock period returns full principal', async function () {
      await time.increase(30 * 24 * 60 * 60 + 1);
      const ids = await staking.getUserStakes(staker.address);
      await staking.connect(staker).unstake(ids[0]);
      expect(await nyt.balanceOf(staker.address)).to.be.gte(STAKE_AMOUNT);
    });

    it('early unstake returns 80% principal', async function () {
      const ids = await staking.getUserStakes(staker.address);
      const balBefore = await nyt.balanceOf(staker.address);
      await staking.connect(staker).unstake(ids[0]);
      const balAfter = await nyt.balanceOf(staker.address);
      expect(balAfter - balBefore).to.equal(STAKE_AMOUNT * 8000n / 10000n);
    });

    it('early unstake burns the 20% penalty', async function () {
      const supplyBefore = await nyt.totalSupply();
      const ids = await staking.getUserStakes(staker.address);
      await staking.connect(staker).unstake(ids[0]);
      const supplyAfter = await nyt.totalSupply();
      expect(supplyBefore - supplyAfter).to.equal(STAKE_AMOUNT * 2000n / 10000n);
    });

    it('emits Unstaked event', async function () {
      const ids = await staking.getUserStakes(staker.address);
      await expect(staking.connect(staker).unstake(ids[0])).to.emit(staking, 'Unstaked');
    });

    it('marks stake inactive after unstake', async function () {
      const ids = await staking.getUserStakes(staker.address);
      await staking.connect(staker).unstake(ids[0]);
      expect((await staking.stakes(ids[0])).active).to.be.false;
    });

    it('reduces totalWeightedStake', async function () {
      const weightBefore = await staking.totalWeightedStake();
      const ids = await staking.getUserStakes(staker.address);
      await staking.connect(staker).unstake(ids[0]);
      expect(await staking.totalWeightedStake()).to.be.lt(weightBefore);
    });
  });
});
