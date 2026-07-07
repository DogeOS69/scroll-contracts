/* eslint-disable node/no-missing-import */
/* eslint-disable node/no-unpublished-import */
import { expect } from "chai";
import { Contract } from "ethers";
import { artifacts, ethers } from "hardhat";

describe("DogeP2PKHVerifier.spec", async () => {
  const PREDEPLOY = "0x5300000000000000000000000000000000000006";
  const ABI = ["function verifyP2PKHPacked(bytes) view returns (bool)"];

  // Vector 0 from src/test/dogeos/DogeSigTestVectors.sol.
  const PACKED_VECTOR =
    "0x" +
    "751e76e8199196d454941c45d1b3a323f1433bd6" +
    "3196730ac4e84bc0557fc8c363301f0b7f635dc66d7f77b8a1d659c496536455" +
    "20" +
    "0dc88c26f74d05a4a3005c3bd6ff07ccd9b4e4836d09595538f80e93af0234ac" +
    "2fd0f13f88190f22a6869938845c7d44b2b52687e1575c0c64ed5d9975b13161" +
    "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798" +
    "483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8";

  let verifier: Contract;

  beforeEach(async () => {
    const artifact = await artifacts.readArtifact("DogeP2PKHVerifier");
    await ethers.provider.send("hardhat_setCode", [PREDEPLOY, artifact.deployedBytecode]);
    verifier = new Contract(PREDEPLOY, ABI, ethers.provider);
  });

  it("verifies a packed fixture at the canonical predeploy address", async () => {
    expect(await verifier.verifyP2PKHPacked(PACKED_VECTOR)).to.eq(true);
  });
});
