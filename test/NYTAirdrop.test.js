const { expect } = require('chai');
const hre = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('NYTAirdrop', function () {
  let ethers;
  let nyt, airdrop, owner, recip1, recip2, other;
  let AIRDROP_SUPPLY, AMOUNT1, AMOUNT2;

  before(async function () {
    ethers = hre.ethers;
  });

  beforeEach(async function () {
    AIRDROP_SUPPLY = ethers.parseEther('18000000');
    AMOUNT1 = ethers.parseEther('1000');
    AMOUNT2 = ethers.parseEther('500');
    [owner, recip1, recip2, other] = await ethers.getSigners();

    const NYT = await ethers.getContractFactory('NYT');
    nyt = await NYT.deploy(owner.address, owner.address);
    await nyt.waitForDeployment();
    await nyt.initializeAllocations(
      owner.address,
      owner.address,
      owner.address,
      owner.address,
    );

    const NYTAirdrop = await ethers.getContractFactory('NYTAirdrop');
    airdrop = await NYTAirdrop.deploy(await nyt.getAddress());
    await airdrop.waitForDeployment();

    await nyt.transfer(await airdrop.getAddress(), AIRDROP_SUPPLY);
  });

  // ─── batchAirdrop ─────────────────────────────────────────────────────────
  describe('batchAirdrop', function () {
    it('sets allocations for multiple recipients', async function () {
      await airdrop.batchAirdrop([recip1.address, recip2.address], [AMOUNT1, AMOUNT2]);
      expect(await airdrop.allocation(recip1.address)).to.equal(AMOUNT1);
      expect(await airdrop.allocation(recip2.address)).to.equal(AMOUNT2);
    });

    it('emits AirdropSet for each recipient', async function () {
      await expect(airdrop.batchAirdrop([recip1.address], [AMOUNT1]))
        .to.emit(airdrop, 'AirdropSet')
        .withArgs(recip1.address, AMOUNT1);
    });

    it('updates totalAllocated', async function () {
      await airdrop.batchAirdrop([recip1.address, recip2.address], [AMOUNT1, AMOUNT2]);
      expect(await airdrop.totalAllocated()).to.equal(AMOUNT1 + AMOUNT2);
    });

    it('non-owner cannot call batchAirdrop', async function () {
      await expect(airdrop.connect(other).batchAirdrop([recip1.address], [AMOUNT1]))
        .to.be.revertedWithCustomError(airdrop, 'OwnableUnauthorizedAccount');
    });

    it('reverts on length mismatch', async function () {
      await expect(airdrop.batchAirdrop([recip1.address, recip2.address], [AMOUNT1]))
        .to.be.revertedWith('Airdrop: length mismatch');
    });

    it('reverts if insufficient balance', async function () {
      const tooMuch = AIRDROP_SUPPLY + 1n;
      await expect(airdrop.batchAirdrop([recip1.address], [tooMuch]))
        .to.be.revertedWith('Airdrop: insufficient balance');
    });
  });

  // ─── Claim ────────────────────────────────────────────────────────────────
  describe('Claim', function () {
    beforeEach(async function () {
      await airdrop.batchAirdrop([recip1.address, recip2.address], [AMOUNT1, AMOUNT2]);
    });

    it('recipient can claim their allocation', async function () {
      await airdrop.connect(recip1).claim();
      expect(await nyt.balanceOf(recip1.address)).to.equal(AMOUNT1);
    });

    it('emits Claimed event', async function () {
      await expect(airdrop.connect(recip1).claim())
        .to.emit(airdrop, 'Claimed')
        .withArgs(recip1.address, AMOUNT1);
    });

    it('marks recipient as claimed', async function () {
      await airdrop.connect(recip1).claim();
      expect(await airdrop.claimed(recip1.address)).to.be.true;
    });

    it('cannot claim twice', async function () {
      await airdrop.connect(recip1).claim();
      await expect(airdrop.connect(recip1).claim())
        .to.be.revertedWith('Airdrop: already claimed');
    });

    it('cannot claim with no allocation', async function () {
      await expect(airdrop.connect(other).claim())
        .to.be.revertedWith('Airdrop: no allocation');
    });

    it('cannot claim after deadline passes', async function () {
      const deadline = (await time.latest()) + 90 * 24 * 60 * 60;
      await airdrop.setClaimDeadline(deadline);
      await time.increase(90 * 24 * 60 * 60 + 1);
      await expect(airdrop.connect(recip1).claim())
        .to.be.revertedWith('Airdrop: claim window closed');
    });
  });

  // ─── Deadline and sweep ───────────────────────────────────────────────────
  describe('Deadline and sweep', function () {
    beforeEach(async function () {
      await airdrop.batchAirdrop([recip1.address], [AMOUNT1]);
    });

    it('owner can set claim deadline', async function () {
      const deadline = (await time.latest()) + 90 * 24 * 60 * 60;
      await airdrop.setClaimDeadline(deadline);
      expect(await airdrop.claimDeadline()).to.equal(BigInt(deadline));
    });

    it('reverts if deadline is in the past', async function () {
      const past = (await time.latest()) - 1;
      await expect(airdrop.setClaimDeadline(past))
        .to.be.revertedWith('Airdrop: deadline in past');
    });

    it('owner sweeps unclaimed tokens after deadline', async function () {
      const deadline = (await time.latest()) + 3600; // 1 hour — safely in the future
      await airdrop.setClaimDeadline(deadline);
      await time.increase(3601);
      const ownerBalBefore = await nyt.balanceOf(owner.address);
      await airdrop.sweep();
      expect(await nyt.balanceOf(owner.address)).to.be.gt(ownerBalBefore);
    });

    it('emits Swept event', async function () {
      const deadline = (await time.latest()) + 3600;
      await airdrop.setClaimDeadline(deadline);
      await time.increase(3601);
      await expect(airdrop.sweep()).to.emit(airdrop, 'Swept');
    });

    it('cannot sweep before deadline', async function () {
      const deadline = (await time.latest()) + 90 * 24 * 60 * 60;
      await airdrop.setClaimDeadline(deadline);
      await expect(airdrop.sweep()).to.be.revertedWith('Airdrop: deadline not reached');
    });

    it('cannot sweep without deadline set', async function () {
      await expect(airdrop.sweep()).to.be.revertedWith('Airdrop: no deadline set');
    });
  });

  // ─── View helpers ─────────────────────────────────────────────────────────
  describe('View helpers', function () {
    it('claimableAmount returns 0 after claim', async function () {
      await airdrop.batchAirdrop([recip1.address], [AMOUNT1]);
      await airdrop.connect(recip1).claim();
      expect(await airdrop.claimableAmount(recip1.address)).to.equal(0n);
    });

    it('remainingUnclaimed decreases after claim', async function () {
      await airdrop.batchAirdrop([recip1.address, recip2.address], [AMOUNT1, AMOUNT2]);
      const before = await airdrop.remainingUnclaimed();
      await airdrop.connect(recip1).claim();
      expect(before - (await airdrop.remainingUnclaimed())).to.equal(AMOUNT1);
    });
  });
});
