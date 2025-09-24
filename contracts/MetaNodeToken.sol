// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';

contract MetaNodeToken is ERC20 {
    constructor() ERC20('MetaNode', 'META') {
        _mint(msg.sender, 5000 * 10 ** 18);
    }
}
