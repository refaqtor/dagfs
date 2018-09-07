import std/streams, std/strutils, std/os
import std/asyncfile, std/asyncdispatch
import cbor
import ../dagfs, ./priv/hex

type
  MissingChunk* = ref object of CatchableError
    cid*: Cid ## Missing chunk identifier
  BufferTooSmall* = object of CatchableError

template raiseMissing*(cid: Cid) =
  raise MissingChunk(msg: "chunk missing from store", cid: cid)

type
  DagfsStore* = ref DagfsStoreObj
  DagfsStoreObj* = object of RootObj
    closeImpl*: proc (s: DagfsStore) {.nimcall, gcsafe.}
    putBufferImpl*: proc (s: DagfsStore; buf: pointer; len: Natural): Cid {.nimcall, gcsafe.}
    putImpl*: proc (s: DagfsStore; chunk: string): Cid {.nimcall, gcsafe.}
    getBufferImpl*: proc (s: DagfsStore; cid: Cid; buf: pointer; len: Natural): int {.nimcall, gcsafe.}
    getImpl*: proc (s: DagfsStore; cid: Cid; result: var string) {.nimcall, gcsafe.}

proc close*(s: DagfsStore) =
  ## Close active store resources.
  if not s.closeImpl.isNil: s.closeImpl(s)

proc putBuffer*(s: DagfsStore; buf: pointer; len: Natural): Cid =
  ## Put a chunk into the store.
  assert(0 < len and len <= maxChunkSize)
  assert(not s.putBufferImpl.isNil)
  s.putBufferImpl(s, buf, len)

proc put*(s: DagfsStore; chunk: string): Cid =
  ## Place a raw block to the store. The hash argument specifies a required
  ## hash algorithm, or defaults to a algorithm choosen by the store
  ## implementation.
  assert(0 < chunk.len and chunk.len <= maxChunkSize)
  assert(not s.putImpl.isNil)
  s.putImpl(s, chunk)

proc getBuffer*(s: DagfsStore; cid: Cid; buf: pointer; len: Natural): int =
  ## Copy a raw block from the store into a buffer pointer.
  assert(cid.isValid)
  assert(0 < len)
  assert(not s.getBufferImpl.isNil)
  result = s.getBufferImpl(s, cid, buf, len)
  assert(result > 0)

proc get*(s: DagfsStore; cid: Cid; result: var string) =
  ## Retrieve a raw block from the store.
  assert(not s.getImpl.isNil)
  assert cid.isValid
  s.getImpl(s, cid, result)
  assert(result.len > 0)

proc get*(s: DagfsStore; cid: Cid): string =
  ## Retrieve a raw block from the store.
  result = ""
  s.get(cid, result)

proc putDag*(s: DagfsStore; dag: CborNode): Cid =
  ## Place an Dagfs node in the store.
  var raw = encode dag
  s.put raw

proc getDag*(s: DagfsStore; cid: Cid): CborNode =
  ## Retrieve an CBOR DAG from the store.
  let stream = newStringStream(s.get(cid))
  result = parseCbor stream
  close stream

type
  FileStore* = ref FileStoreObj
    ## A store that writes nodes and leafs as files.
  FileStoreObj = object of DagfsStoreObj
    root, buf: string

proc parentAndFile(fs: FileStore; cid: Cid): (string, string) =
  ## Generate the parent path and file path of CID within the store.
  let digest = hex.encode(cid.digest)
  result[0]  = fs.root / digest[0..1]
  result[1]  = result[0] / digest[2..digest.high]

proc fsPutBuffer(s: DagfsStore; buf: pointer; len: Natural): Cid =
  var fs = FileStore(s)
  result = dagHash(buf, len)
  if result != zeroChunk:
    let (dir, path) = fs.parentAndFile(result)
    if not existsDir dir:
      createDir dir
    if not existsFile path:
      fs.buf.setLen(len)
      copyMem(addr fs.buf[0], buf, fs.buf.len)
      let
        tmp = fs.root / "tmp"
      writeFile(tmp, fs.buf)
      moveFile(tmp, path)

proc fsPut(s: DagfsStore; chunk: string): Cid =
  var fs = FileStore(s)
  result = dagHash chunk
  if result != zeroChunk:
    let (dir, path) = fs.parentAndFile(result)
    if not existsDir dir:
      createDir dir
    if not existsFile path:
      let
        tmp = fs.root / "tmp"
      writeFile(tmp, chunk)
      moveFile(tmp, path)

proc fsGetBuffer(s: DagfsStore; cid: Cid; buf: pointer; len: Natural): int =
  var fs = FileStore(s)
  let (_, path) = fs.parentAndFile cid
  if existsFile path:
    let fSize = path.getFileSize
    if maxChunkSize < fSize:
      discard tryRemoveFile path
      raiseMissing cid
    if len.int64 < fSize:
      raise newException(BufferTooSmall, "file is $1 bytes, buffer is $2" % [$fSize, $len])
    let file = open(path, fmRead)
    result = file.readBuffer(buf, len)
    close file
  if result == 0:
    raiseMissing cid

proc fsGet(s: DagfsStore; cid: Cid; result: var string) =
  var fs = FileStore(s)
  let (_, path) = fs.parentAndFile cid
  if existsFile path:
    let fSize = path.getFileSize
    if fSize > maxChunkSize:
      discard tryRemoveFile path
      raiseMissing cid
    result.setLen fSize.int
    let
     file = open(path, fmRead)
     n = file.readChars(result, 0, result.len)
    close file
    doAssert(n == result.len)
  else:
    raiseMissing cid

proc newFileStore*(root: string): FileStore =
  ## Blocks retrieved by `get` are not hashed and verified.
  if not existsDir(root):
    createDir root
  new result
  result.putBufferImpl = fsPutBuffer
  result.putImpl = fsPut
  result.getBufferImpl = fsGetBuffer
  result.getImpl = fsGet
  result.root = root
  result.buf = ""
