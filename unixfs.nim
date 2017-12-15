import asyncdispatch, strutils, multiformats, streams, tables, cbor, os, hex, math

import ipld, ipldstore

type EntryKey = enum
  typeKey = 1,
  dataKey = 2,
  sizeKey = 3

type UnixFsType* = enum
  ufsFile = 0,
  ufsDir = 1

type UnixFsKind* = enum
  fileNode,
  dirNode,
  shallowDir,
  shallowFile

type
  FileLink* = object
    cid*: Cid
    size*: int

  UnixFsNode* = ref object
    cid: Cid
    case kind*: UnixFsKind
    of fileNode:
      links*: seq[FileLink]
    of dirNode:
      entries: OrderedTable[string, UnixFsNode]
    of shallowFile, shallowDir:
      discard
    size: BiggestInt

proc cid*(u: UnixFsNode): Cid =
  assert u.cid.isValid
  u.cid

proc isFile*(u: UnixfsNode): bool = u.kind in { fileNode, shallowFile }
proc isDir*(u: UnixfsNode): bool = u.kind in { dirNode, shallowDir }

proc size*(u: UnixfsNode): BiggestInt =
  if u.kind == dirNode: u.entries.len.BiggestInt
  else: u.size

proc newUnixFsRoot*(): UnixFsNode =
  UnixFsNode(
    cid: initCid(),
    kind: dirNode,
    entries: initOrderedTable[string, UnixFsNode](8))

proc newUnixfsFile*(): UnixFsNode =
  UnixFsNode(kind: fileNode, cid: initCid())

proc newUnixfsDir*(cid: Cid): UnixFsNode =
  UnixFsNode(cid: cid, kind: dirNode)

proc add*(root: var UnixFsNode; name: string; node: UnixFsNode) =
  root.entries[name] = node

proc addDir*(root: var UnixFsNode; name: string; cid: Cid) {.deprecated.} =
  assert cid.isValid
  root.add name, UnixFsNode(kind: dirNode, cid: cid)

proc addFile*(root: var UnixFsNode; name: string; cid: Cid; size: BiggestInt) {.deprecated.} =
  assert cid.isValid
  root.add name, UnixFsNode(kind: fileNode, cid: cid, size: size)

proc del*(dir: var UnixFsNode; name: string) =
  dir.entries.del name

const
  DirTag* = 0xda3c80 ## CBOR tag for UnixFS directories
  FileTag* = 0xda3c81 ## CBOR tag for UnixFS files

proc toCbor*(u: UnixFsNode): CborNode =
  case u.kind
  of fileNode:
    if u.links.isNil:
      raiseAssert "cannot encode single-chunk files"
    let array = newCborArray()
    array.seq.setLen u.links.len
    for i in 0..u.links.high:
      let L = newCborMap()
      # typeEntry is reserved but not in use
      L[dataKey.int] = u.links[i].cid.newCborBytes
      L[sizeKey.int] = u.links[i].size.newCborInt
      array.seq[i] = L
    result = newCborTag(FileTag, array)
  of dirNode:
    let map = newCborMap()
    for name, node in u.entries:
      var entry = newCborMap()
      case node.kind
      of fileNode, shallowFile:
        entry[typeKey.int] = ufsFile.int.newCborInt
        entry[dataKey.int] = node.cid.newCborBytes
        entry[sizeKey.int] = node.size.newCborInt
      of dirNode:
        entry[typeKey.int] = ufsDir.int.newCborInt
        entry[dataKey.int] = node.cid.newCborBytes
        entry[sizeKey.int] = node.entries.len.newCborInt
      of shallowdir:
        entry[typeKey.int] = ufsDir.int.newCborInt
        entry[dataKey.int] = node.cid.newCborBytes
        entry[sizeKey.int] = node.size.int.newCborInt
      map[name] = entry
    # TODO: the CBOR maps must be sorted
    result = newCborTag(DirTag, map)
  else:
    raiseAssert "shallow UnixfsNodes can not be encoded"

template parseAssert(cond: bool; msg = "") =
  if not cond: raise newException(
    ValueError,
    if msg == "": "invalid UnixFS CBOR" else: "invalid UnixFS CBOR, " & msg)

