import {
  type Address,
  type Hex,
  concatHex,
  encodeAbiParameters,
  encodeFunctionData,
  getAddress,
  getContractAddress,
  hashMessage,
  keccak256,
  pad,
  toBytes,
  toHex,
} from "viem";

export const LIGHT_ACCOUNT_FACTORY: Address =
  "0x0000000000400CdFef5E2714E63d8040b700BC24";
const LIGHT_ACCOUNT_IMPLEMENTATION: Address =
  "0x8E8e658E22B12ada97B402fF0b044D6A325013C7";
const EIP6492_MAGIC: Hex =
  "0x6492649264926492649264926492649264926492649264926492649264926492";

function initCode(): Hex {
  const mem = new Uint8Array(0x80);
  const writeWord = (offset: number, word: Hex) => {
    mem.set(toBytes(pad(word, { size: 32 })), offset);
  };
  writeWord(
    0x60,
    "0xcc3735a920a3ca505d382bbc545af43d6000803e6038573d6000fd5b3d6000f3",
  );
  writeWord(
    0x40,
    "0x5155f3363d3d373d3d363d7f360894a13ba1a3210667c828492db98dca3e2076",
  );
  writeWord(0x20, "0x6009");
  mem.set(toBytes(pad(LIGHT_ACCOUNT_IMPLEMENTATION, { size: 32 })), 0x1e);
  writeWord(0x0a, "0x603d3d8160223d3973");
  return toHex(mem.slice(0x21, 0x21 + 0x5f));
}

export function lightAccountAddress(owner: Address): Address {
  const combinedSalt = keccak256(
    encodeAbiParameters(
      [{ type: "address" }, { type: "uint256" }],
      [getAddress(owner), 0n],
    ),
  );
  return getContractAddress({
    opcode: "CREATE2",
    from: LIGHT_ACCOUNT_FACTORY,
    salt: combinedSalt,
    bytecode: initCode(),
  });
}

export function lightAccountSignRequest(owner: Address, message: string) {
  const account = lightAccountAddress(owner);
  const hash = hashMessage(message);
  return {
    account,
    domain: {
      name: "LightAccount",
      version: "2",
      chainId: undefined as number | undefined,
      verifyingContract: account,
    },
    types: {
      LightAccountMessage: [{ name: "message", type: "bytes" }],
    },
    primaryType: "LightAccountMessage" as const,
    message: {
      message: encodeAbiParameters([{ type: "bytes32" }], [hash]),
    },
  };
}

export function wrapLightAccountSignature(
  owner: Address,
  signature: Hex,
): Hex {
  const inner = concatHex(["0x00", signature]);
  const factoryData = encodeFunctionData({
    abi: [
      {
        type: "function",
        name: "createAccount",
        stateMutability: "nonpayable",
        inputs: [
          { name: "owner", type: "address" },
          { name: "salt", type: "uint256" },
        ],
        outputs: [{ name: "account", type: "address" }],
      },
    ],
    functionName: "createAccount",
    args: [owner, 0n],
  });
  const packed = encodeAbiParameters(
    [{ type: "address" }, { type: "bytes" }, { type: "bytes" }],
    [LIGHT_ACCOUNT_FACTORY, factoryData, inner],
  );
  return concatHex([packed, EIP6492_MAGIC]);
}
