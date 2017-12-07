import asyncdispatch, asyncfile, streams, strutils, os, ipld, cbor, multiformats, hex, ropes

type
  MissingObject* = object of SystemError
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

proc putRaw*(s: IpldStore; blk: string): Future[Cid] =
  ## Place a raw block to the store.
  assert(not s.putRawImpl.isNil)
  s.putRawImpl(s, blk)

proc getRaw*(s: IpldStore; cid: Cid): Future[string] =
  ## Retrieve a raw block from the store.
  assert cid.isValid
  assert(not s.getRawImpl.isNil)
  s.getRawImpl(s, cid)

proc putDag*(s: IpldStore; dag: Dag): Future[Cid] =
  ## Place an IPLD node in the store.
  assert(not s.putDagImpl.isNil)
  s.putDagImpl(s, dag)

proc getDag*(s: IpldStore; cid: Cid): Future[Dag] {.async.} =
  ## Retrieve an IPLD node from the store.
  assert cid.isValid
  assert(not s.getDagImpl.isNil)
  result = await s.getDagImpl(s, cid)

proc fileStream*(s: IpldStore; cid: Cid; fut: FutureStream[string]): Future[void] {.async.} =
  ## Asynchronously stream a file from a CID list.
  ## TODO: doesn't need to be a file, can be a raw CID or
  ## a DAG that is simply a list of other CIDs.
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

type
  FileStore* = ref FileStoreObj
    ## A store that writes nodes and leafs as files.
  FileStoreObj = object of IpldStoreObj
    root: string

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
    let file = open(path, fmRead)
    let blk = file.readAll()
    close file
    if cid.verify(blk):
      result = blk
    else:
      discard tryRemoveFile path
        # bad block, remove it

proc fsPutDag(s: IpldStore; dag: Dag): Future[Cid] {.async.} =
  var fs = FileStore(s)
  let
    blk = dag.toBinary
    cid = blk.CidSha256(MulticodecTag.DagCbor)
  await fs.putToFile(cid, blk)
  result = cid

proc fsGetDag(s: IpldStore; cid: Cid): Future[Dag] {.async.} =
  let raw = await FileStore(s).fsGetRaw(cid)
  result = parseDag raw

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
    doAssert(not dag.isNil)
    doAssert(dag.contains("links"), $dag & " does not contain 'links'")
    for link in dag.items:
      let cid = link["cid"].getBytes.parseCid
      await fs.fsFileStreamRecurs(cid, fut)
  else:
    doAssert(false)
    discard

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
