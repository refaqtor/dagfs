import asyncdispatch, asyncstreams, httpclient, json, base58.bitcoin, streams, nimSHA2, cbor, tables

import ipld, multiformats, ipldstore, unixfs

type
  IpfsStore* = ref IpfsStoreObj
  IpfsStoreObj = object of IpldStoreObj
    ## IPFS daemon client.
    http: HttpClient
    baseUrl: string

  AsyncIpfsStore* = ref AsyncIpfsStoreObj
  AsyncIpfsStoreObj = object of AsyncIpldStoreObj
    ## IPFS daemon client.
    http: AsyncHttpClient
    baseUrl: string

proc ipfsClose(s: IpldStore) =
  var ipfs = IpfsStore(s)
  close ipfs.http

proc ipfsAsyncClose(s: AsyncIpldStore) =
  var ipfs = AsyncIpfsStore(s)
  close ipfs.http

proc putBlock(ipfs: IpfsStore | AsyncIpfsStore; data: string; format = "raw"): Future[tuple[key: string, size: int]] {.multisync.} =
  # stuff in some MIME horseshit so it works
  ipfs.http.headers = newHttpHeaders({
    "Content-Type": "multipart/form-data; boundary=------------------------KILL_A_WEBDEV"})
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

proc ipfsPut(s: IpldStore; blk: string): Cid =
  var ipfs = IpfsStore(s)
  let
    isDag = blk.isUnixfs
    tag = if isDag: MulticodecTag.DagCbor else: MulticodecTag.Raw
    format = if isDag: "cbor" else: "raw"
    cid = blk.CidSha256(tag)
    resp = ipfs.putBlock(blk, format)
    rCid = parseCid resp.key
  if rCid != cid:
    echo "IPFS CID mismatch"
    raise newException(SystemError, "wanted " & cid.toHex & " got " & rCid.toHex)
  if blk.len != resp.size:
    echo "IPFS daemon returned a size mismatch, sent " & $blk.len & " got " & $resp.size
  result = cid

proc ipfsAsyncPut(s: AsyncIpldStore; blk: string): Future[Cid] {.async.} =
  var ipfs = AsyncIpfsStore(s)
  let
    isDag = blk.isUnixfs
    tag = if isDag: MulticodecTag.DagCbor else: MulticodecTag.Raw
    format = if isDag: "cbor" else: "raw"
    cid = blk.CidSha256(tag)
    resp = await ipfs.putBlock(blk, format)
    rCid = parseCid resp.key
  if rCid != cid:
    raise newException(SystemError, "wanted " & cid.toHex & " got " & rCid.toHex)
  if blk.len != resp.size:
    echo "IPFS daemon returned a size mismatch, sent " & $blk.len & " got " & $resp.size
  result = cid

proc ipfsGetBuffer(s: IpldStore; cid: Cid; buf: pointer; len: Natural): int =
  var ipfs = IpfsStore(s)
  let url = ipfs.baseUrl & "/api/v0/block/get?arg=" & $cid
  try:
    var body = ipfs.http.request(url).body
    if not verify(cid, body):
      raise newMissingObject cid
    if body.len > len:
      raise newException(BufferTooSmall, "")
    result = body.len
    copyMem(buf, body[0].addr, result)
  except:
    raise newMissingObject cid

proc ipfsGet(s: IpldStore; cid: Cid; result: var string) =
  var ipfs = IpfsStore(s)
  let url = ipfs.baseUrl & "/api/v0/block/get?arg=" & $cid
  try:
    result = ipfs.http.request(url).body
    if not verify(cid, result):
      raise newMissingObject cid
  except:
    raise newMissingObject cid

proc ipfsAsyncGet(s: AsyncIpldStore; cid: Cid): Future[string] {.async.} =
  var ipfs = AsyncIpfsStore(s)
  let url = ipfs.baseUrl & "/api/v0/block/get?arg=" & $cid
  try:
    let resp = await ipfs.http.request(url)
    result = await resp.body
    if not verify(cid, result):
      raise newMissingObject cid
  except:
    raise newMissingObject cid

proc newIpfsStore*(url = "http://127.0.0.1:5001"): IpfsStore =
  ## Allocate a new synchronous store interface to the IPFS daemon at `url`.
  ## Every block retrieved by `get` is hashed and verified.
  new result
  result.closeImpl = ipfsClose
  result.putImpl = ipfsPut
  result.getBufferImpl = ipfsGetBuffer
  result.getImpl = ipfsGet
  result.http = newHttpClient()
  result.baseUrl = url

proc newAsyncIpfsStore*(url = "http://127.0.0.1:5001"): AsyncIpfsStore =
  ## Allocate a new asynchronous store interface to the IPFS daemon at `url`.
  ## Every block retrieved by `get` is hashed and verified.
  new result
  result.closeImpl = ipfsAsyncClose
  result.putImpl = ipfsAsyncPut
  result.getImpl = ipfsAsyncGet
  result.http = newAsyncHttpClient()
  result.baseUrl = url
