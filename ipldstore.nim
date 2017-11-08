import asyncdispatch, asyncfile, streams, strutils, os, ipld, cbor, multiformats, unixfs

type
  IpldStore* = ref IpldStoreObj
  IpldStoreObj* = object of RootObj
    closeImpl*: proc (s: IpldStore) {.nimcall, gcsafe.}
    putRawImpl*: proc (s: IpldStore; blk: string): Future[Cid] {.nimcall, gcsafe.}
    getRawImpl*: proc (s: IpldStore; cid: Cid): Future[string] {.nimcall, gcsafe.}
    putDagImpl*: proc (s: IpldStore; dag: Dag): Future[Cid] {.nimcall, gcsafe.}
    getDagImpl*: proc (s: IpldStore; cid: Cid): Future[Dag] {.nimcall, gcsafe.}
    fileStreamImpl*: proc (s: IpldStore; cid: Cid; fut: FutureStream[string]): Future[void] {.nimcall, gcsafe.}

proc close*(s: IpldStore) =
  ## Close active store resources.
  if not s.closeImpl.isNil: s.closeImpl(s)

proc putRaw*(s: IpldStore; blk: string): Future[Cid] {.async.} =
  ## Place a raw block to the store.
  result = await s.putRawImpl(s, blk)

proc getRaw*(s: IpldStore; cid: Cid): Future[string] {.async.} =
  ## Retrieve a raw block from the store.
  result = await s.getRawImpl(s, cid)

proc putDag*(s: IpldStore; dag: Dag): Future[Cid] {.async.} =
  ## Place an IPLD node in the store.
  result = await s.putDagImpl(s, dag)

proc getDag*(s: IpldStore; cid: Cid): Future[Dag] {.async.} =
  ## Retrieve an IPLD node from the store.
  result = await s.getDagImpl(s, cid)

proc fileStream*(s: IpldStore; cid: Cid; fut: FutureStream[string]): Future[void] {.async.} =
  ## Asynchronously stream a file from a CID list.
  await s.fileStreamImpl(s, cid, fut)

proc addFile*(store: IpldStore; path: string): (Cid, int) =
  ## Add a file to the store and return the CID and file size.
  let
    fStream = newFileStream(path, fmRead)
    fRoot = newDag()
  var
    fSize = 0
    lastCid: Cid
  for cid, chunk in fStream.simpleChunks:
    discard waitFor store.putRaw(chunk)
    fRoot.add(cid, "", chunk.len)
    lastCid = cid
    fSize.inc chunk.len
  if fRoot["links"].len == 1:
    # take a shortcut and return the bare chunk CID
    result[0] = lastCid
  else:
    result[0] = waitFor store.putDag(fRoot)
  result[1] = fSize

proc addDir*(store: IpldStore; dirPath: string): Cid =
  var dRoot = newUnixFsRoot()
  for kind, path in walkDir dirPath:
    case kind
    of pcFile:
      let
        (fCid, fSize) = store.addFile(path)
        fName = path[path.rfind('/')+1..path.high]
      dRoot.addFile(fName, fCid, fSize)
    of pcDir:
      let
        dCid = store.addDir(path)
        dName = path[path.rfind('/')+1..path.high]
      dRoot.addDir(dname, dCid)
    else: continue
  let c = dRoot.toCbor
  result = waitFor store.putDag(c)

type
  FileStore* = ref FileStoreObj
    ## A store that writes nodes and leafs as files.
  FileStoreObj = object of IpldStoreObj
    root: string

proc parentAndFile(fs: FileStore; cid: Cid): (string, string) =
  let h = cid.toHex
  result[0]  = fs.root / h[0..10]
  result[1]  = result[0]  / h[11..h.high]

proc putToFile(fs: FileStore; cid: Cid; blk: string) {.async.} =
  let (dir, path) = fs.parentAndFile cid
  if not existsDir dir:
    createDir dir
  if not existsFile path:
    let
      tmp = fs.root / "tmp"
      file = openAsync(tmp, fmWrite)
    await file.write(blk)
    close file
    moveFile(tmp, path)

proc fsPutRaw(s: IpldStore; blk: string): Future[Cid] {.async.} =
  var fs = FileStore(s)
  let cid = blk.CidSha256
  await fs.putToFile(cid, blk)

proc fsGetRaw(s: IpldStore; cid: Cid): Future[string] {.async.} =
  var fs = FileStore(s)
  let (_, path) = fs.parentAndFile cid
  if existsFile path:
    let
      file = openAsync(path, fmRead)
      blk = await file.readAll()
    close file
    result = blk
  else:
    result = nil

proc fsPutDag(s: IpldStore; dag: Dag): Future[Cid] {.async.} =
  var fs = FileStore(s)
  let
    blk = dag.toBinary
    cid = blk.CidSha256(MulticodecTag.DagCbor)
  await fs.putToFile(cid, blk)
  result = cid

proc fsGetDag(s: IpldStore; cid: Cid): Future[Dag] {.async.} =
  var fs = FileStore(s)
  let
    raw = await fs.fsGetRaw(cid)
  if not raw.isNil and cid.verify(raw):
    result = parseDag raw
  else:
    result = nil

proc fsFileStreamRecurs(fs: FileStore; cid: Cid; fut: FutureStream[string]) {.async.} =
  if cid.isRaw:
    let (_, path) = fs.parentAndFile cid
    if existsFile path:
      let
        file = openAsync(path, fmRead)
      while true:
        let data = await file.read(4000)
        if data.len == 0:
          break
        await fut.write(data)
      close file
  elif cid.isDagCbor:
    let dag = await fs.fsGetDag(cid)
    for link in dag["links"].items:
      let cid = link["cid"].getBytes.parseCid
      await fs.fsFileStreamRecurs(cid, fut)
  else: discard

proc fsFileStream(s: IpldStore; cid: Cid; fut: FutureStream[string]) {.async.} =
  var fs = FileStore(s)
  await fs.fsFileStreamRecurs(cid, fut)
  complete fut

proc newFileStore*(root: string): FileStore =
  if not existsDir(root):
    createDir root
  new result
  result.putRawImpl = fsPutRaw
  result.getRawImpl = fsGetRaw
  result.putDagImpl = fsPutDag
  result.getDagImpl = fsGetDag
  result.fileStreamImpl = fsFileStream
  result.root = root
