import strutils, streams, tables, cbor, os, math

import ../dagfs, ./stores

type EntryKey = enum
  typeKey = 1,
  dataKey = 2,
  sizeKey = 3

type FsType* = enum
  ufsFile = 0,
  ufsDir = 1

type FsKind* = enum
  fileNode,
  dirNode,
  shallowDir,
  shallowFile

type
  FileLink* = object
    cid*: Cid
    size*: int

  FsNode* = ref object
    cid: Cid
    case kind*: FsKind
    of fileNode:
      links*: seq[FileLink]
    of dirNode:
      entries: OrderedTable[string, FsNode]
    of shallowFile, shallowDir:
      discard
    size: BiggestInt

proc isRaw*(file: FsNode): bool =
  file.links.len == 0

proc cid*(u: FsNode): Cid =
  assert u.cid.isValid
  u.cid

proc isFile*(u: FsNode): bool = u.kind in { fileNode, shallowFile }
proc isDir*(u: FsNode): bool = u.kind in { dirNode, shallowDir }

proc size*(u: FsNode): BiggestInt =
  if u.kind == dirNode: u.entries.len.BiggestInt
  else: u.size

proc newFsRoot*(): FsNode =
  FsNode(
    cid: initCid(),
    kind: dirNode,
    entries: initOrderedTable[string, FsNode](8))

proc newUnixfsFile*(): FsNode =
  FsNode(kind: fileNode, cid: initCid())

proc newUnixfsDir*(cid: Cid): FsNode =
  FsNode(cid: cid, kind: dirNode)

proc add*(root: var FsNode; name: string; node: FsNode) =
  root.entries[name] = node

proc addDir*(root: var FsNode; name: string; cid: Cid) {.deprecated.} =
  assert cid.isValid
  root.add name, FsNode(kind: dirNode, cid: cid)

proc addFile*(root: var FsNode; name: string; cid: Cid; size: BiggestInt) {.deprecated.} =
  assert cid.isValid
  root.add name, FsNode(kind: fileNode, cid: cid, size: size)

proc del*(dir: var FsNode; name: string) =
  dir.entries.del name

const
  DirTag* = 0xda3c80 ## CBOR tag for UnixFS directories
  FileTag* = 0xda3c81 ## CBOR tag for UnixFS files

proc isUnixfs*(bin: string): bool =
  ## Check if a string contains a UnixFS node
  ## in CBOR form.
  var
    s = newStringStream bin
    c: CborParser
  try:
    c.open s
    c.next
    if c.kind == CborEventKind.cborTag:
      result = c.tag == DirTag or c.tag == FileTag
  except ValueError: discard
  close s

proc toCbor*(u: FsNode): CborNode =
  case u.kind
  of fileNode:
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
    raiseAssert "shallow FsNodes can not be encoded"

template parseAssert(cond: bool; msg = "") =
  if not cond: raise newException(
    ValueError,
    if msg == "": "invalid UnixFS CBOR" else: "invalid UnixFS CBOR, " & msg)

proc parseFs*(raw: string; cid: Cid): FsNode =
  ## Parse a string containing CBOR data into a FsNode.
  new result
  result.cid = cid
  var
    c: CborParser
    buf = ""
  open(c, newStringStream(raw))
  next c
  parseAssert(c.kind == CborEventKind.cborTag, "data not tagged")
  let tag = c.tag
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
        let key = c.readInt.EntryKey
        next c
        case key
        of typeKey:
          parseAssert(false, "type file links are not supported")
        of dataKey:
          parseAssert(c.kind == CborEventKind.cborBytes, "CID not encoded as bytes")
          c.readBytes buf
          result.links[i].cid.take buf
        of sizeKey:
          parseAssert(c.kind == CborEventKind.cborPositive, "link size not encoded properly")
          result.links[i].size = c.readInt
          result.size.inc result.links[i].size
  elif tag == DirTag:
    result.kind = dirNode
    next c
    parseAssert(c.kind == CborEventKind.cborMap)
    let dirLen = c.mapLen
    parseAssert(dirLen != -1, raw)
    result.entries = initOrderedTable[string, FsNode](dirLen.nextPowerOfTwo)
    for i in 1 .. dirLen:
      next c
      parseAssert(c.kind == CborEventKind.cborText, raw)
      c.readText buf
      parseAssert(not buf.contains({ '/', '\0'}), raw)
      next c
      parseAssert(c.kind == CborEventKind.cborMap)
      let nAttrs = c.mapLen
      parseAssert(nAttrs > 1, raw)
      let entry = new FsNode
      result.entries[buf] = entry
      for i in 1 .. nAttrs:
        next c
        parseAssert(c.kind == CborEventKind.cborPositive)
        case c.readInt.EntryKey
        of typeKey:
          next c
          case c.readInt.FsType
          of ufsFile: entry.kind = shallowFile
          of ufsDir: entry.kind = shallowDir
        of dataKey:
          next c
          c.readBytes buf
          entry.cid.take buf
        of sizeKey:
          next c
          entry.size = c.readInt
  else:
    parseAssert(false, raw)
  next c
  parseAssert(c.kind == cborEof, "trailing data")

