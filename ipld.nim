import nimSHA2, streams, multiformat, base58.bitcoin, cbor, hex

type Cid* = object
  digest*: string
  hash*: MulticodecTag
  codec*: MulticodecTag
  ver*: int
  logicalLen*: int # not included in canonical representation

proc `==`*(x, y: Cid): bool =
  result =
    x.ver == y.ver and
    x.codec == y.codec and
    x.hash == y.hash and
    x.digest == y.digest

proc isRaw*(cid: Cid): bool =
  cid.codec == MulticodecTag.Raw

proc isDagCbor*(cid: Cid): bool =
  cid.codec == MulticodecTag.DagCbor

proc toBin(cid: Cid): string =
  let s = newStringStream()
  s.writeUvarint cid.ver
  s.writeUvarint cid.codec.int
  s.writeUvarint cid.hash.int
  s.writeUvarint cid.digest.len
  s.write cid.digest
  s.setPosition 0
  result = s.readAll
  close s

proc toRaw*(cid: Cid): string =
  MultibaseTag.Identity.char & cid.toBIn

proc toHex*(cid: Cid): string =
  MultibaseTag.Base16.char & hex.encode(cid.toBin)

proc toBase58*(cid: Cid): string =
  MultibaseTag.Base58btc.char & bitcoin.encode(cid.toBin)

proc `$`*(cid: Cid): string = cid.toBase58

proc parseCid*(s: string): Cid =
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
  of MultibaseTag.Base58btc:
    raw = bitcoin.decode(s[1..s.high])
  else:
    raise newException(ValueError, "unknown multibase encoding tag")
  off.inc parseUvarint(raw, result.ver, off)
  off.inc parseUvarint(raw, codec, off)
  off.inc parseUvarint(raw, hash, off)
  off.inc parseUvarint(raw, digestLen, off)
  if off + digestLen != raw.len:
    raise newException(ValueError, "invalid multihash length")
  result.digest = raw[off..raw.high]
  result.hash = hash.MulticodecTag
  result.codec = codec.MulticodecTag
  result.logicalLen = -1

proc CidSha256*(data: string; codec = MulticodecTag.Raw): Cid =
  Cid(
    digest: $computeSHA256(data),
    hash: MulticodecTag.Sha2_256,
    codec: codec,
    ver: 1,
    logicalLen: data.len)

type Dag* = CborNode

proc newDag*(): Dag = newCborMap()

proc parseDag*(data: string): Dag =
  let stream = newStringStream(data)
  result = parseCbor stream
  close stream

proc add*(dag: Dag; cid: Cid; name: string; size: int) =
  let link = newCborMap()
  link["cid"] = newCborBytes(cid.toRaw)
  link["name"] = newCborText(name)
  link["size"] = newCborInt(size)
  var links = dag["links"]
  if links.isNil:
    links = newCborArray()
    dag["links"] = links
  links.add link

proc merge*(dag, other: Dag) =
  let otherLinks = other["links"]
  var result = dag["links"]
  if result.isNil:
    result = newCborArray()
    dag["links"] = result
  if not otherLinks.isNil:
    for link in otherlinks.list:
      block insert:
        var i: int
        while i < result.list.len:
          let L = result.list[i]
          if L["name"].getString == link["name"].getString:
            result.list[i] = link
              # replace
            break insert
          inc i
        result.add link
          # append

proc containsFile*(dag: Dag; name: string): bool =
  for link in dag["links"].items:
    if link["name"].getText == name:
      return true
  false

proc lookupFile*(dag: Dag; name: string): tuple[cid: Cid, size: int] =
  for link in dag["links"].items:
    if link["name"].getText == name:
      result.cid = parseCid link["cid"].getBytes()
      result.size = link["size"].getInt().int
      return
  raise newException(SystemError, "DAG file lookup failed")

#[
proc unixFsContains*(dag: Dag; name: string): bool =
  dagcontains(name)

proc unixFsLookup*(dag: Dag; name: string): tuple[key: string, size: int] =
  let fileNode = dag[name]
  if not fileNode.isNil:
    result.key = fileNode["cid"].getText
    result.size = fileNode["size"].getInt.int

proc fileLen*(dag: Dag; name: string): int =
  {.hint:"fileLen not implemented".}
  -1
]#

iterator simpleChunks*(s: Stream; size = 256 * 1024): (Cid, string) =
  while not s.atEnd:
    var result: (Cid, string)
    result[1] = s.readStr size
    result[0] = result[1].CidSHA256(MulticodecTag.Raw)
    yield result

proc addLink*(dag: CborNode; name: string; cid: Cid) =
  dag[newCborText name] = newCborTag(42, newCborBytes(cid.toRaw))
