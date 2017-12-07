import asyncdispatch, strutils, multiformats, streams, tables, cbor, os, hex

import ipld, ipldstore

type EntryKey = enum
  typeKey = 1,
  contentKey = 2,
  sizeKey = 3

type UnixFsType* = enum
  ufsFile = 0,
  ufsDir = 1

type UnixFsKind* = enum
  rootNode,
  dirNode,
  fileNode

type
  UnixFsNode* = ref object
    cid: Cid
    case kind*: UnixFsKind
    of rootNode:
      entries: OrderedTable[string, UnixFsNode]
    of dirNode:
      discard
    of fileNode:
      fSize*: BiggestInt

proc cid*(u: UnixFsNode): Cid =
  assert u.cid.isValid
  u.cid

proc isFile*(u: UnixfsNode): bool = u.kind == fileNode

proc isDir*(u: UnixfsNode): bool = u.kind in {rootNode, dirNode}

proc newUnixFsRoot*(): UnixFsNode =
  UnixFsNode(
    cid: initCid(),
    kind: rootNode,
    entries: initOrderedTable[string, UnixFsNode](8))

proc newUnixFsFile*(cid: Cid; size: int): UnixFsNode =
  UnixFsNode(kind: fileNode, cid: cid, fSize: size)

proc newUnixfsDir*(cid: Cid): UnixFsNode =
  UnixFsNode(cid: cid, kind: dirNode)

proc add*(root: var UnixFsNode; name: string; node: UnixFsNode) =
  root.entries[name] = node

proc addDir*(root: var UnixFsNode; name: string; cid: Cid) {.deprecated.} =
  assert cid.isValid
  root.add name, UnixFsNode(kind: dirNode, cid: cid)

proc addFile*(root: var UnixFsNode; name: string; cid: Cid; size: BiggestInt) {.deprecated.} =
  assert cid.isValid
  root.add name, UnixFsNode(kind: fileNode, cid: cid, fSize: size)

proc del*(dir: var UnixFsNode; name: string) =
  dir.entries.del name

proc toCbor*(root: UnixFsNode): CborNode =
  result = newCborMap()
  for name, node in root.entries:
    var entry = newCborMap()
    case node.kind
    of rootNode, dirNode:
      entry[typeKey.int] = newCborInt ufsDir.int
      entry[contentKey.int] = node.cid.toCbor
    of fileNode:
      entry[typeKey.int] = newCborInt ufsFile.int
      entry[contentKey.int] = node.cid.toCbor
      entry[sizeKey.int] = newCborInt node.fSize
    result[name] = entry
  # TODO: the CBOR maps must be sorted

proc parseUnixfs*(c: CborNode; cid: Cid): UnixFsNode =
  doAssert(not c.isNil)
  doAssert(c.kind == cborMap)
  result = newUnixFsRoot()
  result.cid = cid
  for k, v in c.map.pairs:
    let
      name = k.getString
      t = v[typeKey.int].getInt.UnixFsType
      subCid = v[contentKey.int].getBytes.parseCid
    case t
    of ufsDir:
      result.addDir(name, subCid)
    of ufsFile:
      let size = v[sizeKey.int]
      if not size.isNil:
        result.addFile(name, subCid, size.getInt)
      else:
        result.addFile(name, subCid, 0)
    else:
      discard

proc toStream*(dir: UnixFsNode; s: Stream) =
  doAssert(dir.kind == rootNode)
  let c = dir.toCbor()
  c.toStream s

iterator walk*(node: UnixFsNode): (string, UnixFsNode) {.deprecated.} =
  doAssert(not node.isNil)
  if node.kind == rootNode:
    for k, v in node.entries.pairs:
      yield (k, v)

iterator items*(root: UnixFsNode): (string, UnixFsNode) =
  assert(not root.isNil)
  assert(root.kind == rootNode)
  for k, v in root.entries.pairs:
    yield (k, v)

proc containsFile*(dir: UnixFsNode; name: string): bool =
  doAssert(dir.kind == rootNode)
  dir.entries.contains name

proc `[]`*(dir: UnixFsNode; name: string): UnixFsNode =
  if dir.kind == rootNode:
    result = dir.entries.getOrDefault name

