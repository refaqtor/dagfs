import ipld, strutils, multiformats, streams, tables, cbor, os

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
  UnixFsNode* = object
    case kind*: UnixFsKind
    of rootNode:
      entries: OrderedTable[string, UnixFsNode]
    of dirNode:
      dCid*: Cid
    of fileNode:
      fCid*: Cid
      size: BiggestInt

proc newUnixFsRoot*(): UnixFsNode =
  UnixFsNode(kind: rootNode, entries: initOrderedTable[string, UnixFsNode](8))

proc addDir*(dir: var UnixFsNode; name: string; cid: Cid) =
  doAssert(dir.kind == rootNode)
  dir.entries[name] = UnixFsNode(kind: dirNode, dCid: cid)

proc addFile*(dir: var UnixFsNode; name: string; cid: Cid; size: BiggestInt) =
  doAssert(dir.kind == rootNode)
  dir.entries[name] = UnixFsNode(kind: fileNode, fCid: cid, size: size)

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
    if node.size != 0:
      result[sizeKey.int] = newCborInt node.size

proc parseUnixfs*(c: CborNode): UnixFsNode =
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
      let size = v[sizeKey.int].getInt
      result.addFile(name, cid, size)
    else:
      discard

proc toStream*(dir: UnixFsNode; s: Stream) =
  doAssert(dir.kind == rootNode)
  let c = dir.toCbor()
  c.toStream s

iterator walk*(node: UnixFsNode): (string, UnixFsNode) =
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
    result.size = f.size
