const { expect } = require('chai');
const hre = require('hardhat');

describe('NYT Token', function () {
  let ethers;
  let nyt, owner, presale, airdrop, staking, vesting, liquidity, treasury;
  let TOTAL;

  before(async function () {
    ethers = hre.ethers;
  });

  beforeEach(async function () {
    TOTAL = ethers.parseEther('100000000');
    [owner, presale, airdrop, staking, vesting, liquidity, treasury] =
      await ethers.getSigners();

    const NYT = await ethers.getContractFactory('NYT');
    nyt = await NYT.deploy(
      presale.address,
      airdrop.address,
      staking.address,
      vesting.address,
      liquidity.address,
      treasury.address,
    );
    await nyt.waitForDeployment();
  });

  // ── Supply ────────────────────────────────────────────────────────────────
  it('mints exactly 100,000,000 NYT total', async function () {
    expect(await nyt.totalSupply()).to.equal(TOTAL);
  });

  it('distributes 27% to presale contract', async function () {
    const expected = (TOTAL * 2700n) / 10000n;
    expect(await nyt.balanceOf(presale.address)).to.equal(expected);
  });

  it('distributes 18% to airdrop contract', async function () {
    const expected = (TOTAL * 1800n) / 10000n;
    expect(await nyt.balanceOf(airdrop.address)).to.equal(expected);
  });

  it('distributes 18% to staking contract', async function () {
    const expected = (TOTAL * 1800n) / 10000n;
    expect(await nyt.balanceOf(staking.address)).to.equal(expected);
  });

  it('distributes 15% to vesting contract', async function () {
    const expected = (TOTAL * 1500n) / 10000n;
    expect(await nyt.balanceOf(vesting.address)).to.equal(expected);
  });

  it('distributes 15% to liquidity wallet', async function () {
    const expected = (TOTAL * 1500n) / 10000n;
    expect(await nyt.balanceOf(liquidity.address)).to.equal(expected);
  });

  it('distributes 7% to treasury wallet', async function () {
    const expected = (TOTAL * 700n) / 10000n;
    expect(await nyt.balanceOf(treasury.address)).to.equal(expected);
  });

  it('all allocations sum to 100,000,000', async function () {
    const balances = await Promise.all([
      nyt.balanceOf(presale.address),
      nyt.balanceOf(airdrop.address),
      nyt.balanceOf(staking.address),
      nyt.balanceOf(vesting.address),
      nyt.balanceOf(liquidity.address),
      nyt.balanceOf(treasury.address),
    ]);
    const total = balances.reduce((a, b) => a + b, 0n);
    expect(total).to.equal(TOTAL);
  });

  // ── Metadata ──────────────────────────────────────────────────────────────
  it('has name NYTHOS and symbol NYT', async function () {
    expect(await nyt.name()).to.equal('NYTHOS');
    expect(await nyt.symbol()).to.equal('NYT');
  });

  it('has 18 decimals', async function () {
    expect(await nyt.decimals()).to.equal(18);
  });

  // ── Burn ──────────────────────────────────────────────────────────────────
  it('allows anyone to burn their own tokens via burnTokens()', async function () {
    const amount = ethers.parseEther('1000');
    await nyt.connect(presale).burnTokens(amount);
    expect(await nyt.balanceOf(presale.address)).to.equal(
      (TOTAL * 2700n) / 10000n - amount
    );
    expect(await nyt.totalSupply()).to.equal(TOTAL - amount);
  });

  it('emits TokensBurned event on burn', async function () {
    const amount = ethers.parseEther('500');
    await expect(nyt.connect(treasury).burnTokens(amount))
      .to.emit(nyt, 'TokensBurned')
      .withArgs(treasury.address, amount);
  });

  it('reverts burnTokens() if balance is insufficient', async function () {
    const tooMuch = (TOTAL * 700n) / 10000n + 1n;
    await expect(nyt.connect(treasury).burnTokens(tooMuch))
      .to.be.reverted;
  });

  it('has no mint function callable after deploy', async function () {
    expect(nyt.mint).to.be.undefined;
  });

  // ── Immutable addresses ───────────────────────────────────────────────────
  it('stores immutable contract addresses', async function () {
    expect(await nyt.presaleContract()).to.equal(presale.address);
    expect(await nyt.airdropContract()).to.equal(airdrop.address);
    expect(await nyt.stakingContract()).to.equal(staking.address);
    expect(await nyt.teamVesting()).to.equal(vesting.address);
    expect(await nyt.liquidityWallet()).to.equal(liquidity.address);
    expect(await nyt.treasuryWallet()).to.equal(treasury.address);
  });

  // ── Zero address guard ────────────────────────────────────────────────────
  it('reverts constructor if any address is zero', async function () {
    const NYT = await ethers.getContractFactory('NYT');
    await expect(
      NYT.deploy(
        ethers.ZeroAddress,
        airdrop.address,
        staking.address,
        vesting.address,
        liquidity.address,
        treasury.address,
      )
    ).to.be.revertedWith('NYT: zero address');
  });
});