proc `[]`*(dir: UnixFsNode; index: int): (string, UnixfsNode) =
  result[0] = ""
  if dir.kind == rootNode:
    var i = 0
    for name, node in dir.entries.pairs:
      if i == index:
        result = (name, node)
        break
      inc i

proc lookupFile*(dir: UnixFsNode; name: string): tuple[cid: Cid, size: BiggestInt] =
  doAssert(dir.kind == rootNode)
  let f = dir.entries[name]
  if f.kind == fileNode:
    result.cid = f.cid
    result.size = f.fSize

proc addFile*(store: IpldStore; path: string): Future[UnixFsNode] {.async.} =
  ## Add a file to the store and return the CID and file size.
  var
    fCid = initCid()
    fSize = 0
  let
    fStream = newFileStream(path, fmRead)
    fRoot = newDag()
  for cid, chunk in fStream.simpleChunks:
    discard await store.putRaw(chunk)
    fRoot.add(cid, chunk.len)
    fCid = cid
    fSize.inc chunk.len
  if fSize == 0:
    # return the CID for a raw nothing
    fCid = CidSha256("")
  else:
    if fRoot["links"].len == 1:
      # take a shortcut and return the bare chunk CID
      discard
    else:
      fCid = await store.putDag(fRoot)
    close fStream
  result = newUnixfsFile(fCid, fSize)

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

proc openDir*(store: IpldStore; cid: Cid): Future[UnixfsNode] {.async.} =
  assert cid.isValid
  let dag = await store.getDag(cid)
  result = parseUnixfs(dag, cid)
  assert(result.kind == rootNode)

proc rootName(path: string): string =
  var first, last: int
  while first < path.len and path[first] == DirSep:
    inc first
  last = first
  while last < path.high and path[last+1] != DirSep:
    inc last
  path[first..last]

proc walk*(store: IpldStore; dir: UnixfsNode; path: string): Future[UnixfsNode] {.async.} =
  ## Walk a path down a root.
  assert dir.cid.isValid
  assert(path != "")
  result = dir
  for name in split(path, DirSep):
    if name == "": continue
    if result.kind == fileNode:
      result = nil
      break
    result = result[name]
    assert result.cid.isValid
    if result.isNil: break
    if result.kind == dirNode:
      result = await store.openDir result.cid
        # fetch and parse the directory as a root

proc readBuffer*(store: IpldStore; file: UnixfsNode; pos: BiggestInt;
                 buf: pointer; size: int): Future[int] {.async.} =
  ## Read a UnixFS file into a buffer. May return zero for any failure.
  assert(pos > -1)
  var
    filePos = 0
    bufPos = 0
  if pos < file.fSize:
    if file.cid.isRaw:
      let pos = pos.int
      var blk = await store.getRaw(file.cid)
      if pos < blk.high:
        copyMem(buf, blk[pos].addr, min(blk.len - pos, size))
    elif file.cid.isDagCbor:
      let dag = await store.getDag(file.cid)
      for link in dag["links"].items:
        let linkSize = link["size"].getInt().int
        if filePos <= pos and pos < filePos+linkSize:
          let linkCid = link["cid"].getBytes.parseCid
          var chunk = await store.getRaw(linkCid)
          let
            chunkPos = int(pos - filePos)
            n = min(chunk.len-chunkPos, size)
          copyMem(buf, chunk[chunkPos].addr, n)
          return n
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
    let dag = waitFor store.getDag(cid)
    if dag.kind == cborMap:
      if dag.contains("links"):
        for cbor in dag["links"].items:
          if cbor.contains("cid"):
            paths.add store.path(cbor["cid"].getString.parseCid)
      else:
        let ufsNode = parseUnixfs(dag, cid)
        case ufsNode.kind
        of fileNode:
          for link in dag["links"].items:
            paths.dumpPaths(store, link["cid"].getBytes.parseCid)
        of rootNode:
          for _, u in ufsNode.walk:
            paths.dumpPaths(store, u.cid)
        of dirNode:
          raiseAssert "cannot dump child dir"

iterator dumpPaths*(store: FileStore; cid: Cid): string =
  var collector = newSeq[string]()
  collector.dumpPaths(store, cid)
  for p in collector:
    yield p
