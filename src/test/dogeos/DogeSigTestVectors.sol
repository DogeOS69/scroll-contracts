// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

// GENERATED FILE - DO NOT EDIT.
// Regenerate: python3 scripts/dogeos/gen_doge_sig_vectors.py
//   (deps: pip install -r scripts/dogeos/requirements.txt)
// Plain Solidity only - this file is compiled by both Foundry and Hardhat.

/**
 * @title DogeSigTestVectors
 * @notice Dogecoin Core-compatible signmessage test vectors for DogeSig.
 * @dev Generated with coincurve (libsecp256k1, RFC6979 deterministic nonces).
 */
abstract contract DogeSigTestVectors {
    struct SigVector {
        string name;
        bytes message;
        bytes32 msgHash;
        uint8 header;
        bytes32 r;
        bytes32 s;
        bytes32 x;
        bytes32 y;
        bytes20 keyHash;
        bool compressed;
    }

    function _sigVectors() internal pure returns (SigVector[] memory vectors) {
        vectors = new SigVector[](10);
        // compressed short ascii (recId 1)
        vectors[0] = SigVector({
            name: "compressed short ascii",
            message: hex"53756368207665726966792e204d75636820776f772e",
            msgHash: bytes32(0x3196730ac4e84bc0557fc8c363301f0b7f635dc66d7f77b8a1d659c496536455),
            header: 32,
            r: bytes32(0x0dc88c26f74d05a4a3005c3bd6ff07ccd9b4e4836d09595538f80e93af0234ac),
            s: bytes32(0x2fd0f13f88190f22a6869938845c7d44b2b52687e1575c0c64ed5d9975b13161),
            x: bytes32(0x79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798),
            y: bytes32(0x483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8),
            keyHash: hex"751e76e8199196d454941c45d1b3a323f1433bd6",
            compressed: true
        });
        // uncompressed short ascii (recId 1)
        vectors[1] = SigVector({
            name: "uncompressed short ascii",
            message: hex"53756368207665726966792e204d75636820776f772e",
            msgHash: bytes32(0x3196730ac4e84bc0557fc8c363301f0b7f635dc66d7f77b8a1d659c496536455),
            header: 28,
            r: bytes32(0xd91a4c9770226411a2f7cbed2b3e9da0892e93d2664bd612a33fd8ea89123ce9),
            s: bytes32(0x0f7f0df4a2f7d654607f2351fa7bb17dbed3c74a8473cd7fb08f4045945de19a),
            x: bytes32(0xc6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5),
            y: bytes32(0x1ae168fea63dc339a3c58419466ceaeef7f632653266d0e1236431a950cfe52a),
            keyHash: hex"d6c8e828c1eca1bba065e1b83e1dc2a36e387a42",
            compressed: false
        });
        // empty message (recId 1)
        vectors[2] = SigVector({
            name: "empty message",
            message: hex"",
            msgHash: bytes32(0xe2d7323944c6d8c084722919c739244c55bbd108f2292054bd26e01f4fbd5bdb),
            header: 32,
            r: bytes32(0xba1faf5f02d2fbabe3e94db9f1eeb48c1647e7c7ed1ef30388702123802b1ea8),
            s: bytes32(0x6ed95b09e5a6be2af9e56ffeafb0e4f5feafbd2d2331925928298f546ab0907a),
            x: bytes32(0xf9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9),
            y: bytes32(0x388f7b0f632de8140fe337e62a37f3566500a99934c2231b6cb9fd7584b8e672),
            keyHash: hex"7dd65592d0ab2fe0d0257d571abf032cd9db93dc",
            compressed: true
        });
        // raw 32-byte intent hash (recId 1)
        vectors[3] = SigVector({
            name: "raw 32-byte intent hash",
            message: hex"d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3",
            msgHash: bytes32(0x562a37d4ae1a7c80e9b7b4082af04414c4568abc01019b822bf96eccf92db687),
            header: 32,
            r: bytes32(0x22ff7f60dc5bf3c7a38993f0f048916e1cb3f60c68d8f35a23bc9b0b82c58324),
            s: bytes32(0x3385f9200a59e4405415742f3f6cd0d123892b7b41d5bf771c89edad23f0c1bd),
            x: bytes32(0xe493dbf1c10d80f3581e4904930b1404cc6c13900ee0758474fa94abe8c4cd13),
            y: bytes32(0x51ed993ea0d455b75642e2098ea51448d967ae33bfbdfe40cfe97bdc47739922),
            keyHash: hex"c42e7ef92fdb603af844d064faad95db9bcdfd3d",
            compressed: true
        });
        // message length 252 (recId 0)
        vectors[4] = SigVector({
            name: "message length 252",
            message: _repeat(bytes1(0x64), 252),
            msgHash: bytes32(0x5108a161aa085d73a4360522d32cd1113da1b417da525976b46bdb8a0a993040),
            header: 31,
            r: bytes32(0xb527cd11088fa9f28d8ec8171298231678c6f82626e3c9c64638ad86e029e612),
            s: bytes32(0x492e72eec1db4af7842c617014d1f8f72fadac946c6bf1efb014ba55905bcdd6),
            x: bytes32(0x2f8bde4d1a07209355b4a7250a5c5128e88b84bddc619ab7cba8d569b240efe4),
            y: bytes32(0xd8ac222636e5e3d6d4dba9dda6c9c426f788271bab0d6840dca87d3aa6ac62d6),
            keyHash: hex"4747e8746cddb33b0f7f95a90f89f89fb387cbb6",
            compressed: true
        });
        // message length 253 (recId 1)
        vectors[5] = SigVector({
            name: "message length 253",
            message: _repeat(bytes1(0x6f), 253),
            msgHash: bytes32(0x7adc6ac48e73433214f679d390c26df5fabc2bca19676d890cbaeb0c66a28ab6),
            header: 32,
            r: bytes32(0x0a80f4ffb20a23ae6fb0614facb3d3b807b673882e1872b9fbf5273100d7d78d),
            s: bytes32(0x29eb2bebb11bce70640efc4ddb55580d32da8fab7c8102f2b3b93db2900e9e97),
            x: bytes32(0xfff97bd5755eeea420453a14355235d382f6472f8568a18b2f057a1460297556),
            y: bytes32(0xae12777aacfbb620f3be96017f45c560de80f0f6518fe4a03c870c36b075f297),
            keyHash: hex"7fda9cf020c16cacf529c87d8de89bfc70b8c9cb",
            compressed: true
        });
        // message length 1024 (recId 0)
        vectors[6] = SigVector({
            name: "message length 1024",
            message: _repeat(bytes1(0x67), 1024),
            msgHash: bytes32(0xb2e2a8a7e15bb88049daa0d7bae3a9b0cfd0c0a582a218c603113a402ba8c866),
            header: 31,
            r: bytes32(0xac62ba7cc37eaaf4c1413f983a5cccb992f4fcdf615e90e5dc9b31b15881e6c1),
            s: bytes32(0x4066b5d5a5ff12502f7f8b5e09bb17a2b7344e11fa71c179aefc18dda81ced18),
            x: bytes32(0x5cbdf0646e5db4eaa398f365f2ea7a0e3d419b7e0330e39ce92bddedcac4f9bc),
            y: bytes32(0x6aebca40ba255960a3178d6d861a54dba813d0b813fde7b5a5082628087264da),
            keyHash: hex"5dedfbf9ea599dd4e3ca6a80b333c472fd0b3f69",
            compressed: true
        });
        // recId zero (recId 0)
        vectors[7] = SigVector({
            name: "recId zero",
            message: hex"7265636f76657279206964207a65726f",
            msgHash: bytes32(0xcab0c76bace38c5ff48173bbb29241ebd9fcc57566a07e04a72c7f704b64a468),
            header: 31,
            r: bytes32(0xaf49e34d7028f3b251bd0ee648e7f790bc5f475c3dcd298e86a327a58c48a3be),
            s: bytes32(0x53052f7dc33141cd1cb461e10942bbcdefaacbd15801fdd836d10cb85e9d83f3),
            x: bytes32(0x2f01e5e15cca351daff3843fb70f3c2f0a1bdd05e5af888a67784ef3e10a2a01),
            y: bytes32(0x5c4da8a741539949293d082a132d13b4c2e213d6ba5b7617b5da2cb76cbde904),
            keyHash: hex"9652d86bedf43ad264362e6e6eba6eb764508127",
            compressed: true
        });
        // recId one (recId 1)
        vectors[8] = SigVector({
            name: "recId one",
            message: hex"7265636f76657279206964206f6e6521",
            msgHash: bytes32(0x374f4ede5240fb13aabdb044a7e59d11716854fc39b5ca02b1f346f2b14313a0),
            header: 32,
            r: bytes32(0xf8215ed8ba2c272a72be41a5a76d7a2e79aabfeab8ac83e6876d5b9b903864ed),
            s: bytes32(0x2cd4322e119acafa5db47bf6b5ec022958abf7e78c89200fe10575a403c65238),
            x: bytes32(0xacd484e2f0c7f65309ad178a9f559abde09796974c57e714c35f110dfc27ccbe),
            y: bytes32(0xcc338921b0a7d9fd64380971763b61e9add888a4375f8e0f05cc262ac64f9c37),
            keyHash: hex"b46abf4d9e1746e33bcc39cea3de876c29c4adf3",
            compressed: true
        });
        // uncompressed recId zero (recId 0)
        vectors[9] = SigVector({
            name: "uncompressed recId zero",
            message: hex"756e636f6d70726573736564207265636f76657279206964207a65726f",
            msgHash: bytes32(0x03656ca9446d1399a6387418d423599b5bd592e661ff3b0103e6a4759f8aec88),
            header: 27,
            r: bytes32(0x04c938a8b94ab4c69ef6cd52649d0cdbc1c1c7c4aeea7e4971a20acc640e47d0),
            s: bytes32(0x058b0164ec67c5680ce82dfe31fc7ecd426ccae149188dc20de8510c4c3e8e73),
            x: bytes32(0x774ae7f858a9411e5ef4246b70c65aac5649980be5c17891bbec17895da008cb),
            y: bytes32(0xd984a032eb6b5e190243dd56d7b7b365372db1e2dff9d6a8301d74c9c953c61b),
            keyHash: hex"ef31f6db0c690071007448c034d35e1d4ef2ec4a",
            compressed: false
        });
        return vectors;
    }

    function _repeat(bytes1 char, uint256 len) private pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = char;
        }
    }
}
