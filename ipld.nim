import nimSHA2, streams, multiformats, base58.bitcoin, cbor, hex, hashes, blake2

const MaxBlockSize* = 1 shl 18
  ## Maximum supported block size.

type Cid* = object
  ## Content IDentifier, used to identify blocks.
  digest*: seq[uint8]
  hash*: MulticodecTag
  codec*: MulticodecTag
  ver*: int

proc initCid*(): Cid =
  ## Initialize an invalid CID.
  Cid(hash: MulticodecTag.Invalid, codec: MulticodecTag.Invalid)

proc isValid*(x: Cid): bool =
  ## Check that a CID has been properly initialized.
  x.hash != MulticodecTag.Invalid

proc `==`*(x, y: Cid): bool =
  ## Compare two CIDs. Must be of the same type and
  ## use the same hash algorithm.
  result =
    x.ver == y.ver and
    x.codec == y.codec and
    x.hash == y.hash and
    x.digest == y.digest

proc hash*(cid: Cid): Hash =
  ## Reduce a CID into an integer for use in tables.
  result = hash cid.digest
  result = result !& cid.ver !& cid.codec.int !& cid.hash.int
  result = !$result

proc isRaw*(cid: Cid): bool =
  ## Test if a CID represents a raw block.
  cid.codec == MulticodecTag.Raw

proc isDagCbor*(cid: Cid): bool =
  ## Test if a CID represents CBOR encoded data.
  cid.codec == MulticodecTag.DagCbor

proc toBin(cid: Cid): string =
  let s = newStringStream()
  s.writeUvarint cid.ver
  s.writeUvarint cid.codec.int
  s.writeUvarint cid.hash.int
  s.writeUvarint cid.digest.len
  for e in cid.digest:
    s.write e
  s.setPosition 0
  result = s.readAll
  close s

proc toRaw*(cid: Cid): string =
  ## Return CID encoded in binary.
  MultibaseTag.Identity.char & cid.toBIn

proc newCborBytes*(cid: Cid): CborNode = newCborBytes cid.toRaw
  ## Generate a CBOR representation of a CID.

proc toHex*(cid: Cid): string =
  ## Return CID encoded in hexidecimal.
  MultibaseTag.Base16.char & hex.encode(cid.toBin)

proc toBase58*(cid: Cid): string =
  ## Return CID encoded in base 58.
  MultibaseTag.Base58btc.char & bitcoin.encode(cid.toBin)

proc `$`*(cid: Cid): string = cid.toBase58
  ## Return CID in base 58, the default textual encoding.

proc parseCid*(s: string): Cid =
  ## Detect CID encoding and parse from a string.
  if unlikely(s.len < (1+1+1+1)):
    raise newException(ValueError, "too short to be a valid CID")
  var
    raw: string
    off: int
    codec, hash: int
    digestLen: int
  case s[0].MultibaseTag
  of MultibaseTag.Identity:
    raw = s
    off = 1
  of MultibaseTag.Base16, MultibaseTag.InconsistentBase16:
    raw = hex.decode(s[1..s.high])
    if unlikely(raw.isNil):
      raise newException(ValueError, "not a CID")
  of MultibaseTag.Base58btc:
    raw = bitcoin.decode(s[1..s.high])
  else:
    raise newException(ValueError, "unknown multibase encoding tag")
  off.inc parseUvarint(raw, result.ver, off)
  off.inc parseUvarint(raw, codec, off)
  off.inc parseUvarint(raw, hash, off)
  off.inc parseUvarint(raw, digestLen, off)
  if unlikely(off + digestLen != raw.len):
    raise newException(ValueError, "invalid multihash length")
  result.digest = newSeq[uint8](digestLen)
  for i in 0..<digestLen:
    result.digest[i] = (uint8)raw[i+off]
  result.hash = hash.MulticodecTag
  result.codec = codec.MulticodecTag

proc CidSha256*(data: string; codec = MulticodecTag.Raw): Cid =
  ## Generate a CID for a string of data using the SHA 256 hash algorithm.
  let sha = computeSHA256(data)
  result.digest = newSeq[uint8](32)
  for i in 0..31:
    result.digest[i] = (uint8)sha[i]
  result.hash = MulticodecTag.Sha2_256
  result.codec = codec
  result.ver = 1

proc CidBlake2b256*(data: string; codec = MulticodecTag.Raw): Cid =
  ## Generate a CID for a string of data using the BLAKE2b hash algorithm.
  var b: Blake2b
  blake2b_init(b, 32, nil, 0)
  blake2b_update(b, data, data.len)

  result.digest = blake2b_final(b)
  result.hash = MulticodecTag.Blake2b_256
  result.codec = codec
  result.ver = 1

proc verify*(cid: Cid; data: string): bool =
  ## Verify that a string of data corresponds to a CID.
  case cid.hash
  of MulticodecTag.Sha2_256:
    let sha = computeSHA256(data)
    for i in 0..31:
      if cid.digest[i] != (uint8)sha[i]:
        return false
    result = true
  of MulticodecTag.Blake2b_256:
    var b: Blake2b
    blake2b_init(b, 32, nil, 0)
    blake2b_update(b, data, data.len)
    let digest = blake2b_final(b)
    result = (cid.digest == digest)
  else:
    raise newException(ValueError, "unknown hash type " & $cid.hash)

iterator simpleChunks*(s: Stream; size = 256 * 1024): string =
  ## Iterator that breaks a stream into simple chunks.
  while not s.atEnd:
    yield s.readStr size

when isMainModule:
  import times

  let data = newString MaxBlockSize
  block sha256:
    var i = 0
    let t0 = cpuTime()
    while i < 100:
      discard CidSha256 data
      inc i
    let d = cpuTime() - t0
    echo "SHA256 ticks: ", d
  block blake2b:
    var i = 0
    let t0 = cpuTime()
    while i < 100:
      discard CidBlake2b256 data
      inc i
    let d = cpuTime() - t0
    echo "BLAKE2b ticks: ", d
