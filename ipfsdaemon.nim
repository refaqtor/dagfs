import asyncdispatch, asyncstreams, httpclient, json, base58.bitcoin, streams, nimSHA2, cbor, tables

import ipld, multiformat

type
  IpfsClient* = ref object
    ## IPFS daemon client.
    http: AsyncHttpClient
    baseUrl: string

proc newIpfsClient*(url = "http://127.0.0.1:5001"): IpfsClient =
  ## Create a client of an IPFS daemon.
  IpfsClient(
    http: newAsyncHttpClient(),
    baseUrl: url)

proc close*(ipfs: IpfsClient) =
  ## Close an active connection to the IPFS daemon.
  close ipfs.http

proc getObject*(ipfs: IpfsClient; link: string): Future[JsonNode] {.async.} =
  ## Retrieve an IPLD object.
  let
    resp = await ipfs.http.request(ipfs.baseUrl & "/api/v0/object/get?arg=" & link)
    body = await resp.body
  result = parseJson(body)

import hex, strutils

proc verifyCborDag*(blk, mhash: string): bool =
  ## Verify an IPLD block with an encoded Mulithash string.
  try:
    var cid: string
    case mhash[0]
    of 0.char:
      cid = mhash[1..mhash.high]
    of 'z':
      cid = bitcoin.decode(mhash[1..mhash.high])
    else:
      return false
    let
      s = newStringStream cid
      cidV = s.readUvarint
    if cidV != 1:
      return false
    let
      multicodec = s.readUvarint.MulticodecTag
    case multicodec
    of MulticodecTag.DAG_CBOR:
      return true
    else:
      return false
    let
      mhTag = s.readUvarint.MulticodecTag
      mhLen = s.readUvarint.int
    case mhTag
    of MulticodecTag.Sha2_256:
      if mhLen != 256 div 8: return false
      var expected: SHA256Digest
      discard s.readData(expected.addr, expected.len)
      let actual = computeSHA256(blk)
      if actual == expected:
        return true
    else:
      return false
  except: discard
  return false


proc getBlock*(ipfs: IpfsClient; cid: Cid): Future[string] {.async.} =
  let
    url = ipfs.baseUrl & "/api/v0/block/get?arg=" & $cid
    resp = await ipfs.http.request(url)
  result = await resp.body

proc putBlockBase(ipfs: IpfsClient; data: string; format = "raw"): Future[tuple[key: string, size: int]] {.async.} =
  # stuff in some MIME horseshit so it works
  ipfs.http.headers = newHttpHeaders({"Content-Type": "multipart/form-data; boundary=------------------------KILL_A_WEBDEV"})
  let
    trash = """

--------------------------KILL_A_WEBDEV
Content-Disposition: form-data; name="file"; filename="myfile"
Content-Type: application/octet-stream

""" & data & """

--------------------------KILL_A_WEBDEV--
    """
    resp = await ipfs.http.post(ipfs.baseUrl & "/api/v0/block/put?format="& format, body=trash)
    body = await resp.body
    js = parseJson body
  # You can tell its written in Go when the JSON keys had to be capitalized
  result = (js["Key"].getStr, js["Size"].getNum.int)

proc putBlock*(ipfs: IpfsClient; blk: string): Future[Cid] {.async.} =
  let
    cid = blk.CidSha256
    resp = await ipfs.putBlockBase(blk, "raw")
    rCid = parseCid resp.key
  if rCid != cid:
    raise newException(SystemError, "wanted " & cid.toHex & " got " & rCid.toHex)
  if blk.len != resp.size:
    raise newException(SystemError, "IPFS daemon returned a size mismatch")
  result = cid

proc putDag*(ipfs: IpfsClient; dag: Dag): Future[Cid] {.async.} =
  let
    blk = dag.toBinary
    cid = blk.CidSha256(MulticodecTag.DagCbor)
    resp = await ipfs.putBlockBase(blk, "cbor")
    rCid = parseCid resp.key
  if rCid != cid:
    raise newException(SystemError, "wanted " & cid.toHex & " got " & rCid.toHex)
  if blk.len != resp.size:
    raise newException(SystemError, "IPFS daemon returned a size mismatch")
  result = cid

proc getDag*(ipfs: IpfsClient; cid: Cid): Future[Dag] {.async.} =
  let
    blk = await ipfs.getBlock(cid)
  result = parseDag blk

proc fileStream*(ipfs: IpfsClient; cid: Cid; fut: FutureStream[string]; recursive = false) {.async.} =
  if cid.isRaw:
    let chunk = await ipfs.getBlock(cid)
    await fut.write chunk
  elif cid.isDagCbor:
    let dag = await ipfs.getDag(cid)
    for link in dag["links"].items:
      let linkCid = parseCid link["cid"].getBytes
      await ipfs.fileStream(linkCid, fut, true)
  else: discard
  if not recursive:
    complete fut
