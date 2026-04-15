// deploy.js - Deploys the NYTHOS Base contract stack in the current recommended order
// Run:  npx hardhat run scripts/deploy.js --network baseSepolia
// Then: npx hardhat run scripts/deploy.js --network base  (mainnet - after audit)

const hre = require('hardhat');
const { ethers } = hre;

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log('\n=== NYTHOS Contract Deployment ===');
  console.log('Deployer:', deployer.address);
  console.log('Network: ', hre.network.name);
  console.log('Balance: ', ethers.formatEther(await ethers.provider.getBalance(deployer.address)), 'ETH\n');

  // ─── Wallet addresses ─────────────────────────────────────────────────────
  // Replace deployer.address with your actual multisig/team wallet on mainnet
  const TEAM_WALLET      = process.env.TEAM_WALLET      || deployer.address;
  const LIQUIDITY_WALLET = process.env.LIQUIDITY_WALLET || deployer.address;
  const TREASURY_WALLET  = process.env.TREASURY_WALLET  || deployer.address;

  console.log('Team wallet:      ', TEAM_WALLET);
  console.log('Liquidity wallet: ', LIQUIDITY_WALLET);
  console.log('Treasury wallet:  ', TREASURY_WALLET);
  console.log('');

  // ─── Step 1: Deploy NYT shell ──────────────────────────────────────────────
  // NYT mints the fixed supply to itself, then initializes the real allocation
  // recipients once the dependent contracts are deployed.
  console.log('1. Deploying NYT token...');
  const NYT = await ethers.getContractFactory('NYT');
  const nyt = await NYT.deploy(
    LIQUIDITY_WALLET,  // goes directly to liquidity wallet
    TREASURY_WALLET,   // goes directly to treasury wallet
  );
  await nyt.waitForDeployment();
  const nytAddr = await nyt.getAddress();
  console.log('   NYT deployed:', nytAddr);

  // ─── Step 2: Deploy NYTVesting ─────────────────────────────────────────────
  console.log('2. Deploying NYTVesting...');
  const NYTVesting = await ethers.getContractFactory('NYTVesting');
  const vesting = await NYTVesting.deploy(nytAddr);
  await vesting.waitForDeployment();
  const vestingAddr = await vesting.getAddress();
  console.log('   NYTVesting deployed:', vestingAddr);

  // ─── Step 3: Deploy NYTPresale ─────────────────────────────────────────────
  // Chainlink ETH/USD feed addresses:
  //   Base mainnet:  0x71041dddad3595F9CEd3dCCFBe3D1F4b0a16Bb70
  //   Base Sepolia:  0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1
  const CHAINLINK_FEEDS = {
    base:        '0x71041dddad3595F9CEd3dCCFBe3D1F4b0a16Bb70',
    baseSepolia: '0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1',
  };
  const ETH_USD_FEED = process.env.ETH_USD_FEED
    || CHAINLINK_FEEDS[hre.network.name]
    || CHAINLINK_FEEDS.baseSepolia;

  // Manual fallback price in USD cents - used only if Chainlink feed is stale (>2h).
  // Formula: actual_eth_price_usd × 100 = value to pass in.
  const ETH_PRICE_USD_CENTS = process.env.ETH_PRICE_USD_CENTS
    ? parseInt(process.env.ETH_PRICE_USD_CENTS)
    : 200000; // $2,000 default

  console.log('3. Deploying NYTPresale...');
  console.log('   Chainlink ETH/USD feed:', ETH_USD_FEED);
  console.log('   Manual fallback price: $' + (ETH_PRICE_USD_CENTS / 100).toLocaleString());
  const NYTPresale = await ethers.getContractFactory('NYTPresale');
  const presale = await NYTPresale.deploy(nytAddr, ETH_USD_FEED, ETH_PRICE_USD_CENTS);
  await presale.waitForDeployment();
  const presaleAddr = await presale.getAddress();
  console.log('   NYTPresale deployed:', presaleAddr);

  // ─── Step 4: Deploy NYTStaking ─────────────────────────────────────────────
  console.log('4. Deploying NYTStaking...');
  const NYTStaking = await ethers.getContractFactory('NYTStaking');
  const staking = await NYTStaking.deploy(nytAddr);
  await staking.waitForDeployment();
  const stakingAddr = await staking.getAddress();
  console.log('   NYTStaking deployed:', stakingAddr);

  // ─── Step 5: Deploy NYTAirdrop ─────────────────────────────────────────────
  console.log('5. Deploying NYTAirdrop...');
  const NYTAirdrop = await ethers.getContractFactory('NYTAirdrop');
  const airdrop = await NYTAirdrop.deploy(nytAddr);
  await airdrop.waitForDeployment();
  const airdropAddr = await airdrop.getAddress();
  console.log('   NYTAirdrop deployed:', airdropAddr);

  // ─── Step 6: Initialize live allocation map ────────────────────────────────
  console.log('\n6. Initializing NYT allocations...');
  await (await nyt.initializeAllocations(
    presaleAddr,
    airdropAddr,
    stakingAddr,
    vestingAddr,
  )).wait();
  console.log('   Presale:   27,000,000 NYT →', presaleAddr);
  console.log('   Airdrop:   18,000,000 NYT →', airdropAddr);
  console.log('   Staking:   18,000,000 NYT →', stakingAddr);
  console.log('   Vesting:   15,000,000 NYT →', vestingAddr);

  const TOTAL     = 100_000_000n * 10n ** 18n;
  const teamAlloc = (TOTAL * 1500n) / 10000n;  // 15M NYT

  // ─── Step 7: Create vesting grant for team wallet ─────────────────────────
  console.log('\n7. Creating team vesting grant...');
  await (await vesting.createGrant(TEAM_WALLET, teamAlloc)).wait();
  console.log('   Grant created for:', TEAM_WALLET);
  console.log('   Amount:', ethers.formatEther(teamAlloc), 'NYT');
  console.log('   Cliff: 1 year · Vest: 2 years linear');

  // ─── Summary ──────────────────────────────────────────────────────────────
  console.log('\n╔══════════════════════════════════════════════════╗');
  console.log('║          DEPLOYMENT COMPLETE                     ║');
  console.log('╠══════════════════════════════════════════════════╣');
  console.log('║ NYT Token:     ', nytAddr);
  console.log('║ NYTPresale:    ', presaleAddr);
  console.log('║ NYTStaking:    ', stakingAddr);
  console.log('║ NYTVesting:    ', vestingAddr);
  console.log('║ NYTAirdrop:    ', airdropAddr);
  console.log('╠══════════════════════════════════════════════════╣');
  console.log('║ ALLOCATION SUMMARY                               ║');
  console.log('║  27M NYT → NYTPresale  (founder+early+public)   ║');
  console.log('║  18M NYT → NYTAirdrop  (community airdrop)      ║');
  console.log('║  18M NYT → NYTStaking  (ecosystem & rewards)    ║');
  console.log('║  15M NYT → NYTVesting  (team, 1yr cliff)        ║');
  console.log('║  15M NYT → Liquidity wallet                     ║');
  console.log('║   7M NYT → Treasury wallet                      ║');
  console.log('╠══════════════════════════════════════════════════╣');
  console.log('║ NEXT STEPS                                       ║');
  console.log('║  1. Verify on Basescan:                         ║');
  console.log('║     npx hardhat verify --network baseSepolia    ║');
  console.log('║  2. Save all addresses above in app/env config  ║');
  console.log('║  3. ETH price sourced from Chainlink feed.      ║');
  console.log('║     setEthPrice() is now a manual fallback only ║');
  console.log('║     used if Chainlink is stale (>2h). No need  ║');
  console.log('║     to call it regularly in normal operation.   ║');
  console.log('║  4. If using round 0, seed founder allowlist:   ║');
  console.log('║     presale.addToWhitelist([...addresses])      ║');
  console.log('║  5. Keep sale closed until docs/audit are ready ║');
  console.log('║  6. Open a round only when launch timing is set ║');
  console.log('╚══════════════════════════════════════════════════╝');

  // Machine-readable output for copy-paste into .env
  console.log('\n── Copy into your .env ──');
  console.log(`NYT_TOKEN_ADDRESS=${nytAddr}`);
  console.log(`NYT_CONTRACT_ADDRESS=${nytAddr}`);
  console.log(`NYT_PRESALE_ADDRESS=${presaleAddr}`);
  console.log(`NYT_STAKING_ADDRESS=${stakingAddr}`);
  console.log(`NYT_VESTING_ADDRESS=${vestingAddr}`);
  console.log(`NYT_AIRDROP_ADDRESS=${airdropAddr}`);

  console.log('\n── Copy into NYTHOS-app/.env ──');
  console.log(`VITE_NYT_ADDRESS=${nytAddr}`);
  console.log(`VITE_NYT_PRESALE_ADDRESS=${presaleAddr}`);
  console.log(`VITE_NYT_STAKING_ADDRESS=${stakingAddr}`);
  console.log(`VITE_NYT_VESTING_ADDRESS=${vestingAddr}`);
  console.log(`VITE_NYT_AIRDROP_ADDRESS=${airdropAddr}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
