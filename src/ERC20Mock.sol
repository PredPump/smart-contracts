// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract ERC20Mock is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    // Override transfer to allow testing of failed transfers
    function setTransferShouldRevert(bool shouldRevert) external {
        _transferShouldRevert = shouldRevert;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (_transferShouldRevert) {
            revert("ERC20Mock: transfer reverted");
        }
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (_transferShouldRevert) {
            revert("ERC20Mock: transferFrom reverted");
        }
        return super.transferFrom(from, to, amount);
    }

    // Internal state
    bool private _transferShouldRevert;
}
