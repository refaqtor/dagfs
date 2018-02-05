import streams, strutils, os, ipld, cbor, multiformats, hex

type
  MissingObject* = ref object of SystemError
    cid*: Cid ## Missing object identifier

  BufferTooSmall* = object of SystemError

proc newMissingObject*(cid: Cid): MissingObject =
  MissingObject(msg: "object missing from store", cid: cid)

type
  IpldStore* = ref IpldStoreObj
  IpldStoreObj* = object of RootObj
    closeImpl*: proc (s: IpldStore) {.nimcall, gcsafe.}
    putImpl*: proc (s: IpldStore; blk: string; hash: MultiCodecTag): Cid {.nimcall, gcsafe.}
    getBufferImpl*: proc (s: IpldStore; cid: Cid; buf: pointer; len: Natural): int {.nimcall, gcsafe.}
    getImpl*: proc (s: IpldStore; cid: Cid; result: var string) {.nimcall, gcsafe.}

proc close*(s: IpldStore) =
  ## Close active store resources.
  if not s.closeImpl.isNil: s.closeImpl(s)

proc put*(s: IpldStore; blk: string; hash = MulticodecTag.Invalid): Cid =
  ## Place a raw block to the store. The hash argument specifies a required
  ## hash algorithm, or defaults to a algorithm choosen by the store
  ## implementation.
  assert(not s.putImpl.isNil)
  assert(blk.len > 0)
  s.putImpl(s, blk, hash)

proc getBuffer*(s: IpldStore; cid: Cid; buf: pointer; len: Natural): int =
  ## Copy a raw block from the store into a buffer pointer.
  assert cid.isValid
  assert(not s.getBufferImpl.isNil)
  result = s.getBufferImpl(s, cid, buf, len)
  assert(result > 0)

proc get*(s: IpldStore; cid: Cid; result: var string) =
  ## Retrieve a raw block from the store.
  assert(not s.getImpl.isNil)
  assert cid.isValid
  assert(not result.isNil)
  s.getImpl(s, cid, result)
  assert(result.len > 0)

proc get*(s: IpldStore; cid: Cid): string =
  ## Retrieve a raw block from the store.
  result = ""
  s.get(cid, result)

proc putDag*(s: IpldStore; dag: CborNode): Cid =
  ## Place an IPLD node in the store.
  var raw = dag.toBinary
  result = s.put raw
  result.codec = MulticodecTag.DagCbor

proc getDag*(s: IpldStore; cid: Cid): CborNode =
  ## Retrieve an CBOR DAG from the store.
  let stream = newStringStream(s.get(cid))
  result = parseCbor stream
  close stream

type
  FileStore* = ref FileStoreObj
    ## A store that writes nodes and leafs as files.
  FileStoreObj = object of IpldStoreObj
    root: string

proc parentAndFile(fs: FileStore; cid: Cid): (string, string) =
  ## Generate the parent path and file path of CID within the store.
  let digest = hex.encode(cid.digest)
  var hashType: string
  case cid.hash
  of MulticodecTag.Sha2_256:
    hashType = "sha256"
  of MulticodecTag.Blake2b_256:
    hashType = "blake2b256"
  else:
    raise newException(SystemError, "unhandled hash type")
  result[0]  = fs.root / hashType / digest[0..1]
  result[1]  = result[0]  / digest[2..digest.high]

proc fsPut(s: IpldStore; blk: string; hash: MulticodecTag): Cid =
  var fs = FileStore(s)
  case hash:
  of MulticodecTag.Invalid, MulticodecTag.Blake2b_256:
    result = blk.CidBlake2b256
  of MulticodecTag.Sha2_256:
    result = blk.CidSha256
  else:
    raiseAssert("unsupported hash type " & $hash)
  let (dir, path) = fs.parentAndFile(result)
  if not existsDir dir:
    createDir dir
  if not existsFile path:
    let
      tmp = fs.root / "tmp"
    writeFile(tmp, blk)
    moveFile(tmp, path)

proc fsGetBuffer(s: IpldStore; cid: Cid; buf: pointer; len: Natural): int =
  var fs = FileStore(s)
  let (_, path) = fs.parentAndFile cid
  if existsFile path:
    let fSize = path.getFileSize
    if fSize > MaxBlockSize:
      discard tryRemoveFile path
      raise cid.newMissingObject
    if fSize > len.int64:
      raise newException(BufferTooSmall, "")
    let file = open(path, fmRead)
    result = file.readBuffer(buf, len)
    close file
  if result == 0:
    raise cid.newMissingObject

proc fsGet(s: IpldStore; cid: Cid; result: var string) =
  var fs = FileStore(s)
  let (_, path) = fs.parentAndFile cid
  if existsFile path:
    let fSize = path.getFileSize
    if fSize > MaxBlockSize:
      discard tryRemoveFile path
      raise cid.newMissingObject
    result.setLen fSize.int
    let
     file = open(path, fmRead)
     n = file.readChars(result, 0, result.len)
    close file
    doAssert(n == result.len)
  else:
    raise cid.newMissingObject

proc newFileStore*(root: string): FileStore =
  ## Blocks retrieved by `get` are not hashed and verified.
  if not existsDir(root):
    createDir root
  new result
  result.putImpl = fsPut
  result.getBufferImpl = fsGetBuffer
  result.getImpl = fsGet
  result.root = root