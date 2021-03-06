// SPDX-License-Identifier: GPL-3.0-or-later
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity ^0.8.0;

import '@mimic-fi/v1-vault/contracts/interfaces/IStrategy.sol';
import '@mimic-fi/v1-vault/contracts/interfaces/ISwapConnector.sol';
import '@mimic-fi/v1-vault/contracts/interfaces/IPriceOracle.sol';
import '@mimic-fi/v1-vault/contracts/interfaces/IVault.sol';
import '@mimic-fi/v1-vault/contracts/libraries/FixedPoint.sol';

import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import '@openzeppelin/contracts/utils/math/SafeMath.sol';

import './aave/ILendingPool.sol';

/**
 * @title AaveStrategy
 * @dev This strategy invests tokens in AAVE lending pools, obtaining aTokens in exchange to accrue value over time
 */
contract AaveStrategy is IStrategy, Ownable {
    using SafeERC20 for IERC20;
    using FixedPoint for uint256;

    // Max value in order to cap the slippage config: 10%
    uint256 private constant MAX_SLIPPAGE = 10e16;

    // Min value in order to limit the amount of token rewards to be swapped in the strategy: 10 wei
    uint256 private constant SWAP_THRESHOLD = 10;

    // Precision value used by Mimic's Vault to avoid rounding errors
    uint256 private constant VAULT_EXIT_RATIO_PRECISION = 1e18;

    /**
     * @dev Emitted every time a new slippage value is set
     */
    event SetSlippage(uint256 slippage);

    // Mimic Vault reference
    IVault internal immutable _vault;

    // Token that will be used as the strategy entry point
    IERC20 internal immutable _token;

    // aToken associated to the strategy token
    IERC20 internal immutable _aToken;

    // AAVE lending pool to invest the strategy tokens
    ILendingPool internal immutable _lendingPool;

    uint256 private _slippage;
    string private _metadataURI;

    /**
     * @dev Used to mark functions that can only be called by the protocol vault
     */
    modifier onlyVault() {
        require(address(_vault) == msg.sender, 'CALLER_IS_NOT_VAULT');
        _;
    }

    /**
     * @dev Initializes the AAVE strategy contract
     * @param vault Protocol vault reference
     * @param token Token to be used as the strategy entry point
     * @param aToken aToken associated to the strategy token
     * @param lendingPool AAVE lending pool to be used
     * @param slippage Slippage value to be used in order to swap rewards
     * @param metadataURI Metadata URI associated to the strategy
     */
    constructor(
        IVault vault,
        IERC20 token,
        IERC20 aToken,
        ILendingPool lendingPool,
        uint256 slippage,
        string memory metadataURI
    ) {
        _vault = vault;
        _token = token;
        _aToken = aToken;
        _lendingPool = lendingPool;
        _setSlippage(slippage);
        _setMetadataURI(metadataURI);
    }

    /**
     * @dev Tells the address of the Mimic Vault
     */
    function getVault() external view returns (address) {
        return address(_vault);
    }

    /**
     * @dev Tells the token that will be used as the strategy entry point
     */
    function getToken() external view override returns (address) {
        return address(_token);
    }

    /**
     * @dev Tells the aToken associated to the strategy token
     */
    function getAToken() external view returns (address) {
        return address(_aToken);
    }

    /**
     * @dev Tells the lending pool used by the strategy
     */
    function getLendingPool() external view returns (address) {
        return address(_lendingPool);
    }

    /**
     * @dev Tell the metadata URI associated to the strategy
     */
    function getMetadataURI() external view override returns (string memory) {
        return _metadataURI;
    }

    /**
     * @dev Tell the slippage used to swap rewards
     */
    function getSlippage() public view returns (uint256) {
        return _slippage;
    }

    /**
     * @dev Tells how much value the strategy has over time.
     * For example, if a strategy has a value of 100 in T0, and then it has a value of 120 in T1,
     * It means it gained a 20% between T0 and T1 due to the appreciation of the A token.
     */
    function getTotalValue() external view override returns (uint256) {
        return _getATokenBalance();
    }

    /**
     * @dev Tells how much a value unit means expressed in the strategy token.
     * For example, if a strategy has a value of 100 in T0, and then it has a value of 120 in T1,
     * and the value rate is 1.5, it means the strategy has earned 30 strategy tokens between T0 and T1.
     */
    function getValueRate() external pure override returns (uint256) {
        return FixedPoint.ONE;
    }

    /**
     * @dev Setter to update the slippage
     * @param slippage New slippage to be set
     */
    function setSlippage(uint256 slippage) external onlyOwner {
        _setSlippage(slippage);
    }

    /**
     * @dev Setter to override the existing metadata URI
     * @param metadataURI New metadata to be set
     */
    function setMetadataURI(string memory metadataURI) external onlyOwner {
        _setMetadataURI(metadataURI);
    }

    /**
     * @dev Strategy onJoin hook
     * @param amount Amount of strategy tokens to invest
     */
    function onJoin(uint256 amount, bytes memory)
        external
        override
        onlyVault
        returns (uint256 value, uint256 totalValue)
    {
        invest(_token);
        value = amount;
        totalValue = _getATokenBalance();
    }

    /**
     * @dev Strategy onExit hook
     * @param ratio Ratio of the invested position to exit
     * @param emergency Tells if the exit call is an emergency or not, if it is then no investments are made, simply exit
     */
    function onExit(uint256 ratio, bool emergency, bytes memory)
        external
        override
        onlyVault
        returns (address token, uint256 amount, uint256 value, uint256 totalValue)
    {
        // Invest before exiting only if it is a non-emergency exit
        if (!emergency) {
            invest(_token);
        }

        amount = SafeMath.div(_getATokenBalance().mulDown(ratio), VAULT_EXIT_RATIO_PRECISION);
        _lendingPool.withdraw(address(_token), amount, address(this));
        _token.approve(address(_vault), amount);

        token = address(_token);
        value = amount;
        totalValue = _getATokenBalance();
    }

    /**
     * @dev Invest all the balance of a token in the strategy into the AAVE lending pool.
     * If the requested token is not the same token as the strategy token it will be swapped before joining the pool.
     * This method is marked as public so it can be used externally by anyone in case of an airdrop.
     * @param token Token to invest all its balance, it cannot be the aToken of the strategy
     */
    function invest(IERC20 token) public {
        require(token != _aToken, 'AAVE_INTERNAL_TOKEN');

        if (token != _token) {
            uint256 amountIn = token.balanceOf(address(this));
            _swap(token, _token, amountIn);
        }

        uint256 amount = _token.balanceOf(address(this));
        if (amount == 0) return;
        _token.approve(address(_lendingPool), amount);
        _lendingPool.deposit(address(_token), amount, address(this), 0);
    }

    /**
     * @dev Internal function to swap a pair of tokens using the Vault's swap connector
     * @param tokenIn Token to be sent
     * @param tokenOut Token to received
     * @param amountIn Amount of tokenIn being swapped
     */
    function _swap(IERC20 tokenIn, IERC20 tokenOut, uint256 amountIn) internal {
        if (amountIn == 0) return;
        require(tokenIn != tokenOut, 'SWAP_SAME_TOKEN');

        IPriceOracle priceOracle = IPriceOracle(_vault.priceOracle());
        uint256 price = priceOracle.getTokenPrice(address(tokenOut), address(tokenIn));
        uint256 minAmountOut = amountIn.mulUp(price).mulUp(FixedPoint.ONE - _slippage);
        if (minAmountOut < SWAP_THRESHOLD) return;

        address swapConnector = _vault.swapConnector();
        tokenIn.safeTransfer(swapConnector, amountIn);

        uint256 preBalanceIn = tokenIn.balanceOf(address(this));
        uint256 preBalanceOut = tokenOut.balanceOf(address(this));
        (uint256 remainingIn, uint256 amountOut) = ISwapConnector(swapConnector).swap(
            address(tokenIn),
            address(tokenOut),
            amountIn,
            minAmountOut,
            block.timestamp,
            new bytes(0)
        );

        require(amountOut >= minAmountOut, 'SWAP_MIN_AMOUNT');
        uint256 postBalanceIn = tokenIn.balanceOf(address(this));
        require(postBalanceIn >= preBalanceIn.add(remainingIn), 'SWAP_INVALID_REMAINING_IN');
        uint256 postBalanceOut = tokenOut.balanceOf(address(this));
        require(postBalanceOut >= preBalanceOut.add(amountOut), 'SWAP_INVALID_AMOUNT_OUT');
    }

    /**
     * @dev Internal function to get the A token balance
     */
    function _getATokenBalance() internal view returns (uint256) {
        return _aToken.balanceOf(address(this));
    }

    /**
     * @dev Internal function to set the metadata URI
     * @param metadataURI New metadata to be set
     */
    function _setMetadataURI(string memory metadataURI) private {
        _metadataURI = metadataURI;
        emit SetMetadataURI(metadataURI);
    }

    /**
     * @dev Internal function to set the slippage
     * @param slippage New slippage to be set
     */
    function _setSlippage(uint256 slippage) private {
        require(slippage <= MAX_SLIPPAGE, 'SLIPPAGE_ABOVE_MAX');
        _slippage = slippage;
        emit SetSlippage(slippage);
    }
}
