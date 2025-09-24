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
      url: 'https://mainnet.infura.io/v3/4fdeb7812b9546b4b9027a9187e82bbc',
      accounts: ['6855591763d1b4166eef0a211fccf52d42ecad8bc792326c64e4281352df6a65'],
      gasPrice: 30000000000, // 30 Gwei
    }
  },
};
