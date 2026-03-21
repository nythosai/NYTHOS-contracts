const { expect } = require('chai');
const hre = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('NYTPresale', function () {
  let ethers;
  let nyt, presale, owner, buyer, buyer2, whitelisted;

  before(async function () {
    ethers = hre.ethers;
  });

  beforeEach(async function () {
    [owner, buyer, buyer2, whitelisted] = await ethers.getSigners();

    const NYT = await ethers.getContractFactory('NYT');
    nyt = await NYT.deploy(
      owner.address, owner.address, owner.address,
      owner.address, owner.address, owner.address,
    );
    await nyt.waitForDeployment();

    const NYTPresale = await ethers.getContractFactory('NYTPresale');
    presale = await NYTPresale.deploy(await nyt.getAddress(), 200000); // $2,000/ETH
    await presale.waitForDeployment();

    // Fund presale contract with 27M NYT
    await nyt.transfer(await presale.getAddress(), ethers.parseEther('27000000'));
  });

  // ─── Round management ─────────────────────────────────────────────────────
  describe('Round management', function () {
    it('starts with sale closed', async function () {
      expect(await presale.saleOpen()).to.be.false;
    });

    it('owner can open a round', async function () {
      await presale.openRound(0);
      expect(await presale.saleOpen()).to.be.true;
      expect(await presale.currentRound()).to.equal(0);
    });

    it('owner can close sale', async function () {
      await presale.openRound(0);
      await presale.closeSale();
      expect(await presale.saleOpen()).to.be.false;
    });

    it('non-owner cannot open round', async function () {
      await expect(presale.connect(buyer).openRound(0))
        .to.be.revertedWithCustomError(presale, 'OwnableUnauthorizedAccount');
    });
  });

  // ─── Whitelist ────────────────────────────────────────────────────────────
  describe('Whitelist', function () {
    it('owner adds to whitelist', async function () {
      await presale.addToWhitelist([whitelisted.address]);
      expect(await presale.whitelist(whitelisted.address)).to.be.true;
    });

    it('owner removes from whitelist', async function () {
      await presale.addToWhitelist([whitelisted.address]);
      await presale.removeFromWhitelist([whitelisted.address]);
      expect(await presale.whitelist(whitelisted.address)).to.be.false;
    });

    it('non-whitelisted buyer cannot buy in private round', async function () {
      await presale.openRound(0);
      await expect(presale.connect(buyer).buy({ value: ethers.parseEther('0.1') }))
        .to.be.revertedWith('Presale: not whitelisted');
    });

    it('whitelisted buyer can buy in private round', async function () {
      await presale.addToWhitelist([buyer.address]);
      await presale.openRound(0);
      await expect(presale.connect(buyer).buy({ value: ethers.parseEther('0.1') }))
        .to.not.be.reverted;
    });
  });

  // ─── Buying ───────────────────────────────────────────────────────────────
  describe('Buying', function () {
    beforeEach(async function () {
      await presale.openRound(1); // IDO — open to all
    });

    it('reverts if sale not open', async function () {
      await presale.closeSale();
      await expect(presale.connect(buyer).buy({ value: ethers.parseEther('0.1') }))
        .to.be.revertedWith('Presale: sale not open');
    });

    it('reverts with zero ETH', async function () {
      await expect(presale.connect(buyer).buy({ value: 0n }))
        .to.be.revertedWith('Presale: zero ETH');
    });

    it('records correct NYT amount for buyer', async function () {
      // 0.1 ETH × $2,000 = $200 / $0.008 per NYT = 25,000 NYT
      await presale.connect(buyer).buy({ value: ethers.parseEther('0.1') });
      expect(await presale.nytPurchased(buyer.address)).to.equal(ethers.parseEther('25000'));
    });

    it('accumulates ETH paid for buyer', async function () {
      const ethIn = ethers.parseEther('0.1');
      await presale.connect(buyer).buy({ value: ethIn });
      expect(await presale.ethPaid(buyer.address)).to.equal(ethIn);
    });

    it('records which round buyer participated in', async function () {
      await presale.connect(buyer).buy({ value: ethers.parseEther('0.1') });
      expect(await presale.buyerRound(buyer.address)).to.equal(1); // IDO
    });
  });

  // ─── ETH price oracle ─────────────────────────────────────────────────────
  describe('ETH price oracle', function () {
    it('owner can update ETH price', async function () {
      await presale.setEthPrice(300000);
      expect(await presale.ethPriceUSD()).to.equal(300000n);
    });

    it('emits EthPriceUpdated event', async function () {
      await expect(presale.setEthPrice(300000))
        .to.emit(presale, 'EthPriceUpdated')
        .withArgs(300000n);
    });

    it('reverts if price too low', async function () {
      await expect(presale.setEthPrice(5000))
        .to.be.revertedWith('Presale: price too low');
    });

    it('reverts if price too high', async function () {
      await expect(presale.setEthPrice(200_000_001n))
        .to.be.revertedWith('Presale: price too high');
    });

    it('non-owner cannot set ETH price', async function () {
      await expect(presale.connect(buyer).setEthPrice(300000))
        .to.be.revertedWithCustomError(presale, 'OwnableUnauthorizedAccount');
    });
  });

  // ─── Finalize + Claim ─────────────────────────────────────────────────────
  describe('Finalize and claim', function () {
    beforeEach(async function () {
      // Set high ETH price to hit soft cap easily in tests
      // $200,000/ETH: 0.5 ETH = $100,000 = exactly soft cap
      await presale.setEthPrice(20000000);
      await presale.openRound(1); // IDO
      await presale.connect(buyer).buy({ value: ethers.parseEther('0.5') });
    });

    it('owner can finalize', async function () {
      await presale.closeSale();
      await presale.finalize();
      expect(await presale.finalized()).to.be.true;
    });

    it('softCapReached is true when enough raised', async function () {
      await presale.closeSale();
      await presale.finalize();
      expect(await presale.softCapReached()).to.be.true;
    });

    it('IDO buyer can claim immediately after finalize', async function () {
      await presale.closeSale();
      await presale.finalize();
      const amount = await presale.nytPurchased(buyer.address);
      await presale.connect(buyer).claim();
      expect(await nyt.balanceOf(buyer.address)).to.equal(amount);
    });

    it('cannot claim before finalize', async function () {
      await expect(presale.connect(buyer).claim())
        .to.be.revertedWith('Presale: not finalized');
    });
  });

  // ─── 30-day cliff for public round ───────────────────────────────────────
  describe('Public sale 30-day cliff', function () {
    // buyer2 buys in IDO to exceed soft cap, buyer buys in PUBLIC for cliff testing
    beforeEach(async function () {
      await presale.setEthPrice(20000000); // $200,000/ETH

      // Step 1: IDO round — buyer2 buys enough to exceed soft cap ($100k)
      await presale.openRound(1); // IDO
      await presale.connect(buyer2).buy({ value: ethers.parseEther('0.5') }); // $100k in IDO

      // Step 2: Public round — buyer buys (subject to 30-day cliff)
      await presale.openRound(2); // PUBLIC
      await presale.connect(buyer).buy({ value: ethers.parseEther('0.1') }); // $20k in PUBLIC

      await presale.closeSale();
      await presale.finalize();
    });

    it('public buyer cannot claim before 30 days', async function () {
      await expect(presale.connect(buyer).claim())
        .to.be.revertedWith('Presale: 30-day cliff not yet passed');
    });

    it('public buyer can claim after 30 days', async function () {
      await time.increase(30 * 24 * 60 * 60 + 1);
      const amount = await presale.nytPurchased(buyer.address);
      await presale.connect(buyer).claim();
      expect(await nyt.balanceOf(buyer.address)).to.equal(amount);
    });

    it('IDO buyer (non-public) can claim immediately after finalize', async function () {
      const amount = await presale.nytPurchased(buyer2.address);
      await presale.connect(buyer2).claim();
      expect(await nyt.balanceOf(buyer2.address)).to.equal(amount);
    });
  });

  // ─── Refund ───────────────────────────────────────────────────────────────
  describe('Refund when soft cap not reached', function () {
    it('buyer can refund if soft cap not reached', async function () {
      await presale.openRound(1);
      const ethIn = ethers.parseEther('0.1');
      await presale.connect(buyer).buy({ value: ethIn });
      await presale.closeSale();
      await presale.finalize();

      expect(await presale.softCapReached()).to.be.false;

      const balBefore = await ethers.provider.getBalance(buyer.address);
      const tx = await presale.connect(buyer).refund();
      const receipt = await tx.wait();
      const gasUsed = receipt.gasUsed * receipt.gasPrice;
      const balAfter = await ethers.provider.getBalance(buyer.address);

      expect(balAfter + gasUsed).to.be.closeTo(balBefore + ethIn, ethers.parseEther('0.001'));
    });

    it('cannot claim if soft cap not reached', async function () {
      await presale.openRound(1);
      await presale.connect(buyer).buy({ value: ethers.parseEther('0.1') });
      await presale.closeSale();
      await presale.finalize();
      await expect(presale.connect(buyer).claim())
        .to.be.revertedWith('Presale: soft cap not reached, use refund()');
    });
  });

  // ─── View helpers ─────────────────────────────────────────────────────────
  describe('View helpers', function () {
    it('totalSold() sums all rounds', async function () {
      await presale.openRound(1);
      await presale.connect(buyer).buy({ value: ethers.parseEther('0.1') });
      const sold = await presale.totalSold();
      expect(sold).to.equal(await presale.nytPurchased(buyer.address));
    });
  });
});
