import asyncdispatch, asyncstreams, httpclient, json, base58.bitcoin, streams, nimSHA2, cbor, tables

import ipld, multiformats, store

type
  IpfsStore* = ref IpfsStoreObj
  IpfsStoreObj = object of StoreObj
    ## IPFS daemon client.
    http: AsyncHttpClient
    baseUrl: string

proc ipfsClose(s: Store) =
  var ipfs = IpfsStore(s)
  close ipfs.http

proc putBlockBase(ipfs: IpfsStore; data: string; format = "raw"): Future[tuple[key: string, size: int]] {.async.} =
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

proc ipfsPutRaw(s: Store; blk: string): Future[Cid] {.async.} =
  var ipfs = IpfsStore(s)
  let
    cid = blk.CidSha256
    resp = await ipfs.putBlockBase(blk, "raw")
    rCid = parseCid resp.key
  if rCid != cid:
    raise newException(SystemError, "wanted " & cid.toHex & " got " & rCid.toHex)
  if blk.len != resp.size:
    raise newException(SystemError, "IPFS daemon returned a size mismatch")
  result = cid

proc ipfsPutDag(s: Store; dag: Dag): Future[Cid] {.async.} =
  var ipfs = IpfsStore(s)
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

proc ipfsGetRaw(s: Store; cid: Cid): Future[string] {.async.} =
  var ipfs = IpfsStore(s)
  let
    url = ipfs.baseUrl & "/api/v0/block/get?arg=" & $cid
    resp = await ipfs.http.request(url)
  result = await resp.body

proc ipfsGetDag(s: Store; cid: Cid): Future[Dag] {.async.} =
  var ipfs = IpfsStore(s)
  let
    blk = await ipfs.ipfsGetRaw(cid)
  result = parseDag blk

proc ipfsFileStreamRecurse(ipfs: IpfsStore; cid: Cid; fut: FutureStream[string]) {.async.} =
  if cid.isRaw:
    let chunk = await ipfs.ipfsGetRaw(cid)
    await fut.write chunk
  elif cid.isDagCbor:
    let dag = await ipfs.getDag(cid)
    for link in dag["links"].items:
      let linkCid = parseCid link["cid"].getBytes
      await ipfs.fileStream(linkCid, fut)
  else: discard

proc ipfsFileStream(s: Store; cid: Cid; fut: FutureStream[string]) {.async.} =
  var ipfs = IpfsStore(s)
  await ipfs.ipfsFileStreamRecurse(cid, fut)
  complete fut

proc newIpfsStore*(url = "http://127.0.0.1:5001"): IpfsStore =
  new result
  result.closeImpl = ipfsClose
  result.putRawImpl = ipfsPutRaw
  result.getRawImpl = ipfsGetRaw
  result.putDagImpl = ipfsPutDag
  result.getDagImpl = ipfsGetDag
  result.fileStreamImpl = ipfsFileStream
  result.http = newAsyncHttpClient()
  result.baseUrl = url
