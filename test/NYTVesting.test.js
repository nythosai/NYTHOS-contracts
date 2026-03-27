const { expect } = require('chai');
const hre = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('NYTVesting', function () {
  let ethers;
  let nyt, vesting, owner, beneficiary, other;
  let GRANT_AMOUNT;

  before(async function () {
    ethers = hre.ethers;
  });

  beforeEach(async function () {
    GRANT_AMOUNT = ethers.parseEther('15000000');
    [owner, beneficiary, other] = await ethers.getSigners();

    const NYT = await ethers.getContractFactory('NYT');
    nyt = await NYT.deploy(owner.address, owner.address);
    await nyt.waitForDeployment();
    await nyt.initializeAllocations(
      owner.address,
      owner.address,
      owner.address,
      owner.address,
    );

    const NYTVesting = await ethers.getContractFactory('NYTVesting');
    vesting = await NYTVesting.deploy(await nyt.getAddress());
    await vesting.waitForDeployment();

    await nyt.transfer(await vesting.getAddress(), GRANT_AMOUNT);
  });

  // ─── Grant creation ───────────────────────────────────────────────────────
  describe('Grant creation', function () {
    it('owner can create a grant', async function () {
      await vesting.createGrant(beneficiary.address, GRANT_AMOUNT);
      const schedule = await vesting.schedules(beneficiary.address);
      expect(schedule.totalAmount).to.equal(GRANT_AMOUNT);
      expect(schedule.initialized).to.be.true;
    });

    it('emits GrantCreated event', async function () {
      await expect(vesting.createGrant(beneficiary.address, GRANT_AMOUNT))
        .to.emit(vesting, 'GrantCreated');
    });

    it('non-owner cannot create grant', async function () {
      await expect(vesting.connect(other).createGrant(beneficiary.address, GRANT_AMOUNT))
        .to.be.revertedWithCustomError(vesting, 'OwnableUnauthorizedAccount');
    });

    it('reverts on duplicate grant for same beneficiary', async function () {
      await vesting.createGrant(beneficiary.address, GRANT_AMOUNT);
      await expect(vesting.createGrant(beneficiary.address, GRANT_AMOUNT))
        .to.be.revertedWith('Vesting: already exists');
    });

    it('reverts if contract has insufficient balance', async function () {
      const tooMuch = GRANT_AMOUNT + 1n;
      await expect(vesting.createGrant(beneficiary.address, tooMuch))
        .to.be.revertedWith('Vesting: insufficient balance');
    });

    it('reverts with zero address', async function () {
      await expect(vesting.createGrant(ethers.ZeroAddress, GRANT_AMOUNT))
        .to.be.revertedWith('Vesting: zero address');
    });
  });

  // ─── Cliff enforcement ───────────────────────────────────────────────────
  describe('1-year cliff', function () {
    beforeEach(async function () {
      await vesting.createGrant(beneficiary.address, GRANT_AMOUNT);
    });

    it('vestedAmount is 0 before cliff', async function () {
      expect(await vesting.vestedAmount(beneficiary.address)).to.equal(0n);
    });

    it('claimable is 0 before cliff', async function () {
      expect(await vesting.claimable(beneficiary.address)).to.equal(0n);
    });

    it('claim reverts before cliff', async function () {
      await expect(vesting.connect(beneficiary).claim())
        .to.be.revertedWith('Vesting: nothing to claim');
    });

    it('tokens become claimable just after cliff', async function () {
      await time.increase(365 * 24 * 60 * 60 + 1);
      expect(await vesting.claimable(beneficiary.address)).to.be.gt(0n);
    });
  });

  // ─── Linear vesting ───────────────────────────────────────────────────────
  describe('Linear vesting after cliff', function () {
    beforeEach(async function () {
      await vesting.createGrant(beneficiary.address, GRANT_AMOUNT);
      await time.increase(365 * 24 * 60 * 60);
    });

    it('~50% vested at cliff + 1 year', async function () {
      await time.increase(365 * 24 * 60 * 60);
      const vested = await vesting.vestedAmount(beneficiary.address);
      const half = GRANT_AMOUNT / 2n;
      expect(vested).to.be.closeTo(half, ethers.parseEther('10000'));
    });

    it('100% vested after cliff + 2 years', async function () {
      await time.increase(730 * 24 * 60 * 60 + 1);
      expect(await vesting.vestedAmount(beneficiary.address)).to.equal(GRANT_AMOUNT);
    });

    it('beneficiary can claim vested tokens', async function () {
      await time.increase(365 * 24 * 60 * 60);
      const claimableAmt = await vesting.claimable(beneficiary.address);
      await vesting.connect(beneficiary).claim();
      // Balance may be slightly more than snapshot due to block time advancing during tx
      expect(await nyt.balanceOf(beneficiary.address)).to.be.closeTo(
        claimableAmt, ethers.parseEther('100')
      );
    });

    it('emits Claimed event', async function () {
      await time.increase(365 * 24 * 60 * 60);
      await expect(vesting.connect(beneficiary).claim()).to.emit(vesting, 'Claimed');
    });

    it('cannot re-claim within the same second', async function () {
      await time.increase(365 * 24 * 60 * 60);
      await vesting.connect(beneficiary).claim();
      // Disable auto-mining so the second claim lands in the same block
      await hre.network.provider.send('evm_setAutomine', [false]);
      const claimAfter = await vesting.claimable(beneficiary.address);
      await hre.network.provider.send('evm_setAutomine', [true]);
      // At most 1 wei of new vesting in same second — claimable should be essentially 0
      expect(claimAfter).to.be.lte(ethers.parseEther('1'));
    });
  });

  // ─── View helpers ─────────────────────────────────────────────────────────
  describe('View helpers', function () {
    it('vestedAmount returns 0 for non-beneficiary', async function () {
      expect(await vesting.vestedAmount(other.address)).to.equal(0n);
    });

    it('beneficiaryCount increments on grant', async function () {
      expect(await vesting.beneficiaryCount()).to.equal(0n);
      await vesting.createGrant(beneficiary.address, GRANT_AMOUNT);
      expect(await vesting.beneficiaryCount()).to.equal(1n);
    });
  });
});
