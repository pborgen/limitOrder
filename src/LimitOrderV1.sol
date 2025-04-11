// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract LimitOrderBook is ERC2771Context, EIP712, ReentrancyGuard {
    // Trusted forwarder address for gasless transactions
    constructor(
        address trustedForwarder
    ) ERC2771Context(trustedForwarder) EIP712("LimitOrderBook", "1") {}

    // Order structure
    struct Order {
        address maker; // User who created the order
        address tokenIn; // Token to sell
        address tokenOut; // Token to buy
        uint256 amountIn; // Amount to sell
        uint256 amountOut; // Amount to receive (based on limit price)
        bool isBuy; // True for buy order, false for sell order
        uint256 expiry; // Order expiration timestamp
        bool active; // Order status
        bytes32 orderHash; // Unique order identifier
    }

    // Mapping to store orders
    mapping(bytes32 => Order) public orders;

    // Events
    event OrderPlaced(
        bytes32 indexed orderHash,
        address indexed maker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bool isBuy,
        uint256 expiry
    );
    event OrderCancelled(bytes32 indexed orderHash);
    event OrderExecuted(
        bytes32 indexed orderHash,
        address indexed taker,
        uint256 amountIn,
        uint256 amountOut
    );

    // Place a limit order (gasless via meta-transaction)
    function placeOrder(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bool isBuy,
        uint256 expiry,
        bytes memory signature
    ) external nonReentrant {
        require(expiry > block.timestamp, "Order expired");
        require(amountIn > 0 && amountOut > 0, "Invalid amounts");

        // Generate order hash using EIP-712
        bytes32 orderHash = _hashOrder(
            _msgSender(),
            tokenIn,
            tokenOut,
            amountIn,
            amountOut,
            isBuy,
            expiry
        );

        // Verify signature
        require(
            _verifySignature(orderHash, signature, _msgSender()),
            "Invalid signature"
        );

        // Create order
        orders[orderHash] = Order({
            maker: _msgSender(),
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            amountOut: amountOut,
            isBuy: isBuy,
            expiry: expiry,
            active: true,
            orderHash: orderHash
        });

        // Transfer tokens from maker to contract (for sell orders)
        if (!isBuy) {
            IERC20(tokenIn).transferFrom(_msgSender(), address(this), amountIn);
        }

        emit OrderPlaced(
            orderHash,
            _msgSender(),
            tokenIn,
            tokenOut,
            amountIn,
            amountOut,
            isBuy,
            expiry
        );
    }

    // Cancel an order
    function cancelOrder(bytes32 orderHash) external nonReentrant {
        Order storage order = orders[orderHash];
        require(order.maker == _msgSender(), "Not order maker");
        require(order.active, "Order inactive");

        order.active = false;

        // Refund tokens for sell orders
        if (!order.isBuy && order.amountIn > 0) {
            IERC20(order.tokenIn).transfer(order.maker, order.amountIn);
        }

        emit OrderCancelled(orderHash);
    }

    // Execute an order (called by taker)
    function executeOrder(
        bytes32 orderHash,
        uint256 amountIn
    ) external nonReentrant {
        Order storage order = orders[orderHash];
        require(order.active, "Order inactive");
        require(block.timestamp <= order.expiry, "Order expired");
        require(amountIn <= order.amountIn, "Invalid amount");

        address taker = _msgSender();
        uint256 amountOut = (amountIn * order.amountOut) / order.amountIn;

        // Transfer tokens
        if (order.isBuy) {
            // Buy order: taker sends tokenIn, maker sends tokenOut
            IERC20(order.tokenIn).transferFrom(taker, order.maker, amountIn);
            IERC20(order.tokenOut).transferFrom(order.maker, taker, amountOut);
        } else {
            // Sell order: contract sends tokenIn, taker sends tokenOut
            IERC20(order.tokenIn).transfer(taker, amountIn);
            IERC20(order.tokenOut).transferFrom(taker, order.maker, amountOut);
        }

        // Update order
        order.amountIn -= amountIn;
        order.amountOut -= amountOut;
        if (order.amountIn == 0) {
            order.active = false;
        }

        emit OrderExecuted(orderHash, taker, amountIn, amountOut);
    }

    // EIP-712 order hash
    function _hashOrder(
        address maker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bool isBuy,
        uint256 expiry
    ) internal view returns (bytes32) {
        return
            _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        keccak256(
                            "Order(address maker,address tokenIn,address tokenOut,uint256 amountIn,uint256 amountOut,bool isBuy,uint256 expiry)"
                        ),
                        maker,
                        tokenIn,
                        tokenOut,
                        amountIn,
                        amountOut,
                        isBuy,
                        expiry
                    )
                )
            );
    }

    // Verify EIP-712 signature
    function _verifySignature(
        bytes32 orderHash,
        bytes memory signature,
        address signer
    ) internal view returns (bool) {
        address recovered = ECDSA.recover(orderHash, signature);
        return recovered == signer;
    }
}
