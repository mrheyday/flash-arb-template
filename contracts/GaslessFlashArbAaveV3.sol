// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/draft-EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

interface IHook {
    function validate(address executor, uint256 expectedProfitWei, bytes32 actionsHash) external view returns (bool);
}

contract GaslessFlashArbAaveV3 is ReentrancyGuard, EIP712 {
    bytes32 public constant ORDER_TYPEHASH =
        keccak256("Order(address solver,uint256 nonce,uint256 expiry,uint256 expectedProfitWei,bytes32 actionsHash)");

    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant SOLVER_SHARE_BP = 9000;

    event OrderExecuted(bytes32 indexed digest, address indexed solver, uint256 profitWei);
    event Withdrawn(address indexed to, uint256 amount);

    struct SolverOrder {
        address solver;
        uint256 nonce;
        uint256 expiry;
        uint256 expectedProfitWei;
        bytes32 actionsHash;
    }

    address public immutable treasury;
    address public owner;
    IHook public hook;
    mapping(address => uint256) public nonces;
    mapping(bytes32 => bool) public executed;
    mapping(address => uint256) private _withdrawable;

    constructor(address _treasury, address _hook) EIP712("FlashArb", "1") {
        require(_treasury != address(0), "treasury zero");
        treasury = _treasury;
        owner = msg.sender;
        if (_hook != address(0)) hook = IHook(_hook);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    function _verifySignature(
        SolverOrder memory order,
        bytes calldata signature
    ) internal view returns (address) {
        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order.solver,
                order.nonce,
                order.expiry,
                order.expectedProfitWei,
                order.actionsHash
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        return ECDSA.recover(digest, signature);
    }

    function submitOrderAndExecute(
        SolverOrder memory order,
        bytes calldata signature,
        bytes calldata
    ) external payable {
        require(order.solver != address(0), "solver zero");
        require(order.expiry > block.timestamp, "expired");
        address recovered = _verifySignature(order, signature);
        require(recovered == order.solver, "invalid signature");
        require(order.nonce == nonces[order.solver], "invalid nonce");

        bytes32 digest = keccak256(
            abi.encode(order.solver, order.nonce, order.expiry, order.expectedProfitWei, order.actionsHash)
        );
        require(!executed[digest], "already executed");

        if (address(hook) != address(0)) {
            require(hook.validate(order.solver, order.expectedProfitWei, order.actionsHash), "hook failed");
        }

        nonces[order.solver] ++;
        executed[digest] = true;
        require(msg.value == order.expectedProfitWei, "msg.value mismatch");

        uint256 solverShare = (order.expectedProfitWei * SOLVER_SHARE_BP) / BASIS_POINTS;
        uint256 treasuryShare = order.expectedProfitWei - solverShare;
        _withdrawable[order.solver] += solverShare;
        _withdrawable[treasury] += treasuryShare;

        emit OrderExecuted(digest, order.solver, order.expectedProfitWei);
    }

    function withdraw() external nonReentrant {
        uint256 amount = _withdrawable[msg.sender];
        require(amount > 0, "nothing to withdraw");
        _withdrawable[msg.sender] = 0;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "withdraw failed");
        emit Withdrawn(msg.sender, amount);
    }

    function rescueETH(address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "zero to");
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "rescue failed");
    }

    receive() external payable {}
}