proc toStream*(node: FsNode; s: Stream) =
  let c = node.toCbor()
  c.toStream s

iterator items*(dir: FsNode): (string, FsNode) =
  assert(dir.kind == dirNode)
  for k, v in dir.entries.pairs:
    yield (k, v)

proc containsFile*(dir: FsNode; name: string): bool =
  doAssert(dir.kind == dirNode)
  dir.entries.contains name

proc `[]`*(dir: FsNode; name: string): FsNode =
  if dir.kind == dirNode:
    result = dir.entries.getOrDefault name

proc `[]`*(dir: FsNode; index: int): (string, FsNode) =
  result[0] = ""
  if dir.kind == dirNode:
    var i = 0
    for name, node in dir.entries.pairs:
      if i == index:
        result = (name, node)
        break
      inc i

proc lookupFile*(dir: FsNode; name: string): tuple[cid: Cid, size: BiggestInt] =
  doAssert(dir.kind == dirNode)
  let f = dir.entries[name]
  if f.kind == fileNode:
    result.cid = f.cid
    result.size = f.size

proc addFile*(store: DagfsStore; path: string): FsNode =
  ## Add a file to the store and a FsNode.
  let
    fStream = newFileStream(path, fmRead)
    u = newUnixfsFile()
  u.links = newSeqOfCap[FileLink](1)
  for chunk in fStream.simpleChunks:
    let cid = store.put(chunk)
    u.links.add FileLink(cid: cid, size: chunk.len)
    u.size.inc chunk.len
  if u.size == 0:
    # return the CID for a raw nothing
    u.cid = dagHash("")
  else:
    if u.links.len == 1:
      # take a shortcut use the raw chunk CID
      u.cid = u.links[0].cid
    else:
      u.cid = store.putDag(u.toCbor)
  result = u
  close fStream

proc addDir*(store: DagfsStore; dirPath: string): FsNode =
  var dRoot = newFsRoot()
  for kind, path in walkDir dirPath:
    var child: FsNode
    case kind
    of pcFile:
      child = store.addFile path
    of pcDir:
      child = store.addDir(path)
    else: continue
    dRoot.add path.extractFilename, child
  let
    dag = dRoot.toCbor
    cid = store.putDag(dag)
  result = newUnixfsDir(cid)

proc open*(store: DagfsStore; cid: Cid): FsNode =
  assert cid.isValid
  let raw = store.get(cid)
  result = parseFs(raw, cid)

proc openDir*(store: DagfsStore; cid: Cid): FsNode =
  assert cid.isValid
  var raw = ""
  try: store.get(cid, raw)
  except MissingObject: raise cid.newMissingObject
    # this sucks
  result = parseFs(raw, cid)
  assert(result.kind == dirNode)

proc walk*(store: DagfsStore; dir: FsNode; path: string; cache = true): FsNode =
  ## Walk a path down a root.
  assert(dir.kind == dirNode)
  result = dir
  var raw = ""
  for name in split(path, DirSep):
    if name == "": continue
    if result.kind == fileNode:
      result = nil
      break
    var next = result[name]
    if next.isNil:
      result = nil
      break
    if (next.kind in {shallowFile, shallowDir}):
      store.get(next.cid, raw)
      next = parseFs(raw, next.cid)
      if cache:
        result.entries[name] = next
    result = next

#[
iterator fileChunks*(store: DagfsStore; file: FsNode): string =
  ## Iterate over the links in a file and return futures for link data.
  if file.cid.isRaw:
    yield store.get(file.cid)
  else:
    var
      i = 0
      chunk = ""
    while i < file.links.len:
      store.get(file.links[i].cid, chunk)
      yield chunk
      inc i
]#

proc readBuffer*(store: DagfsStore; file: FsNode; pos: BiggestInt;
                 buf: pointer; size: int): int =
  ## Read a UnixFS file into a buffer. May return zero for any failure.
  assert(pos > -1)
  var
    filePos = 0
    chunk = ""
  if pos < file.size:
    #[
    if file.cid.isRaw:
      let pos = pos.int
      store.get(file.cid, chunk)
      if pos < chunk.high:
        copyMem(buf, chunk[pos].addr, min(chunk.len - pos, size))
      result = size
    else:
    ]#
    block:
      for i in 0..file.links.high:
        let linkSize = file.links[i].size
        if filePos <= pos and pos < filePos+linkSize:
          store.get(file.links[i].cid, chunk)
          let
            chunkPos = int(pos - filePos)
            n = min(chunk.len-chunkPos, size)
          copyMem(buf, chunk[chunkPos].addr, n)
          result = n
          break
        filePos.inc linkSize
