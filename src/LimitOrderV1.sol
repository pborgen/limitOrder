// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interface/IUniswapV2Router02.sol";

contract LimitOrderBookV1 is ReentrancyGuard {
    uint256 public platformFee;
    uint256 public executionFee;
    uint256 public executionFeeTotalHeld;
    address public owner;

    // Trusted forwarder address for gasless transactions
    constructor(uint256 _platformFee, uint256 _executionFee) {
        platformFee = _platformFee;
        executionFee = _executionFee;
        owner = msg.sender;
    }

    // Order structure
    struct Order {
        address creator; // User who created the order
        address router; // Router to use
        address tokenIn; // Token to sell
        address tokenOut; // Token to buy
        uint256 amountIn; // Amount to sell
        uint256 amountOutMin; // Amount to receive (based on limit price)
        uint256 amountOutActual;
        uint256 expiry; // Order expiration timestamp
        bool active; // Order status
        uint256 platformFee; // Fee paid for the order
        uint256 executionFee; // Fee paid for the execution
        uint256 creationBlock; // Block number of the order
        uint256 orderId; // Numeric order ID
    }

    // Mapping to store orders
    mapping(uint256 => Order) public orders;
    mapping(address => bool) public allowedToExecuteOrders;

    // Events
    event OrderPlaced(address indexed maker, uint256 orderId);
    event OrderCancelled(uint256 orderId);
    event OrderExecuted(
        address indexed maker,
        uint256 indexed orderId,
        uint256 actualAmountOut
    );

    // Helper function to convert bytes32 to uint256
    function bytes32ToUint256(bytes32 _bytes) public pure returns (uint256) {
        return uint256(_bytes);
    }

    // Place a limit order (gasless via meta-transaction)
    function placeOrder(
        address router,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 expiry
    ) external payable nonReentrant {
        require(router != address(0), "Invalid router");
        require(tokenIn != tokenOut, "Invalid token pair");
        require(
            tokenIn != address(0) && tokenOut != address(0),
            "Invalid token"
        );

        require(expiry > block.timestamp, "Order expired");
        require(amountIn > 0 && amountOutMin > 0, "Invalid amounts");

        // Verify approval
        require(
            IERC20(tokenIn).allowance(msg.sender, address(this)) >= amountIn,
            "Token not approved"
        );

        // Make sure fee was sent
        require(msg.value == platformFee + executionFee, "Incorrect fee");

        bytes32 orderHash = keccak256(
            abi.encodePacked(msg.sender, block.number, block.timestamp)
        );
        uint256 numericOrderId = bytes32ToUint256(orderHash);

        // make sure an order was not created already
        require(
            orders[numericOrderId].creationBlock == 0,
            "Order already created in this block"
        );

        // Create order
        orders[numericOrderId] = Order({
            creator: msg.sender,
            router: router,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            amountOutActual: 0,
            expiry: expiry,
            active: true,
            platformFee: platformFee,
            executionFee: executionFee,
            creationBlock: block.number,
            orderId: numericOrderId
        });

        executionFeeTotalHeld += executionFee;

        emit OrderPlaced(msg.sender, numericOrderId);
    }

    // Cancel an order
    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage order = orders[orderId];
        require(order.creator == msg.sender, "Not order creator");
        require(order.active, "Order inactive");

        order.active = false;

        // Refund 1/2 of the fee
        uint256 refundAmount = (order.executionFee) / 2;
        (bool success, ) = order.creator.call{value: refundAmount}("");
        require(success, "Refund failed");

        executionFeeTotalHeld -= order.executionFee;
        emit OrderCancelled(orderId);
    }

    // Execute an order (called by taker)
    function executeOrder(uint256 orderId) external nonReentrant {

        Order storage order = orders[orderId];
        require(order.active, "Order inactive");
        require(block.timestamp <= order.expiry, "Order expired");

        address[] memory path = new address[](2);
        path[0] = order.tokenIn;
        path[1] = order.tokenOut;

        // transfer tokens to this contract
        IERC20(order.tokenIn).transferFrom(
            msg.sender,
            address(this),
            order.amountIn
        );

        // approve the router to spend the tokens
        IERC20(order.tokenIn).approve(order.router, order.amountIn);

        uint256 amountBeforeSwap = IERC20(order.tokenOut).balanceOf(
            address(this)
        );

        IUniswapV2Router02(order.router)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                order.amountIn,
                order.amountOutMin,
                path,
                order.creator,
                block.timestamp
            );

        uint256 amountAfterSwap = IERC20(order.tokenOut).balanceOf(
            address(this)
        );

        uint256 actualAmountOut = amountAfterSwap - amountBeforeSwap;

        order.amountOutActual = actualAmountOut;
        order.active = false;

        // refund the execution fee
        (bool success, ) = msg.sender.call{value: order.executionFee}("");
        require(success, "Refund failed");

        executionFeeTotalHeld -= order.executionFee;

        emit OrderExecuted(order.creator, orderId, actualAmountOut);
    }

    // Withdraw collected fees
    function withdrawPlatformFees() external {
        require(msg.sender == owner, "Not owner");

        uint256 platformFees = address(this).balance - executionFeeTotalHeld;
        (bool success, ) = owner.call{value: platformFees}("");
        require(success, "Withdraw failed");
    }

    function withdrawToken(address token) external {
        require(msg.sender == owner, "Not owner");
        IERC20(token).transfer(
            msg.sender,
            IERC20(token).balanceOf(address(this))
        );
    }

    function updateFees(uint256 _newPlatformFee, uint256 _newExecutionFee) external {
        require(msg.sender == owner, "Not owner");
        platformFee = _newPlatformFee;
        executionFee = _newExecutionFee;
    }
}