proc parseUnixfs*(raw: string; cid: Cid): UnixFsNode =
  ## Parse a string containing CBOR data into a UnixFsNode.
  assert(not raw.isNil)
  new result
  result.cid = cid
  var
    c: CborParser
    buf = ""
  open(c, newStringStream(raw))
  next c
  parseAssert(c.kind == CborEventKind.cborTag, "data not tagged")
  let tag = c.parseTag
  if tag == FileTag:
    result.kind = fileNode
    next c
    parseAssert(c.kind == CborEventKind.cborArray, "file data not an array")
    let nLinks = c.arrayLen
    result.links = newSeq[FileLink](nLinks)
    for i in 0..<nLinks:
      next c
      parseAssert(c.kind == CborEventKind.cborMap, "file array does not contain maps")
      let nAttrs = c.mapLen
      for _ in 1..nAttrs:
        next c
        parseAssert(c.kind == CborEventKind.cborPositive, "link map key not an integer")
        let key = c.parseInt.EntryKey
        next c
        case key
        of typeKey:
          parseAssert(false, "type file links are not supported")
        of dataKey:
          parseAssert(c.kind == CborEventKind.cborBytes, "CID not encoded as bytes")
          c.readBytes buf
          result.links[i].cid = buf.parseCid
        of sizeKey:
          parseAssert(c.kind == CborEventKind.cborPositive, "link size not encoded properly")
          result.links[i].size = c.parseInt
          result.size.inc result.links[i].size
  elif tag == DirTag:
    result.kind = dirNode
    next c
    parseAssert(c.kind == CborEventKind.cborMap)
    let dirLen = c.mapLen
    parseAssert(dirLen != -1, raw)
    result.entries = initOrderedTable[string, UnixFsNode](dirLen.nextPowerOfTwo)
    for i in 1 .. dirLen:
      next c
      parseAssert(c.kind == CborEventKind.cborText, raw)
      c.readText buf
      parseAssert(not buf.contains({ '/', '\0'}), raw)
      next c
      parseAssert(c.kind == CborEventKind.cborMap)
      let nAttrs = c.mapLen
      parseAssert(nAttrs > 1, raw)
      let entry = new UnixFsNode
      result.entries[buf] = entry
      for i in 1 .. nAttrs:
        next c
        parseAssert(c.kind == CborEventKind.cborPositive)
        case c.parseInt.EntryKey
        of typeKey:
          next c
          case c.parseInt.UnixFsType
          of ufsFile: entry.kind = shallowFile
          of ufsDir: entry.kind = shallowDir
        of dataKey:
          next c
          c.readBytes buf
          entry.cid = buf.parseCid
        of sizeKey:
          next c
          entry.size = c.parseInt
  else:
    parseAssert(false, raw)
  next c
  parseAssert(c.kind == cborEof, "trailing data")

proc toStream*(node: UnixFsNode; s: Stream) =
  let c = node.toCbor()
  c.toStream s

iterator items*(dir: UnixFsNode): (string, UnixFsNode) =
  assert(not dir.isNil)
  assert(dir.kind == dirNode)
  for k, v in dir.entries.pairs:
    yield (k, v)

proc containsFile*(dir: UnixFsNode; name: string): bool =
  doAssert(dir.kind == dirNode)
  dir.entries.contains name

proc `[]`*(dir: UnixFsNode; name: string): UnixFsNode =
  if dir.kind == dirNode:
    result = dir.entries.getOrDefault name

proc `[]`*(dir: UnixFsNode; index: int): (string, UnixfsNode) =
  result[0] = ""
  if dir.kind == dirNode:
    var i = 0
    for name, node in dir.entries.pairs:
      if i == index:
        result = (name, node)
        break
      inc i

proc lookupFile*(dir: UnixFsNode; name: string): tuple[cid: Cid, size: BiggestInt] =
  doAssert(dir.kind == dirNode)
  let f = dir.entries[name]
  if f.kind == fileNode:
    result.cid = f.cid
    result.size = f.size

proc addFile*(store: IpldStore; path: string): Future[UnixFsNode] {.async.} =
  ## Add a file to the store and a UnixfsNode.
  let
    fStream = newFileStream(path, fmRead)
    u = newUnixfsFile()
  for cid, chunk in fStream.simpleChunks:
    discard await store.put(chunk)
    if u.links.isNil:
      u.links = newSeqOfCap[FileLink](1)
    u.links.add FileLink(cid: cid, size: chunk.len)
    u.size.inc chunk.len
  if u.size == 0:
    # return the CID for a raw nothing
    u.cid = CidSha256("")
  else:
    if u.links.len == 1:
      # take a shortcut use the raw chunk CID
      u.cid = u.links[0].cid
    else:
      u.cid = await store.putDag(u.toCbor)
  result = u
  close fStream

