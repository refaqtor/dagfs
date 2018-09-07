import std/hashes, std/streams, std/strutils
import base58/bitcoin, cbor
import ./dagfs/priv/hex, ./dagfs/priv/blake2

const
  maxBlockSize* = 1 shl 18
    ## Maximum supported block size.
  digestLen* = 32
    ## Length of a block digest.

type Cid* = object
  ## Content IDentifier, used to identify blocks.
  digest*: array[digestLen, uint8]

proc initCid*(): Cid = Cid()
  ## Initialize an invalid CID.

proc isValid*(x: Cid): bool =
  ## Check that a CID has been properly initialized.
  for c in x.digest.items:
    if c != 0: return true

proc `==`*(x, y: Cid): bool =
  ## Compare two CIDs.
  for i in 0..<digestLen:
    if x.digest[i] != y.digest[i]:
      return false
  true

proc `==`*(cbor: CborNode; cid: Cid): bool =
  ## Compare a CBOR node with a CID.
  if cbor.kind == cborBytes:
    for i in 0..<digestLen:
      if cid.digest[i] != cbor.bytes[i].uint8:
        return false
    result = true

proc hash*(cid: Cid): Hash = hash cid.digest
  ## Reduce a CID into an integer for use in tables.

proc toCbor*(cid: Cid): CborNode = newCborBytes cid.digest
  ## Generate a CBOR representation of a CID.

proc toCid*(cbor: CborNode): Cid =
  ## Generate a CBOR representation of a CID.
  assert(cbor.bytes.len == digestLen)
  for i in 0..<digestLen:
    result.digest[i] = cbor.bytes[i].uint8

{.deprecated: [newCborBytes: toCbor].}

proc toHex*(cid: Cid): string = hex.encode(cid.digest)
  ## Return CID encoded in hexidecimal.

proc writeUvarint*(s: Stream; n: SomeInteger) =
  ## Write an IPFS varint
  var n = n
  while true:
    let c = int8(n and 0x7f)
    n = n shr 7
    if n == 0:
      s.write((char)c.char)
      break
    else:
      s.write((char)c or 0x80)

proc readUvarint*(s: Stream): BiggestInt =
  ## Read an IPFS varint
  var shift: int
  while shift < (9*8):
    let c = (BiggestInt)s.readChar
    result = result or ((c and 0x7f) shl shift)
    if (c and 0x80) == 0:
      break
    shift.inc 7

proc toIpfs*(cid: Cid): string =
  ## Return CID encoded in IPFS multimulti.
  const
    multiRaw = 0x55
    multiBlake2b_256 = 0xb220
  let s = newStringStream()
  s.writeUvarint 1
  s.writeUvarint multiRaw
  s.writeUvarint multi_blake2b_256
  s.writeUvarint digestLen
  for e in cid.digest:
    s.write e
  s.setPosition 0
  result = 'z' & bitcoin.encode(s.readAll)
  close s

proc `$`*(cid: Cid): string = toHex cid
  ## Return CID in base 58, the default textual encoding.

proc parseCid*(s: string): Cid =
  ## Detect CID encoding and parse from a string.
  var raw = parseHexStr s
  if raw.len != digestLen:
    raise newException(ValueError, "invalid ID length")
  for i in 0..<digestLen:
    result.digest[i] = raw[i].byte

const
  zeroBlock* = parseCid "8ddb61928ec76e4ee904cd79ed977ab6f5d9187f1102975060a6ba6ce10e5481"
    ## CID of zero block of maximum size.

proc take*(cid: var Cid; buf: var string) =
  ## Take a raw digest from a string buffer.
  doAssert(buf.len == digestLen)
  copyMem(cid.digest[0].addr, buf[0].addr, digestLen)

proc dagHash*(data: string): Cid =
  ## Generate a CID for a string of data using the BLAKE2b hash algorithm.
  assert(data.len <= maxBlockSize)
  var b: Blake2b
  blake2b_init(b, digestLen, nil, 0)
  blake2b_update(b, data, data.len)
  var s = blake2b_final(b)
  copyMem(result.digest[0].addr, s[0].addr, digestLen)

proc verify*(cid: Cid; data: string): bool =
  ## Verify that a string of data corresponds to a CID.
  var b: Blake2b
  blake2b_init(b, digestLen, nil, 0)
  blake2b_update(b, data, data.len)
  let digest = blake2b_final(b)
  for i in 0..<digestLen:
    if cid.digest[i] != digest[i]:
      return false
  true

iterator simpleChunks*(s: Stream; size = maxBlockSize): string =
  ## Iterator that breaks a stream into simple chunks.
  doAssert(size <= maxBlockSize)
  var tmp = newString(size)
  while not s.atEnd:
    tmp.setLen(size)
    tmp.setLen(s.readData(tmp[0].addr, size))
    yield tmp
