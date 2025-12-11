// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

// import "hardhat/console.sol";
// import "@openzeppelin/contracts/access/Ownable.sol";

interface ArbSys {
    function arbBlockNumber() external view returns (uint256);
    function arbBlockHash(uint256 blockNumber) external view returns (bytes32);
}

contract RandomSeed is VRFConsumerBaseV2Plus {
    // VRF Configuration - all private since they're only used in this contract
    uint256 private s_subscriptionId;
    bytes32 public s_keyHash;
    uint32 public callbackGasLimit = 200000;
    uint16 public requestConfirmations = 1;
    uint32 public numWords = 1;
    bool public nativePayment = true; // Use native ETH for payment

    bool public immutable useOracle; // Set in constructor, cannot be changed
    bool public needFinalize = true;
    uint256 public blockWait = 3; // Number of blocks to wait between commit and reveal

    // Storage - organized by round
    mapping(uint256 => uint256) internal s_requestToRound; // requestId => round
    mapping(uint256 => uint256) internal s_roundResults; // round => random result
    mapping(uint256 => uint256) internal s_roundFulfilledBlock; // round => block number when fulfilled

    struct PendingRound {
        uint256 round;
        uint256 vrfResult;
        bytes32 commitment;
        uint256 commitBlock;
    }

    // Store all pending rounds by round number (for local mode)
    mapping(uint256 => PendingRound) private s_pendingRounds;
    // Store single pending round (for oracle mode)
    PendingRound private s_pendingRound;

    // Events
    event RandomRequested(uint256 indexed requestId, uint256 indexed round);
    event RandomFulfilled(
        uint256 indexed requestId,
        uint256 indexed round,
        uint256 indexed randomNumber
    );

    event BlockWaitUpdated(uint256 newBlockWait);

    event CallbackGasLimitUpdated(uint32 oldGasLimit, uint32 newGasLimit);
    event SubscriptionIdUpdated(uint256 oldSubscriptionId, uint256 newSubscriptionId);
    event RequestConfirmationsUpdated(uint16 oldRequestConfirmations, uint16 newRequestConfirmations);

    event DebugReveal(
        uint256 currentBlock,
        uint256 commitBlock,
        uint256 blockWait,
        bytes32 commitBlockHash
    );

    constructor(
        address _vrfCoordinator,
        bool _useOracle
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        useOracle = _useOracle;
    }

    function updateChainLinkConfig(
        uint256 _subscriptionId,
        bytes32 _keyHash,
        uint16 _requestConfirmations,
        bool _needFinalize
    ) external onlyOwner {
        uint256 oldSubscriptionId = s_subscriptionId;
        uint16 oldRequestConfirmations = requestConfirmations;
        
        s_subscriptionId = _subscriptionId;
        s_keyHash = _keyHash;
        requestConfirmations = _requestConfirmations;
        needFinalize = _needFinalize;
        
        if (oldSubscriptionId != _subscriptionId) {
            emit SubscriptionIdUpdated(oldSubscriptionId, _subscriptionId);
        }
        if (oldRequestConfirmations != _requestConfirmations) {
            emit RequestConfirmationsUpdated(oldRequestConfirmations, _requestConfirmations);
        }
    }

    function requestRandomWords(uint256 round, bytes32 secretCommitment ) internal returns (uint256) {
        require(s_roundFulfilledBlock[round] == 0, "Round already fulfilled");

        if (!useOracle) {
            // Use block data as pseudo-randomness
            uint256 l2BlockNumber = ArbSys(address(100)).arbBlockNumber();
            s_pendingRounds[round] = PendingRound({
                round: round,
                commitment: secretCommitment,
                vrfResult: 0,
                commitBlock: l2BlockNumber // record commit block
            });
            s_roundFulfilledBlock[round] = l2BlockNumber;
            return 0;
        }

        s_pendingRound = PendingRound({
            round: round,
            commitment: secretCommitment,
            vrfResult: 0,
            commitBlock: 0 // not used for oracle
        });

        // Request random number with direct funding
        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: s_keyHash,
                subId: s_subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: numWords,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: nativePayment})
                )
            })
        );

        s_requestToRound[requestId] = round;
        emit RandomRequested(requestId, round);

        return requestId;
    }

    function fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal override {
        require(useOracle, "fulfillRandomWords should only be called in oracle mode");
        uint256 round = s_requestToRound[requestId];
        require(round == s_pendingRound.round, "Round mismatch");

        uint256 l2BlockNumber = ArbSys(address(100)).arbBlockNumber();
        s_roundFulfilledBlock[round] = l2BlockNumber;
        if (needFinalize) { 
            s_pendingRound.vrfResult = randomWords[0];
        } else {
            s_roundResults[round] = randomWords[0];
        }
    }

    // For useOracle == true
    function finalizeCurrentRound(bytes32 secret) external onlyOwner {
        require(useOracle, "Not in oracle mode");
        uint256 round = s_pendingRound.round;
        require(round > 0, "No round pending");
        require(s_roundResults[round] == 0, "Already revealed");
        require(s_pendingRound.vrfResult != 0, "VRF result not yet available");
        require(s_roundFulfilledBlock[round] != 0, "Round not fulfilled");
        bytes32 computedCommitment = keccak256(abi.encodePacked(secret));
        require(computedCommitment == s_pendingRound.commitment, "Invalid secret");

        uint256 finalRandom = uint256(keccak256(abi.encodePacked(
            s_pendingRound.vrfResult,
            secret
        )));

        s_roundResults[round] = finalRandom;
        delete s_pendingRound;
    }

    // For useOracle == false
    function finalizeRound(uint256 round, bytes32 secret) external onlyOwner {
        require(!useOracle, "Not in local mode");
        PendingRound storage pendingRound = s_pendingRounds[round];
        require(pendingRound.round > 0, "No round pending");
        require(s_roundResults[round] == 0, "Already revealed");
        require(s_roundFulfilledBlock[round] != 0, "Round not fulfilled");
        bytes32 computedCommitment = keccak256(abi.encodePacked(secret));
        require(computedCommitment == pendingRound.commitment, "Invalid secret");

        uint256 l2BlockNumber = ArbSys(address(100)).arbBlockNumber();
        bytes32 commitBlockHash = ArbSys(address(100)).arbBlockHash(pendingRound.commitBlock);

        emit DebugReveal(l2BlockNumber, pendingRound.commitBlock, blockWait, commitBlockHash);
        require(l2BlockNumber >= pendingRound.commitBlock + blockWait, "Reveal too soon after commit block");
        require(l2BlockNumber <= pendingRound.commitBlock + 255, "Reveal window expired");
        require(commitBlockHash != bytes32(0), "Commit blockhash unavailable");

        uint256 finalRandom = uint256(keccak256(abi.encodePacked(
            commitBlockHash,
            secret
        )));

        s_roundResults[round] = finalRandom;
        delete s_pendingRounds[round];
    }

    function getPendingRound(uint256 round) external view returns (PendingRound memory) {
        if (!useOracle) {
            require(s_pendingRounds[round].round > 0, "No pending round");
            return s_pendingRounds[round];
        } else {
            require(s_pendingRound.round == round, "No pending round");
            return s_pendingRound;
        }
    }

    function getRoundResult(uint256 round) public view returns (uint256) {
        require(_isRoundFinalized(round), "Round not finalized yet");
        return s_roundResults[round];
    }

    function isRoundFulfilled(uint256 round) public view returns (bool) {
        return s_roundFulfilledBlock[round] != 0;
    }

    function isRoundFinalized(uint256 round) external view returns (bool) {
        return _isRoundFinalized(round); 
    }

    function _isRoundFinalized(uint256 round) internal view returns (bool) {
        return s_roundFulfilledBlock[round] != 0 && s_roundResults[round] != 0; 
    }

    function getRequestRound(
        uint256 requestId
    ) external view returns (uint256) {
        return s_requestToRound[requestId];
    }

    function getRoundFulfilledBlock(uint256 round) external view returns (uint256) {
        return s_roundFulfilledBlock[round];
    }

    // Admin functions
    function updateCallbackGasLimit(uint32 newGasLimit) external onlyOwner {
        uint32 oldGasLimit = callbackGasLimit;
        callbackGasLimit = newGasLimit;
        emit CallbackGasLimitUpdated(oldGasLimit, newGasLimit);
    }

    function togglePaymentMethod() external onlyOwner {
        nativePayment = !nativePayment;
    }

    // Function to withdraw unused ETH
    function withdrawETH(uint256 amount) external onlyOwner {
        require(address(this).balance >= amount, "Insufficient balance");
        payable(msg.sender).transfer(amount);
    }

    // Check contract balance
    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }

    // Only owner can update blockWait
    function setBlockWait(uint256 _blockWait) external onlyOwner {
        require(_blockWait > 0 && _blockWait < 256, "blockWait must be 1-255");
        blockWait = _blockWait;
        emit BlockWaitUpdated(_blockWait);
    }
}
