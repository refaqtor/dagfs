import asyncdispatch, strutils, multiformats, streams, tables, cbor, os

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
    case kind*: UnixFsKind
    of rootNode:
      entries: OrderedTable[string, UnixFsNode]
    of dirNode:
      dCid*: Cid
    of fileNode:
      fCid*: Cid
      fSize*: BiggestInt

proc newUnixFsRoot*(): UnixFsNode =
  UnixFsNode(kind: rootNode, entries: initOrderedTable[string, UnixFsNode](8))

proc newUnixFsFile*(cid: Cid; size: int): UnixFsNode =
  UnixFsNode(kind: fileNode, fCid: cid, fSize: size)

proc newUnixfsDir*(cid: Cid): UnixFsNode =
  UnixFsNode(kind: dirNode, dCid: cid)

proc cid*(u: UnixfsNode): Cid =
  case u.kind:
  of dirNode:
    u.dCid
  of fileNode:
    u.fCid
  else:
    initCid()

proc addDir*(dir: var UnixFsNode; name: string; cid: Cid) {.deprecated.} =
  doAssert(dir.kind == rootNode)
  dir.entries[name] = UnixFsNode(kind: dirNode, dCid: cid)

proc add*(dir: var UnixFsNode; name: string; node: UnixFsNode) =
  doAssert(dir.kind == rootNode)
  dir.entries[name] = node

proc addFile*(dir: var UnixFsNode; name: string; cid: Cid; size: BiggestInt) {.deprecated.} =
  dir.add name, UnixFsNode(kind: fileNode, fCid: cid, fSize: size)

proc del*(dir: var UnixFsNode; name: string) =
  doAssert(dir.kind == rootNode)
  dir.entries.del name

proc toCbor*(node: UnixFsNode): CborNode =
  result = newCborMap()
  case node.kind:
  of rootNode:
    for k, v in node.entries:
      result[k] = v.toCbor
    # TODO: the CBOR map must be sorted
  of dirNode:
    result[typeKey.int] = newCborInt ufsDir.int
    result[contentKey.int] = node.dCid.toCbor
  of fileNode:
    result[typeKey.int] = newCborInt ufsFile.int
    result[contentKey.int] = node.fCid.toCbor
    result[sizeKey.int] = newCborInt node.fSize

proc parseUnixfs*(c: CborNode): UnixFsNode =
  doAssert(not c.isNil)
  doAssert(c.kind == cborMap)
  result = newUnixFsRoot()
  for k, v in c.map.pairs:
    let
      name = k.getString
      t = v[typeKey.int].getInt.UnixFsType
      cid = v[contentKey.int].getBytes.parseCid
    case t
    of ufsDir:
      result.addDir(name, cid)
    of ufsFile:
      let size = v[sizeKey.int]
      if not size.isNil:
        result.addFile(name, cid, size.getInt)
      else:
        result.addFile(name, cid, 0)
    else:
      discard

proc toStream*(dir: UnixFsNode; s: Stream) =
  doAssert(dir.kind == rootNode)
  let c = dir.toCbor()
  c.toStream s

iterator walk*(node: UnixFsNode): (string, UnixFsNode) =
  doAssert(not node.isNil)
  if node.kind == rootNode:
    for k, v in node.entries.pairs:
      yield (k, v)

proc containsFile*(dir: UnixFsNode; name: string): bool =
  doAssert(dir.kind == rootNode)
  dir.entries.contains name

proc lookupFile*(dir: UnixFsNode; name: string): tuple[cid: Cid, size: BiggestInt] =
  doAssert(dir.kind == rootNode)
  let f = dir.entries[name]
  if f.kind == fileNode:
    result.cid = f.fCid
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
    case kind
    of pcFile:
      let
        file = waitFor store.addFile path
        name = extractFilename path
      dRoot.add name, file
    of pcDir:
      let
        dir = waitFor store.addDir(path)
        name= extractFilename path
      dRoot.add name, dir
    else: continue
  let
    dag = dRoot.toCbor
    cid = await store.putDag(dag)
  result = newUnixfsDir(cid)