proc addDir*(store: IpldStore; dirPath: string): Future[UnixFsNode] {.async.} =
  var dRoot = newUnixFsRoot()
  for kind, path in walkDir dirPath:
    # need to use `waitFor` in this iterator
    var child: UnixFsNode
    case kind
    of pcFile:
      child = waitFor store.addFile path
    of pcDir:
      child = waitFor store.addDir(path)
    else: continue
    dRoot.add path.extractFilename, child
  let
    dag = dRoot.toCbor
    cid = await store.putDag(dag)
  result = newUnixfsDir(cid)

proc open*(store: IpldStore; cid: Cid): Future[UnixfsNode] {.async.} =
  assert cid.isValid
  assert(not cid.isRaw)
  let raw = await store.get(cid)
  result = parseUnixfs(raw, cid)

proc openDir*(store: IpldStore; cid: Cid): Future[UnixfsNode] {.async.} =
  assert cid.isValid
  let raw = await store.get(cid)
  assert(not raw.isNil)
  result = parseUnixfs(raw, cid)
  assert(result.kind == dirNode)

proc walk*(store: IpldStore; dir: UnixfsNode; path: string; cache = true): Future[UnixfsNode] {.async.} =
  ## Walk a path down a root.
  assert dir.cid.isValid
  assert(path != "")
  assert(dir.kind == dirNode)
  result = dir
  for name in split(path, DirSep):
    if name == "": continue
    if result.kind == fileNode:
      result = nil
      break
    var next = result[name]
    if next.isNil:
      result = nil
      break
    if (next.kind in {shallowFile, shallowDir}) and (not next.cid.isRaw):
      let raw = await store.get(next.cid)
      next = parseUnixfs(raw, next.cid)
      if cache:
        result.entries[name] = next
    result = next

iterator fileChunks*(store: IpldStore; file: UnixfsNode): Future[string] =
  ## Iterate over the links in a file and return futures for link data.
  if file.cid.isRaw:
    yield store.get(file.cid)
  else:
    var i = 0
    while i < file.links.len:
      yield store.get(file.links[i].cid)
      inc i

proc readBuffer*(store: IpldStore; file: UnixfsNode; pos: BiggestInt;
                 buf: pointer; size: int): Future[int] {.async.} =
  ## Read a UnixFS file into a buffer. May return zero for any failure.
  assert(pos > -1)
  var
    filePos = 0
  if pos < file.size:
    if file.cid.isRaw:
      let pos = pos.int
      var blk = await store.get(file.cid)
      if pos < blk.high:
        copyMem(buf, blk[pos].addr, min(blk.len - pos, size))
      result = size
    else:
      for i in 0..file.links.high:
        let linkSize = file.links[i].size
        if filePos <= pos and pos < filePos+linkSize:
          var chunk = await store.get(file.links[i].cid)
          let
            chunkPos = int(pos - filePos)
            n = min(chunk.len-chunkPos, size)
          copyMem(buf, chunk[chunkPos].addr, n)
          result = n
          break
        filePos.inc linkSize

proc path(fs: FileStore; cid: Cid): string =
  ## Generate the file path of a CID within the store.
  assert cid.isValid
  let digest = hex.encode(cid.digest)
  var hashType: string
  case cid.hash
  of MulticodecTag.Sha2_256:
    hashType = "sha256"
  of MulticodecTag.Blake2b_512:
    hashType = "blake2b"
  of MulticodecTag.Blake2s_256:
    hashType = "blake2s"
  else:
    raise newException(SystemError, "unhandled hash type")
  result = hashType / digest[0..1] / digest[2..digest.high]

proc dumpPaths*(paths: var seq[string]; store: FileStore; cid: Cid) =
  ## Recursively dump the constituent FileStore chunk files of a CID to a string seq.
  ## TODO: use CBOR tags rather than reconstitute UnixFS nodes.
  paths.add store.path(cid)
  if cid.isDagCbor:
    let u = waitFor store.open(cid)
    case u.kind:
    of fileNode:
      assert(not u.links.isNil)
      for i in 0..u.links.high:
        paths.add store.path(u.links[i].cid)
    of dirNode:
      for _, child in u.items:
        paths.dumpPaths(store, child.cid)
    else:
      raiseAssert "cannot dump shallow nodes"

iterator dumpPaths*(store: FileStore; cid: Cid): string =
  var collector = newSeq[string]()
  collector.dumpPaths(store, cid)
  for p in collector:
    yield p
