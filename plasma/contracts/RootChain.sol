pragma solidity ^0.4.0;

import "./Math.sol";
import "./Merkle.sol";
import "./PlasmaUtils.sol";
import "./PriorityQueue.sol";


/**
 * @title RootChain
 * @dev Plasma Battleship root chain contract implementation.
 */
contract RootChain {
    /*
     * Events
     */

    event DepositCreated(
        address indexed owner,
        uint256 amount,
        uint256 depositBlock
    );

    event PlasmaBlockRootCommitted(
        uint256 blockNumber,
        bytes32 root
    );

    event ExitStarted(
        address indexed owner,
        uint256 utxoPosition,
        uint256 amount
    );


    /*
     * Storage
     */

    uint256 constant public CHALLENGE_PERIOD = 1 weeks;
    uint256 constant public EXIT_BOND = 123456789;

    PriorityQueue exitQueue;
    uint256 public currentPlasmaBlockNumber;
    address public operator;

    mapping (uint256 => PlasmaBlock) public plasmaBlocks;
    mapping (uint256 => PlasmaExit) public plasmaExits;

    struct PlasmaBlock {
        bytes32 root;
        uint256 timestamp;
    }

    struct PlasmaExit {
        address owner;
        uint256 amount;
        bool isStarted;
        bool isValid;
    }


    /*
     * Modifiers
     */

    modifier onlyOperator() {
        require(msg.sender == operator, "Sender must be operator.");
        _;
    }

    modifier onlyWithValue(uint256 value) {
        require(msg.value == value, "Sent value must be equal to requried value.");
        _;
    }


    /*
     * Constructor
     */

    constructor() public {
        operator = msg.sender;
        currentPlasmaBlockNumber = 1;
        exitQueue = new PriorityQueue();
    }


    /*
     * Public functions
     */

    /**
     * @dev Allows a user to deposit into the Plasma chain.
     */
    function deposit() public payable {
        require(msg.value > 0, "Deposit value must be greater than zero.");

        // Generate the deposit transaction.
        bytes memory encodedDepositTx = PlasmaUtils.getDepositTransaction(msg.sender, msg.value);

        // Publish the new deposit block root.
        plasmaBlocks[currentPlasmaBlockNumber] = PlasmaBlock({
            root: PlasmaUtils.getDepositRoot(encodedDepositTx),
            timestamp: block.timestamp
        });

        emit DepositCreated(msg.sender, msg.value, currentPlasmaBlockNumber);
        currentPlasmaBlockNumber++;
    }

    /**
     * @dev Allows the operator to commit a block root to Ethereum.
     * @param _root Root to be committed.
     */
    function commitPlasmaBlockRoot(bytes32 _root) public onlyOperator {
        plasmaBlocks[currentPlasmaBlockNumber] = PlasmaBlock({
            root: _root,
            timestamp: block.timestamp
        });

        emit PlasmaBlockRootCommitted(currentPlasmaBlockNumber, _root);
        currentPlasmaBlockNumber++;
    }

    /**
     * @dev Starts an exit for a given UTXO.
     * @param _utxoBlockNumber Block number of the UTXO being exited.
     * @param _utxoTxIndex Transaction index of the UTXO being exited.
     * @param _utxoOutputIndex Output index of the UTXO being exited.
     * @param _encodedTx RLP encoded transaction that created the output.
     * @param _txInclusionProof Proof that the transaction was included in the Plasma chain.
     * @param _txSignatures Signatures that validate the transaction that created the output.
     * @param _txConfirmationSignatures Signatures that confirm the transaction that created the output.
     */
    function startExit(
        uint256 _utxoBlockNumber,
        uint256 _utxoTxIndex,
        uint256 _utxoOutputIndex,
        bytes _encodedTx,
        bytes _txInclusionProof,
        bytes _txSignatures,
        bytes _txConfirmationSignatures
    ) public payable onlyWithValue(EXIT_BOND) {
        uint256 utxoPosition = PlasmaUtils.encodeUtxoPosition(_utxoBlockNumber, _utxoTxIndex, _utxoOutputIndex);
        PlasmaUtils.TransactionOutput memory transactionOutput = PlasmaUtils.decodeTx(_encodedTx).outputs[_utxoOutputIndex];

        // Check that this exit is valid.
        require(transactionOutput.owner == msg.sender, "Only output owner can withdraw this output.");
        require(transactionOutput.amount > 0, "Output value must be greater than zero.");
        require(!plasmaExits[utxoPosition].isStarted, "Exit must not already exist.");

        // Check transaction signatures.
        bytes32 txHash = keccak256(_encodedTx);
        require(PlasmaUtils.validateSignatures(txHash, _txSignatures, _txConfirmationSignatures), "Signatures must match.");

        // Check the transaction is included in the chain.
        PlasmaBlock memory plasmaBlock = plasmaBlocks[_utxoBlockNumber];
        bytes32 merkleHash = keccak256(abi.encodePacked(_encodedTx, _txSignatures));
        require(Merkle.checkMembership(merkleHash, _utxoTxIndex, plasmaBlock.root, _txInclusionProof), "Transaction must be in block.");

        // Must wait at least one week (> 1 week old UTXOs), but might wait up to two weeks (< 1 week old UTXOs).
        uint256 exitableAt = Math.max(plasmaBlock.timestamp + 2 weeks, block.timestamp + 1 weeks);

        exitQueue.insert(exitableAt, utxoPosition);
        plasmaExits[utxoPosition] = PlasmaExit({
            owner: transactionOutput.owner,
            amount: transactionOutput.amount,
            isStarted: true,
            isValid: true
        });

        emit ExitStarted(msg.sender, utxoPosition, transactionOutput.amount);
    }

    /**
     * @dev Blocks an exiting UTXO by proving the UTXO was spent.
     * @param _exitingUtxoBlockNumber Block number of the UTXO being exited.
     * @param _exitingUtxoTxIndex Transaction index of the UTXO being exited.
     * @param _exitingUtxoOutputIndex Output index of the UTXO being exited.
     * @param _encodedSpendingTx RLP encoded transaction that spent the UTXO.
     * @param _spendingTxConfirmationSignature Confirmation signature over the spending transaction.
     */
    function challengeExit(
        uint256 _exitingUtxoBlockNumber,
        uint256 _exitingUtxoTxIndex,
        uint256 _exitingUtxoOutputIndex,
        bytes _encodedSpendingTx,
        bytes _spendingTxConfirmationSignature
    ) public {
        PlasmaUtils.Transaction memory transaction = PlasmaUtils.decodeTx(_encodedSpendingTx);
        uint256 exitingUtxoPosition = PlasmaUtils.encodeUtxoPosition(_exitingUtxoBlockNumber, _exitingUtxoTxIndex, _exitingUtxoOutputIndex);

        // Check that the exiting UTXO was actually spent.
        bool spendsExitingUtxo = false;
        for (uint8 i = 0; i < transaction.inputs.length; i++) {
            if (exitingUtxoPosition == PlasmaUtils.getInputPosition(transaction.inputs[i])) {
                spendsExitingUtxo = true;
                break;
            }
        }
        require(spendsExitingUtxo, "Transaction must spend exiting UTXO.");

        // Check that the spending transaction was confirmed.
        bytes32 confirmationHash = keccak256(abi.encodePacked(keccak256(_encodedSpendingTx)));
        address owner = plasmaExits[exitingUtxoPosition].owner;
        require(owner == ECRecovery.recover(confirmationHash, _spendingTxConfirmationSignature), "Transaction must be confirmed.");

        // The exit is invalid.
        plasmaExits[exitingUtxoPosition].isValid = false;
    }

    /**
     * @dev Processes any exits that have completed the exit period.
     */
    function processExits() public {
        uint256 exitableAt;
        uint256 utxoPosition;

        // Iterate while the queue is not empty.
        while(exitQueue.currentSize() > 0){
            (exitableAt, utxoPosition) = exitQueue.getMin();

            // Check if this exit has finished its challenge period.
            if (exitableAt > block.timestamp){
                return;
            }

            PlasmaExit memory currentExit = plasmaExits[utxoPosition];

            // Only pay out valid exits.
            if (currentExit.isValid){
                currentExit.owner.transfer(currentExit.amount);

                // Delete owner but keep amount to prevent another exit from the same UTXO.
                delete plasmaExits[utxoPosition].owner;
            }

            exitQueue.delMin();
        }
    }
}
