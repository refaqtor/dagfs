import asyncdispatch, ipld, ipfsdaemon, os, strutils, multiformat, streams, cbor

when not declared(commandLineParams):
  {.error: "POSIX only utility".}

proc addFile(ipfs: IpfsClient; path: string): (Cid, int) =
  let
    fStream = newFileStream(path, fmRead)
    fRoot = newDag()
  var
    fSize = 0
    lastCid: Cid
  for cid, chunk in fStream.simpleChunks:
    discard waitFor ipfs.putBlock(chunk)
    fRoot.add(cid, "", chunk.len)
    lastCid = cid
    fSize.inc chunk.len
  if fRoot["links"].len == 1:
    # take a shortcut and return the bare chunk CID
    result[0] = lastCid
  else:
    result[0] = waitFor ipfs.putDag(fRoot)
  result[1] = fSize

proc addDir(ipfs: IpfsClient; dirPath: string): Cid =
  let
    dRoot = newDag()
  for kind, path in walkDir dirPath:
    case kind
    of pcFile:
      let
        (fCid, fSize) = ipfs.addFile(path)
        fName = path[path.rfind('/')+1..path.high]
      dRoot.add(fCid, fName, fSize)
    of pcDir:
      let
        dCid = ipfs.addDir(path)
        dName = path[path.rfind('/')+1..path.high]
      dRoot.add(dCid, dName, 0)
    else: continue
  result = waitFor ipfs.putDag(dRoot)

proc addCmd(params: seq[TaintedString]) =
  let ipfs = newIpfsClient()
  for path in params[1.. params.high]:
    let info = getFileInfo(path, followSymlink=false)
    case info.kind
    of pcFile:
      let (cid, size) = ipfs.addFile path
      stdout.writeLine cid, " ", size, " ", path
    of pcDir:
      let cid = ipfs.addDir path
      stdout.writeLine cid, " ", path
    else: continue
  close ipfs

proc mergeCmd(params: seq[TaintedString]) =
  let
    ipfs = newIpfsClient()
    root = newDag()

  for cidStr in params[1..params.high]:
    let cid = parseCid cidStr
    if cid.codec != MulticodecTag.Dag_cbor:
      stderr.writeLine cidStr, " is not CBOR encoded"
      quit QuitFailure
    let
      raw = waitFor ipfs.getBlock(cid)
      subDag = parseDag raw
    root.merge subDag
  let cid = waitFor ipfs.putDag(root)
  stdout.writeLine cid
  close ipfs

proc infoCmd(params: seq[TaintedString]) {.async.} =
  let
    ipfs = newIpfsClient()
  for cidStr in params[1..params.high]:
    let
      cid = parseCid cidStr
    stdout.writeLine cid.toHex
    if cid.isDagCbor:
      let dag = await ipfs.getDag(cid)
      stdout.writeLine dag
  close ipfs

proc catCmd(params: seq[TaintedString]) {.async.} =
  let
    ipfs = newIpfsClient()
  for param in params[1..params.high]:
    let
      cid = parseCid param
      fut = newFutureStream[string]()
    asyncCheck ipfs.fileStream(cid, fut)
    while true:
      let (valid, chunk) = await fut.read()
      if not valid: break
      stdout.write chunk

proc main() =
  let params = commandLineParams()
  if params.len < 2:
    quit "insufficient parameters"

  case params[0]
  of "add":
    addCmd params
  of "merge":
    mergeCmd params
  of "info":
    waitFor infoCmd(params)
  of "cat":
    waitFor catCmd(params)
  quit()

main()
