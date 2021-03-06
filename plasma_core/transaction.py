import rlp
from rlp.sedes import big_endian_int, binary, CountableList
from ethereum import utils
from plasma_core.utils.signatures import sign, get_signer
from plasma_core.utils.transactions import encode_utxo_position
from plasma_core.constants import NULL_SIGNATURE, NULL_ADDRESS


def pad_list(to_pad, pad_value, required_length):
    """Pads a list to a specified length.

    Args:
        to_pad (list): A list of items to pad.
        pad_value: Some value that should be used to pad the list.
        required_length (int): Total required list length.

    Returns:
        list: The padded list.
    """

    if len(to_pad) > required_length:
        raise ValueError('list cannot be longer than required length')

    return to_pad + [pad_value] * (required_length - len(to_pad))


class TransactionInput(rlp.Serializable):
    """Represents a transaction input.

    Attributes:
        blknum (int): Block in which this input was created.
        txindex (int): Index in the block of the transaction that created this input.
        oindex (int): Index of the output in the transaction.
    """

    fields = (
        ('blknum', big_endian_int),
        ('txindex', big_endian_int),
        ('oindex', big_endian_int)
    )

    def __init__(self, blknum=0, txindex=0, oindex=0):
        self.blknum = blknum
        self.txindex = txindex
        self.oindex = oindex

    @property
    def position(self):
        """This input's position in the chain"""
        return encode_utxo_position(self.blknum, self.txindex, self.oindex)


class TransactionOutput(rlp.Serializable):
    """Represents a transaction output.

    Attributes:
        owner (bytes): Address of the owner of this output.
        amount (int): Amount represented by this output.
    """

    fields = (
        ('owner', utils.address),
        ('amount', big_endian_int)
    )

    def __init__(self, owner=NULL_ADDRESS, amount=0):
        self.owner = utils.normalize_address(owner)
        self.amount = amount


class Transaction(rlp.Serializable):
    """Represents a Plasma transaction

    Attributes:
        inputs ((int, int,int)[]): List of inputs to this transaction.
        outputs ((bytes, int)[]): List of outputs created by this transaction.
        signatures (bytes[]): List of signatures over this transaction.
    """

    NUM_TXOS = 2
    DEFAULT_INPUT = (0, 0, 0)
    DEFAULT_OUTPUT = (NULL_ADDRESS, 0)
    fields = (
        ('inputs', CountableList(TransactionInput, NUM_TXOS)),
        ('outputs', CountableList(TransactionOutput, NUM_TXOS)),
        ('signatures', CountableList(binary, NUM_TXOS))
    )

    def __init__(self, inputs=[], outputs=[], signatures=[], confirmations=[]):
        inputs = inputs or [self.DEFAULT_INPUT] * self.NUM_TXOS
        outputs = outputs or [self.DEFAULT_OUTPUT] * self.NUM_TXOS
        signatures = signatures or [NULL_SIGNATURE] * self.NUM_TXOS
        confirmations = confirmations or [NULL_SIGNATURE] * self.NUM_TXOS

        padded_inputs = pad_list(inputs, self.DEFAULT_INPUT, self.NUM_TXOS)
        padded_outputs = pad_list(outputs, self.DEFAULT_OUTPUT, self.NUM_TXOS)

        self.inputs = [TransactionInput(*i) for i in padded_inputs]
        self.outputs = [TransactionOutput(*o) for o in padded_outputs]
        self.signatures = signatures[:]
        self.confirmations = confirmations[:]
        self.spent = [False] * self.NUM_TXOS

    @property
    def merkle_leaf_data(self):
        """RLP encoding of this transaction concatenated with its signatures"""
        return self.encoded + self.joined_signatures

    @property
    def hash(self):
        """Hash of the RLP encoding of this transaction"""
        return utils.sha3(self.encoded)

    @property
    def confirmation_hash(self):
        """Double of the RLP encoding of this transaction"""
        return utils.sha3(self.hash)

    @property
    def joined_signatures(self):
        """Transaction signatures joined into a single byte string"""
        return b''.join(self.signatures)

    @property
    def joined_confirmations(self):
        """Confirmation signatures joined into a single byte string"""
        return b''.join(self.confirmations)

    @property
    def signers(self):
        """List of addresses that have signed this transaction"""
        return [get_signer(self.hash, sig) if sig != NULL_SIGNATURE else NULL_ADDRESS for sig in self.signatures]

    @property
    def encoded(self):
        """RLP encoded representation of this transaction"""
        return rlp.encode(self, UnsignedTransaction)

    @property
    def is_deposit(self):
        """Whether or not this is a deposit transaction"""
        return all([i.blknum == 0 for i in self.inputs])

    def sign(self, index, key):
        """Adds a signature for this transaction.

        Args:
            index (int): Index of the input owner by the signer.
            key (bytes): Private key to be used to sign.
        """

        self.signatures[index] = sign(self.hash, key)

    def confirm(self, index, key):
        """Adds a confirmation signature for this transaction.

        Args:
            index (int): Index of the input owner by the signer.
            key (bytes): Private key to be used to sign.
        """

        self.confirmations[index] = sign(self.confirmation_hash, key)


class UnsignedTransaction(rlp.Serializable):

    fields = Transaction.fields[:-1]
