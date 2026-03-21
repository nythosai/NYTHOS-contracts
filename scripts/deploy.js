// deploy.js — Deploys all NYTHOS contracts in the correct order
// Run:  npx hardhat run scripts/deploy.js --network baseSepolia
// Then: npx hardhat run scripts/deploy.js --network base  (mainnet — after audit)

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

  // ─── Step 1: Deploy NYT with deployer holding all allocations temporarily ─
  // (We need NYTPresale, NYTAirdrop, NYTStaking, NYTVesting addresses before
  //  calling the NYT constructor — so we deploy NYT first with deployer as
  //  a temporary holder, then transfer tokens to each contract after.)
  console.log('1. Deploying NYT token...');
  const NYT = await ethers.getContractFactory('NYT');
  const nyt = await NYT.deploy(
    deployer.address,  // presale placeholder
    deployer.address,  // airdrop placeholder
    deployer.address,  // staking placeholder
    deployer.address,  // vesting placeholder
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
  // ETH price: set to $2,000 = 200000 USD cents. Update before mainnet deploy.
  const ETH_PRICE_USD_CENTS = process.env.ETH_PRICE_USD_CENTS
    ? parseInt(process.env.ETH_PRICE_USD_CENTS)
    : 200000; // $2,000 default

  console.log('3. Deploying NYTPresale...');
  console.log('   ETH price used:', '$' + (ETH_PRICE_USD_CENTS / 100).toLocaleString());
  const NYTPresale = await ethers.getContractFactory('NYTPresale');
  const presale = await NYTPresale.deploy(nytAddr, ETH_PRICE_USD_CENTS);
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

  // ─── Step 6: Transfer allocations to actual contracts ─────────────────────
  console.log('\n6. Transferring token allocations to contracts...');

  const TOTAL        = 100_000_000n * 10n ** 18n;
  const presaleAlloc = (TOTAL * 2700n) / 10000n;  // 27M NYT (private + IDO + public)
  const airdropAlloc = (TOTAL * 1800n) / 10000n;  // 18M NYT
  const stakingAlloc = (TOTAL * 1800n) / 10000n;  // 18M NYT (ecosystem & rewards)
  const teamAlloc    = (TOTAL * 1500n) / 10000n;  // 15M NYT

  await (await nyt.transfer(presaleAddr, presaleAlloc)).wait();
  console.log('   Presale:  ', ethers.formatEther(presaleAlloc), 'NYT →', presaleAddr);

  await (await nyt.transfer(airdropAddr, airdropAlloc)).wait();
  console.log('   Airdrop:  ', ethers.formatEther(airdropAlloc), 'NYT →', airdropAddr);

  await (await nyt.transfer(stakingAddr, stakingAlloc)).wait();
  console.log('   Staking:  ', ethers.formatEther(stakingAlloc), 'NYT →', stakingAddr);

  await (await nyt.transfer(vestingAddr, teamAlloc)).wait();
  console.log('   Vesting:  ', ethers.formatEther(teamAlloc),    'NYT →', vestingAddr);

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
  console.log('║  27M NYT → NYTPresale  (private+IDO+public)     ║');
  console.log('║  18M NYT → NYTAirdrop  (community airdrop)      ║');
  console.log('║  18M NYT → NYTStaking  (ecosystem & rewards)    ║');
  console.log('║  15M NYT → NYTVesting  (team, 1yr cliff)        ║');
  console.log('║  15M NYT → Liquidity wallet                     ║');
  console.log('║   7M NYT → Treasury wallet                      ║');
  console.log('╠══════════════════════════════════════════════════╣');
  console.log('║ NEXT STEPS                                       ║');
  console.log('║  1. Verify on Basescan:                         ║');
  console.log('║     npx hardhat verify --network baseSepolia    ║');
  console.log('║  2. Open private sale:                          ║');
  console.log('║     presale.openRound(0)                        ║');
  console.log('║  3. Add whitelist wallets:                      ║');
  console.log('║     presale.addToWhitelist([...addresses])      ║');
  console.log('║  4. Keep ETH price updated:                     ║');
  console.log('║     presale.setEthPrice(priceInUSDCents)        ║');
  console.log('║  5. Save all addresses above in your .env!      ║');
  console.log('╚══════════════════════════════════════════════════╝');

  // Machine-readable output for copy-paste into .env
  console.log('\n── Copy into your .env ──');
  console.log(`NYT_CONTRACT_ADDRESS=${nytAddr}`);
  console.log(`NYT_PRESALE_ADDRESS=${presaleAddr}`);
  console.log(`NYT_STAKING_ADDRESS=${stakingAddr}`);
  console.log(`NYT_VESTING_ADDRESS=${vestingAddr}`);
  console.log(`NYT_AIRDROP_ADDRESS=${airdropAddr}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
