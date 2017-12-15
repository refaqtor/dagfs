import asyncdispatch, asyncfile, streams, strutils, os, ipld, cbor, multiformats, hex, ropes

type
  MissingObject* = ref object of SystemError
    cid*: Cid ## Missing object identifier

proc newMissingObject*(cid: Cid): MissingObject =
  MissingObject(msg: "object missing from store", cid: cid)

type
  IpldStore* = ref IpldStoreObj
  IpldStoreObj* = object of RootObj
    closeImpl*: proc (s: IpldStore) {.nimcall, gcsafe.}
    putImpl*: proc (s: IpldStore; blk: string): Future[Cid] {.nimcall, gcsafe.}
    getImpl*: proc (s: IpldStore; cid: Cid): Future[string] {.nimcall, gcsafe.}
    fileStreamImpl*: proc (s: IpldStore; cid: Cid; fut: FutureStream[string]): Future[void] {.nimcall, gcsafe.}

proc close*(s: IpldStore) =
  ## Close active store resources.
  if not s.closeImpl.isNil: s.closeImpl(s)

proc put*(s: IpldStore; blk: string): Future[Cid] =
  ## Place a raw block to the store.
  assert(not s.putImpl.isNil)
  s.putImpl(s, blk)

proc get*(s: IpldStore; cid: Cid): Future[string] =
  ## Retrieve a raw block from the store.
  assert cid.isValid
  assert(not s.getImpl.isNil)
  s.getImpl(s, cid)
 
{.deprecated: [putRaw: put, getRaw: get].}

proc putDag*(s: IpldStore; dag: Dag): Future[Cid] {.async.} =
  ## Place an IPLD node in the store.
  assert(not s.putImpl.isNil)
  let
    raw = dag.toBinary
    cid = raw.CidSha256(MulticodecTag.DagCbor)
  discard await s.putImpl(s, raw)
  result = cid

proc getDag*(s: IpldStore; cid: Cid): Future[Dag] {.async.} =
  ## Retrieve an IPLD node from the store.
  assert cid.isValid
  assert(not s.getImpl.isNil)
  let raw = await s.getImpl(s, cid)
  assert(not raw.isNil)
  result = parseDag raw

proc fileStream*(s: IpldStore; cid: Cid; fut: FutureStream[string]): Future[void] {.async, deprecated.} =
  ## Asynchronously stream a file from a CID list.
  ## TODO: doesn't need to be a file, can be a raw CID or
  ## a DAG that is simply a list of other CIDs.
  if not s.fileStreamImpl.isNil:
    # use an optimized implementation
    await s.fileStreamImpl(s, cid, fut)
  else:
    # use the simple implementation
    if cid.isRaw:
      let blk = await s.get(cid)
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

proc fsPut(s: IpldStore; blk: string): Future[Cid] {.async.} =
  var fs = FileStore(s)
  let cid = blk.CidSha256
  await fs.putToFile(cid, blk)

proc fsGet(s: IpldStore; cid: Cid): Future[string] =
  result = newFuture[string]("fsGet")
  var fs = FileStore(s)
  let (_, path) = fs.parentAndFile cid
  if existsFile path:
    let file = open(path, fmRead)
    let blk = file.readAll()
    close file
    if cid.verify(blk):
      result.complete blk
    else:
      discard tryRemoveFile path
        # bad block, remove it
  if not result.finished:
    result.fail cid.newMissingObject

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
    let dag = await fs.getDag(cid)
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
  result.putImpl = fsPut
  result.getImpl = fsGet
  result.fileStreamImpl = fsFileStream
  result.root = root
