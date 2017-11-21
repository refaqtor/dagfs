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

proc putRaw*(s: IpldStore; blk: string): Future[Cid] {.async.} =
  ## Place a raw block to the store.
  doAssert(not s.putRawImpl.isNil)
  result = await s.putRawImpl(s, blk)

proc getRaw*(s: IpldStore; cid: Cid): Future[string] {.async.} =
  ## Retrieve a raw block from the store.
  doAssert(not s.getRawImpl.isNil)
  result = await s.getRawImpl(s, cid)
  if result.isNil:
    raise newException(MissingObject, $cid)

proc putDag*(s: IpldStore; dag: Dag): Future[Cid] {.async.} =
  ## Place an IPLD node in the store.
  doAssert(not s.putDagImpl.isNil)
  result = await s.putDagImpl(s, dag)

proc getDag*(s: IpldStore; cid: Cid): Future[Dag] {.async.} =
  ## Retrieve an IPLD node from the store.
  doAssert(not s.getDagImpl.isNil)
  result = await s.getDagImpl(s, cid)
  if result.isNil:
    raise newException(MissingObject, $cid)

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
  result = hashType / digest[0..1] / digest[2..digest.high]

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

import unixfs

proc dumpPaths*(result: var seq[string]; store: FileStore; cid: Cid) =
  ## Recursively dump the constituent chunk files of a CID to a string seq.
  result.add store.path(cid)
  if cid.isDagCbor:
    let dag = waitFor store.getDag(cid)
    if dag.kind == cborMap:
      if dag.contains("links"):
        for cbor in dag["links"].items:
          if cbor.contains("cid"):
            result.add store.path(cbor["cid"].getString.parseCid)
      else:
        let ufsNode = parseUnixfs dag
        case ufsNode.kind
        of fileNode:
          for link in dag["links"].items:
            result.dumpPaths(store, link["cid"].getBytes.parseCid)
        of rootNode:
          for _, u in ufsNode.walk:
            result.dumpPaths(store, u.cid)
        of dirNode:
          doAssert(false)

iterator dumpPaths*(store: FileStore; cid: Cid): string =
  var collector = newSeq[string]()
  collector.dumpPaths(store, cid)
  for p in collector:
    yield p

when isMainModule:
  # The 'ipldstore' utility:
  import os, unixfs

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

  iterator params(cmdLine: seq[TaintedString]): string =
    if cmdLine.len == ArgParamIndex+1 and cmdLine[ArgParamIndex] == "-":
      # Dump and split stdin
      let words = stdin.readAll.splitWhitespace
      var i = 0
      while i < words.len:
        yield words[i]
        inc i
    else:
      # feed the parameters as usual
      var i = ArgParamIndex
      while i < cmdLine.len:
        yield cmdLine[i]
        inc i

  proc catCmd(store: FileStore; cmdLine: seq[TaintedString]) =
    for param in cmdLine.params:
      let
        cid = parseCid param
        fut = newFutureStream[string]()
      asyncCheck store.fileStream(cid, fut)
      while true:
        let (valid, chunk) = waitFor fut.read()
        if not valid: break
        stdout.write chunk

  proc mergeCmd(store: FileStore; cmdLine: seq[TaintedString]) =
    var root = newUnixFsRoot()
    for param in cmdLine.params:
      let cid = parseCid param
      if cid.codec != MulticodecTag.Dag_cbor:
        panic param, " is not CBOR encoded"
      let
        dag = waitFor store.getDag(cid)
      try:
        let dir = parseUnixfs dag
        for name, node in dir.walk:
          case node.kind
          of dirNode:
            root.addDir(name, node.dCid)
          of fileNode:
            root.addFile(name, node.fCid, node.fSize)
          else:
            doAssert(false)
      except:
        panic "cannot merge ", $cid
    let cid = waitFor store.putDag(root.toCbor)
    stdout.writeLine cid

  proc ls(store: FileStore; cid: Cid, depth: int) =
    if cid.isDagCbor:
      let dag = waitFor store.getDag(cid)
      doAssert(not dag.isNil)
      block:
        let ufsNode = parseUnixfs dag
        if ufsNode.kind == rootNode:
          for name, u in ufsNode.walk:
            doAssert(not name.isNil)
            doAssert(not u.isNil, name & " is nil")
            for _ in 0..depth: stdout.write('\t')
            case u.kind:
              of fileNode:
                stdout.writeLine(u.fcid, " ", name, "\t", u.fSize)
              of dirNode:
                stdout.writeLine(u.dCid, " ", name)
                ls(store, u.dCid, depth+1)
              else:
                doAssert(false)
    else:
      doAssert(false)

  proc lsCmd(store: FileStore; cmdLine: seq[TaintedString]) =
    for param in cmdLine.params:
      let cid = param.parseCid
      stdout.writeLine(cid)
      ls(store, cid, 0)

  proc mkdirCmd(store: FileStore; cmdLine: seq[TaintedString]) =
    if cmdLine.len != ArgParamIndex+2:
      panic "  ipldstore STORE_PATH mkdir DIR_NAME DIR_CONTENT_CID"
    let
      dName = cmdLine[ArgParamIndex]
      dCid = parseCid cmdLine[ArgParamIndex+1]
      dag = waitFor store.getDag(dCid)
    try:
      let dir = parseUnixfs dag
      if dir.kind == fileNode:
        panic $dCid, " is not a directory"
    except:
      panic "failed to parse directory ", $dCid
    var root = newUnixFsRoot()
    root.addDir(dName, dCid)
    let cid = waitFor store.putDag(root.toCbor)
    stdout.writeLine cid

  proc main() =
    let cmdLine = commandLineParams()
    if cmdLine.len < 3:
      panic "  usage: ipldstore STORE_PATH COMMAND [ARGS, ...]\n" &
        "    commands:\n"&
        "       add: create a root directory containing the supplied paths as top-level nodes\n"&
        "       cat: concatenate a CID, must be a file\n"&
        "      dump: print the store paths that compose a CID\n"&
        "     merge: merge roots\n"&
        "        ls: recursively list a root\n"&
        "     mkdir: create a root containing a named directory for a given CID\n"&
        ""
    let
      store = newFileStore(cmdLine[StoreParamIndex])
      cmdStr = cmdLine[CmdParamIndex]
    case cmdStr
    of "add":
      addCmd(store, cmdLine)
    of "cat":
      catCmd(store, cmdLine)
    of "dump":
      dumpCmd(store, cmdLine)
    of "merge":
      mergeCmd(store, cmdLine)
    of "ls":
      lsCmd(store, cmdLine)
    of "mkdir":
      mkdirCmd(store, cmdLine)
    else:
      panic "unhandled command '", cmdStr, "'"

  main()
