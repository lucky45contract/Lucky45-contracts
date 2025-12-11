// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;
import "./RandomSeed.sol";
// import "hardhat/console.sol";

contract RandomNumber is RandomSeed {
    // Round management
    uint256 public currentRound = 0;
    uint256 public currentRequestId = 0;

    // Start time (string for informational purposes)
    string public startTime;

    // Events
    event RoundSet(uint256 indexed newRound);

    constructor(address _vrfCoordinator, bool _useOracle, string memory _startTime) RandomSeed(_vrfCoordinator, _useOracle) {
        startTime = _startTime;
    }

    // Generate random for current round with secret commitment
    function generateNextRoundSeed(bytes32 secretCommitment) external onlyOwner returns (uint256) {
        advanceRound();
        currentRequestId = requestRandomWords(currentRound, secretCommitment);
        return currentRound;
    }

    // Advance to next round
    function advanceRound() public onlyOwner {
        unchecked {
            ++currentRound;
        }
        emit RoundSet(currentRound);
    }

    // Advance round by a specific increment
    function advanceRoundBy(uint256 increment) public onlyOwner {
        require(increment > 0, "Increment must be greater than 0");
        unchecked {
            currentRound += increment;
        }
        emit RoundSet(currentRound);
    }

    // Get result for current round
    function getRoundSeed() external view returns (uint256) {
        require(currentRound > 0, "No current round set");
        return getRoundResult(currentRound);
    }

     // Check if current round is complete
    function isRoundFulfilled() external view returns (bool) {
        require(currentRound > 0, "No current round set");
        return isRoundFulfilled(currentRound);
    }

    // Check if current round is complete
    function isRoundFinalized() external view returns (bool) {
        require(currentRound > 0, "No current round set");
        return _isRoundFinalized(currentRound);
    }

    function getRoundResultExtended(string memory name, uint256 round, uint32 min, uint32 max, uint16 count, uint16 offset) 
        external view returns (uint32[] memory) {
        require(count >= 1, "Count must be greater than 0");
        require(count <= 1000, "Count must be less than 1000");
        require(max >= min, "Max must be greater than or equal to min");
        require(max - min + 1 >= count, "Range too small for unique numbers");
        require(round > 0, "No round set");
        
        uint256 seed = getRoundResult(round);
        uint32[] memory results = new uint32[](count);
        
        for (uint16 i = 0; i < count; i++) {
            uint32 newNumber;
            uint256 attempts = 0;
            bool isUnique = false;
            
            while (!isUnique && attempts < 10000) {
                uint256 temp = uint256(keccak256(abi.encode(name, seed, i + offset, attempts)));
                uint32 range = max - min + 1;
                uint32 maxValid = type(uint32).max - (type(uint32).max % range);

                uint32 candidate=uint32(temp);
                //rejection sampling to eliminate modulo bias
                if(candidate >= maxValid){
                    continue;
                }

                newNumber = candidate % range + min;
                
                // Check if number already exists
                isUnique = true;
                for (uint16 j = 0; j < i; j++) {
                    if (results[j] == newNumber) {
                        isUnique = false;
                        break;
                    }
                }
                attempts++;
            }
            
            require(isUnique, "Failed to generate unique number");
            results[i] = newNumber;
        }
        
        return results;
    }
}
