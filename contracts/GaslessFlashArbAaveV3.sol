// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title GaslessFlashArbAaveV3 (safe variant)
 * @notice Minimal, secure-by-design variant intended for tests:
 *  - exact nonce checking
 *  - executed guard
 *  - hook validation BEFORE state changes
 *  - pull-payment accounting (internal balances) and explicit withdraw
 *  - solver: 90% / treasury: 10% profit split
 *  - nonReentrant protection on external value transfers
 */
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IHook {
    function validate(address executor, uint256 expectedProfitWei, bytes32 actionsHash) external view returns (bool);
}

contract GaslessFlashArbAaveV3 is ReentrancyGuard {
    // ---- constants ----
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant SOLVER_SHARE_BP = 9000; // 90%

    // ---- events ----
    event OrderExecuted(bytes32 indexed digest, address indexed solver, uint256 profitWei);
    event Withdrawn(address indexed to, uint256 amount);

    // ---- types ----
    struct SolverOrder {
        address solver;
        uint256 nonce;
        uint256 expiry;
        uint256 expectedProfitWei;
        bytes32 actionsHash;
    }

    // ---- state ----
    address public immutable treasury;
    address public owner;
    IHook public hook;

    mapping(address => uint256) public nonces;
    mapping(bytes32 => bool) public executed;

    mapping(address => uint256) private _withdrawable;

    constructor(address _treasury, address _hook) {
        require(_treasury != address(0), "treasury zero");
        treasury = _treasury;
        owner = msg.sender;
        if (_hook != address(0)) hook = IHook(_hook);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    /// @notice return how much `who` can withdraw
    function withdrawable(address who) external view returns (uint256) {
        return _withdrawable[who];
    }

    /**
     * @notice Submit and execute a solver order.
     *  Performs cheap checks then hook validation BEFORE state writes.
     */
    function submitOrderAndExecute(
        SolverOrder memory order,
        bytes calldata, /* signature - reserved */
        bytes calldata  /* actions - reserved */
    ) external payable {
        require(order.solver != address(0), "solver zero");
        require(order.expiry > block.timestamp, "expired");

        uint256 cur = nonces[order.solver];
        require(order.nonce == cur, "invalid nonce");

        bytes32 digest = keccak256(
            abi.encode(
                order.solver,
                order.nonce,
                order.expiry,
                order.expectedProfitWei,
                order.actionsHash
            )
        );

        require(!executed[digest], "already executed");

        if (address(hook) != address(0)) {
            require(
                hook.validate(order.solver, order.expectedProfitWei, order.actionsHash),
                "hook validation failed"
            );
        }

        nonces[order.solver] = cur + 1;
        executed[digest] = true;

        require(msg.value == order.expectedProfitWei, "msg.value mismatch");

        uint256 total = order.expectedProfitWei;
        uint256 solverShare = (total * SOLVER_SHARE_BP) / BASIS_POINTS;
        uint256 treasuryShare = total - solverShare;

        _withdrawable[order.solver] += solverShare;
        _withdrawable[treasury] += treasuryShare;

        emit OrderExecuted(digest, order.solver, total);
    }

    function withdraw() external nonReentrant {
        uint256 amount = _withdrawable[msg.sender];
        require(amount != 0, "nothing to withdraw");
        _withdrawable[msg.sender] = 0;

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "send failed");
        emit Withdrawn(msg.sender, amount);
    }

    function rescueETH(address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "zero to");
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "rescue failed");
    }

    receive() external payable {}
}
