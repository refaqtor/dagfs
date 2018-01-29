import httpclient, json, base58.bitcoin, streams, nimSHA2, cbor, tables

import ipld, multiformats, ipldstore, unixfs

type
  IpfsStore* = ref IpfsStoreObj
  IpfsStoreObj = object of IpldStoreObj
    ## IPFS daemon client.
    http: HttpClient
    baseUrl: string

proc ipfsClose(s: IpldStore) =
  var ipfs = IpfsStore(s)
  close ipfs.http

proc putBlock(ipfs: IpfsStore; data: string; format = "raw"): tuple[key: string, size: int] =
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
    resp = ipfs.http.post(ipfs.baseUrl & "/api/v0/block/put?format="& format, body=trash)
    body = resp.body
    js = parseJson body
  # You can tell its written in Go when the JSON keys had to be capitalized
  result = (js["Key"].getStr, js["Size"].getNum.int)

proc ipfsPut(s: IpldStore; blk: string; hash: MulticodecTag): Cid =
  doAssert(hash in {MulticodecTag.Invalid, MulticodecTag.Sha2_256})
  var ipfs = IpfsStore(s)
  let
    isDag = blk.isUnixfs
    tag = if isDag: MulticodecTag.DagCbor else: MulticodecTag.Raw
    format = if isDag: "cbor" else: "raw"
  result = blk.CidSha256(tag)
  discard ipfs.putBlock(blk, format)
    # IPFS returns a different hash. Whatever.

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
