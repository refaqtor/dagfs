import std/asyncnet, std/asyncdispatch, std/streams, cbor
import ../dagfs, ./stores

proc toInt(chars: openArray[char]): BiggestInt =
  for c in chars.items:
    result = (result shl 8) or c.BiggestInt

const
  defaultPort = Port(1024)
  errTag = toInt "err"
  getTag = toInt "get"
  putTag = toInt "put"

type
  TcpServer* = ref TcpServerObj
  TcpServerObj = object
    sock: AsyncSocket
    store: DagfsStore

proc newTcpServer*(store: DagfsStore; port = defaultPort): TcpServer =
  ## Create a new TCP server that serves `store`.
  result = TcpServer(sock: newAsyncSocket(buffered=false), store: store)
  result.sock.bindAddr(port, "127.0.0.1")
  result.sock.setSockOpt(OptReuseAddr, true)
    # some braindead unix cruft

proc process(server: TcpServer; client: AsyncSocket) {.async.} =
  ## Process messages from a TCP client.
  var
    tmpBuf = ""
    blkBuf = ""
  block loop:
    while not client.isClosed:
      block:
        tmpBuf.setLen(256)
        let n = await client.recvInto(addr tmpBuf[0], tmpBuf.len)
        if n < 40: break loop
        tmpBuf.setLen n
      let
        tmpStream = newStringStream(tmpBuf)
        cmd = parseCbor tmpStream
      when defined(tcpDebug):
        echo "C: ", cmd
      if cmd.kind != cborArray or cmd.seq.len < 3: break loop
      case cmd[0].getInt
      of errTag:
        break loop
      of getTag:
        let
          cid = cmd[1].toCid
          resp = newCborArray()
        try:
          server.store.get(cid, blkBuf)
          resp.add(putTag)
          resp.add(cmd[1])
          resp.add(blkBuf.len)
          when defined(tcpDebug):
            echo "S: ", resp
          await client.send(encode resp)
          await client.send(blkBuf)
        except:
          resp.add(errTag)
          resp.add(cmd[1])
          resp.add(getCurrentExceptionMsg())
          when defined(tcpDebug):
            echo "S: ", resp
          await client.send(encode resp)
      of putTag:
          # TODO: check if the block is already in the store
        let resp = newCborArray()
        resp.add(newCborInt getTag)
        resp.add(cmd[1])
        resp.add(cmd[2])
        when defined(tcpDebug):
          echo "S: ", resp
        await client.send(encode resp)
        doAssert(cmd[2].getInt <= maxBlockSize)
        tmpBuf.setLen cmd[2].getInt
        blkBuf.setLen 0
        while blkBuf.len < cmd[2].getInt:
          let n = await client.recvInto(tmpBuf[0].addr, tmpBuf.len)
          if n == 0: break loop
          tmpBuf.setLen n
          blkBuf.add tmpBuf
        let cid = server.store.put(blkBuf)
        doAssert(cid == cmd[1].toCid)
      else: break loop
  close client

proc serve*(server: TcpServer) {.async.} =
  ## Service client connections to server.
  listen server.sock
  while not server.sock.isClosed:
    let (host, sock) = await server.sock.acceptAddr()
    asyncCheck server.process(sock)

proc close*(server: TcpServer) =
  ## Close a TCP server.
  close server.sock

type
  TcpClient* = ref TcpClientObj
  TcpClientObj = object of DagfsStoreObj
    sock: AsyncSocket
    buf: string

proc tcpClientPut(s: DagfsStore; blk: string): Cid =
  var client = TcpClient(s)
  result = dagHash blk
  if result != zeroBlock:
    block put:
      let cmd = newCborArray()
      cmd.add(newCborInt putTag)
      cmd.add(toCbor result)
      cmd.add(newCborInt blk.len)
      when defined(tcpDebug):
        echo "C: ", cmd
      waitFor client.sock.send(encode cmd)
    block get:
      let
        respBuf = waitFor client.sock.recv(256)
        s = newStringStream(respBuf)
        resp = parseCbor s
      when defined(tcpDebug):
        echo "S: ", resp
      case resp[0].getInt
      of getTag:
        if resp[1] == result:
          waitFor client.sock.send(blk)
        else:
          close client.sock
          raiseAssert "server sent out-of-order \"get\" message"
      of errTag:
        raiseAssert resp[2].getText
      else:
        raiseAssert "invalid server message"

proc tcpClientGetBuffer(s: DagfsStore; cid: Cid; buf: pointer; len: Natural): int =
  assert(getTag != 0)
  var client = TcpClient(s)
  block get:
    let cmd = newCborArray()
    cmd.add(newCborInt getTag)
    cmd.add(toCbor cid)
    cmd.add(newCborInt len)
    when defined(tcpDebug):
      echo "C: ", cmd
    waitFor client.sock.send(encode cmd)
  block put:
    let
      respBuf = waitFor client.sock.recv(256, {Peek})
      s = newStringStream(respBuf)
      resp = parseCbor s
      skip = s.getPosition
    when defined(tcpDebug):
      echo "S: ", resp
    case resp[0].getInt
    of putTag:
      doAssert(resp[1] == cid)
      result = resp[2].getInt.int
      doAssert(skip <= len and result <= len)
      discard waitFor client.sock.recvInto(buf, skip)
      result = waitFor client.sock.recvInto(buf, result)
    of errTag:
      raise MissingObject(msg: resp[2].getText, cid: cid)
    else:
      raise cid.newMissingObject

proc tcpClientGet(s: DagfsStore; cid: Cid; result: var string) =
  result.setLen maxBlockSize
  let n = s.getBuffer(cid, result[0].addr, result.len)
  result.setLen n
  assert(result.dagHash == cid)

proc newTcpClient*(host: string; port = defaultPort): TcpClient =
  new result
  result.sock = waitFor asyncnet.dial(host, port, buffered=false)
  result.buf = ""
  result.putImpl = tcpClientPut
  result.getBufferImpl = tcpClientGetBuffer
  result.getImpl = tcpClientGet

proc close*(client: TcpClient) =
  ## Close a TCP client connection.
  close client.sock
