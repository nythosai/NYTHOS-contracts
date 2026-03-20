// deploy.js — Deploys all NYTHOS contracts in the correct order
// Run:  npx hardhat run scripts/deploy.js --network baseSepolia
// Then: npx hardhat run scripts/deploy.js --network base  (mainnet)

const hre = require('hardhat');
const { ethers } = hre;

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log('\n=== NYTHOS Contract Deployment ===');
  console.log('Deployer:', deployer.address);
  console.log('Network: ', hre.network.name);
  console.log('Balance: ', ethers.formatEther(await ethers.provider.getBalance(deployer.address)), 'ETH\n');

  // ─── 1. Deploy NYTVesting (needs no args except NYT address — deploy first as placeholder)
  // We'll deploy vesting before NYT, so we use a two-step approach:
  // Deploy NYT last (it needs all contract addresses), so deploy placeholder wallets first.

  // For simplicity: use deployer address as placeholder for wallets
  // In production: replace with multisig / real team wallet addresses

  const TEAM_WALLET       = deployer.address;  // replace with real team multisig
  const LIQUIDITY_WALLET  = deployer.address;  // replace with real liquidity wallet
  const ECOSYSTEM_WALLET  = deployer.address;
  const MARKETING_WALLET  = deployer.address;
  const AIRDROP_WALLET    = deployer.address;  // will be replaced by NYTAirdrop contract

  // ─── 2. Deploy NYTVesting ─────────────────────────────────────────────────
  // We need to pass a token address — but NYT isn't deployed yet.
  // Solution: Deploy vesting + other contracts first with a dummy, then replace.
  // Easier: deploy NYT with deployer address for vesting/airdrop/staking/presale,
  //         then transfer tokens to actual contracts after.

  // Step 1: Deploy Vesting (needs NYT address — will be set after NYT deploy)
  // We use a simple 2-step: deploy NYT first with deployer as all recipients,
  // then deploy the other contracts and transfer tokens to them.

  // ─── Deploy NYT with deployer holding all allocations temporarily ─────────
  console.log('1. Deploying NYT token...');
  const NYT = await ethers.getContractFactory('NYT');
  const nyt = await NYT.deploy(
    deployer.address,  // presale — will transfer to NYTPresale later
    deployer.address,  // staking — will transfer to NYTStaking later
    deployer.address,  // team vesting — will transfer to NYTVesting later
    LIQUIDITY_WALLET,
    ECOSYSTEM_WALLET,
    MARKETING_WALLET,
    deployer.address,  // airdrop — will transfer to NYTAirdrop later
  );
  await nyt.waitForDeployment();
  const nytAddr = await nyt.getAddress();
  console.log('   NYT deployed:', nytAddr);

  // ─── Deploy NYTVesting ────────────────────────────────────────────────────
  console.log('2. Deploying NYTVesting...');
  const NYTVesting = await ethers.getContractFactory('NYTVesting');
  const vesting = await NYTVesting.deploy(nytAddr);
  await vesting.waitForDeployment();
  const vestingAddr = await vesting.getAddress();
  console.log('   NYTVesting deployed:', vestingAddr);

  // ─── Deploy NYTPresale ────────────────────────────────────────────────────
  console.log('3. Deploying NYTPresale...');
  const NYTPresale = await ethers.getContractFactory('NYTPresale');
  // ETH price: $2,000 = 200000 USD cents (update before deploy on mainnet)
  const presale = await NYTPresale.deploy(nytAddr, 200000);
  await presale.waitForDeployment();
  const presaleAddr = await presale.getAddress();
  console.log('   NYTPresale deployed:', presaleAddr);

  // ─── Deploy NYTStaking ────────────────────────────────────────────────────
  console.log('4. Deploying NYTStaking...');
  const NYTStaking = await ethers.getContractFactory('NYTStaking');
  const staking = await NYTStaking.deploy(nytAddr);
  await staking.waitForDeployment();
  const stakingAddr = await staking.getAddress();
  console.log('   NYTStaking deployed:', stakingAddr);

  // ─── Deploy NYTAirdrop ────────────────────────────────────────────────────
  console.log('5. Deploying NYTAirdrop...');
  const NYTAirdrop = await ethers.getContractFactory('NYTAirdrop');
  const airdrop = await NYTAirdrop.deploy(nytAddr);
  await airdrop.waitForDeployment();
  const airdropAddr = await airdrop.getAddress();
  console.log('   NYTAirdrop deployed:', airdropAddr);

  // ─── Transfer allocations to actual contracts ─────────────────────────────
  console.log('\n6. Transferring token allocations...');

  const TOTAL = 100_000_000n * 10n ** 18n;
  const presaleAlloc  = (TOTAL * 4000n) / 10000n;  // 40M NYT
  const stakingAlloc  = (TOTAL * 2000n) / 10000n;  // 20M NYT
  const teamAlloc     = (TOTAL * 1500n) / 10000n;  // 15M NYT
  const airdropAlloc  = (TOTAL *  200n) / 10000n;  //  2M NYT

  await (await nyt.transfer(presaleAddr,  presaleAlloc)).wait();
  console.log('   Presale allocation sent:', ethers.formatEther(presaleAlloc), 'NYT');

  await (await nyt.transfer(stakingAddr,  stakingAlloc)).wait();
  console.log('   Staking allocation sent:', ethers.formatEther(stakingAlloc), 'NYT');

  await (await nyt.transfer(vestingAddr,  teamAlloc)).wait();
  console.log('   Vesting allocation sent:', ethers.formatEther(teamAlloc), 'NYT');

  await (await nyt.transfer(airdropAddr,  airdropAlloc)).wait();
  console.log('   Airdrop allocation sent:', ethers.formatEther(airdropAlloc), 'NYT');

  // ─── Create vesting grant for team ───────────────────────────────────────
  // Grant the full team allocation to the team wallet
  await (await vesting.createGrant(TEAM_WALLET, teamAlloc)).wait();
  console.log('   Team vesting grant created for:', TEAM_WALLET);

  // ─── Summary ──────────────────────────────────────────────────────────────
  console.log('\n=== Deployment Complete ===');
  console.log('NYT Token:   ', nytAddr);
  console.log('NYTVesting:  ', vestingAddr);
  console.log('NYTPresale:  ', presaleAddr);
  console.log('NYTStaking:  ', stakingAddr);
  console.log('NYTAirdrop:  ', airdropAddr);
  console.log('\nNext steps:');
  console.log('  1. Verify contracts on Basescan');
  console.log('  2. Open presale round: presale.openRound(0)  // 0=PRIVATE');
  console.log('  3. Add wallets to whitelist: presale.addToWhitelist([...])');
  console.log('  4. Update ETH price oracle regularly: presale.setEthPrice(...)');
  console.log('  5. Load airdrop recipients: airdrop.batchAirdrop([...], [...])');
  console.log('  6. Deposit revenue to staking: staking.depositRevenue({value: ...})');
  console.log('\nSave these addresses — you will need them in the app!');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
