require("@nomicfoundation/hardhat-toolbox");
require('@nomicfoundation/hardhat-ethers');
require('@openzeppelin/hardhat-upgrades');

// ... existing code ...

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: "0.8.28",
  networks: {
    hardhat: {
    },
    sepolia: {
      url: 'https://mainnet.infura.io/v3/key',
      accounts: ['key'],
      gasPrice: 30000000000, // 30 Gwei
    }
  },
};
