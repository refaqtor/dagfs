import asyncdispatch, asyncfile, streams, strutils, os, ipld, cbor, multiformats, unixfs, hex

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
  doAssert(not s.putRawImpl.isNil)
  result = await s.putRawImpl(s, blk)

proc getRaw*(s: IpldStore; cid: Cid): Future[string] {.async.} =
  ## Retrieve a raw block from the store.
  doAssert(not s.getRawImpl.isNil)
  result = await s.getRawImpl(s, cid)

proc putDag*(s: IpldStore; dag: Dag): Future[Cid] {.async.} =
  ## Place an IPLD node in the store.
  doAssert(not s.putDagImpl.isNil)
  result = await s.putDagImpl(s, dag)

proc getDag*(s: IpldStore; cid: Cid): Future[Dag] {.async.} =
  ## Retrieve an IPLD node from the store.
  doAssert(not s.getDagImpl.isNil)
  result = await s.getDagImpl(s, cid)

proc fileStream*(s: IpldStore; cid: Cid; fut: FutureStream[string]): Future[void] {.async.} =
  ## Asynchronously stream a file from a CID list.
  if not s.fileStreamImpl.isNil:
    # use an optimized implementation
    await s.fileStreamImpl(s, cid, fut)
  else:
    # use the simple implementation
    if cid.isRaw:
      let blk = await s.getRaw(cid)
      await fut.write(blk)
    elif cid.isDagCbor:
      let dag = await s.getDag(cid)
      for link in dag["links"].items:
        let subCid = link["cid"].getBytes.parseCid
        await fileStream(s, subCid, fut)
    else:
      discard

proc addFile*(store: IpldStore; path: string): (Cid, int) =
  ## Add a file to the store and return the CID and file size.
  let
    fStream = newFileStream(path, fmRead)
    fRoot = newDag()
  result = (initCid(), 0)
  for cid, chunk in fStream.simpleChunks:
    discard waitFor store.putRaw(chunk)
    fRoot.add(cid, "", chunk.len)
    result[0] = cid
    result[1].inc chunk.len
  if fRoot["links"].len == 1:
    # take a shortcut and return the bare chunk CID
    discard
  else:
    result[0] = waitFor store.putDag(fRoot)

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

proc path(fs: FileStore; cid: Cid): string =
  ## Generate the file path of a CID within the store.
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
  result = fs.root / hashType / digest[0..1] / digest[2..digest.high]

proc parentAndFile(fs: FileStore; cid: Cid): (string, string) {.deprecated.} =
  ## Generate the parent path and file path of CID within the store.
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
  result[0]  = fs.root / hashType / digest[0..1]
  result[1]  = result[0]  / digest[2..digest.high]

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

when isMainModule:
  # The 'ipldstore' utility:
  import os

  when not declared(commandLineParams):
    {.error: "'ipldstore' is a POSIX only utility".}

  const
    # Argument order inspired the cruel travesty that is every systemd utility
    StoreParamIndex = 0
    CmdParamIndex = 1
    ArgParamIndex = 2

  proc panic(msg: varargs[string]) =
    stderr.writeLine(msg)
    quit QuitFailure

  proc addCmd(store: FileStore; params: seq[TaintedString]) {.async.} =
    for path in params[ArgParamIndex.. params.high]:
      let info = getFileInfo(path, followSymlink=false)
      case info.kind
      of pcFile:
        let (cid, size) = store.addFile path
        stdout.writeLine cid, " ", size, " ", path
      of pcDir:
        let cid = store.addDir path
        stdout.writeLine cid, " ", path
      else: continue

  proc catCmd(store: FileStore; params: seq[TaintedString]) {.async.} =
    for param in params[ArgParamIndex..params.high]:
      let
        cid = parseCid param
        fut = newFutureStream[string]()
      asyncCheck store.fileStream(cid, fut)
      while true:
        let (valid, chunk) = await fut.read()
        if not valid: break
        stdout.write chunk

  proc dumpCmd(store: FileStore; params: seq[TaintedString]) {.async.} =
    for param in params[ArgParamIndex..params.high]:
      let
        cid = parseCid param
        path = store.path cid
      stdout.writeLine path

  proc main() =
    let params = commandLineParams()
    if params.len < 3:
      panic "usage: ipldstore STORE_PATH COMMAND [ARGS, ...]"
    let
      store = newFileStore(params[StoreParamIndex])
      cmdStr = params[CmdParamIndex]
    case cmdStr
    of "add":
      waitFor addCmd(store, params)
    of "cat":
      waitFor catCmd(store, params)
    of "dump":
      waitFor dumpCmd(store, params)
    else:
      panic "unhandled command '", cmdStr, "'"

  main()
