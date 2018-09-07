import std/tables, std/xmltree, std/strtabs, std/strutils, std/streams, std/xmlparser

import genode, genode/signals, genode/parents, genode/servers, genode/roms

import dagfs, dagfs/stores, dagfs/fsnodes, ./dagfs_client, ./filesystemsession

const
  currentPath = currentSourcePath.rsplit("/", 1)[0]
  fsComponentH = currentPath & "/fs_component.h"

const FsH = "<file_system_session/file_system_session.h>"

proc raiseInvalidHandle() {.noreturn, header: FsH,
  importcpp: "throw File_system::Invalid_handle()".}
proc raiseInvalidName() {.noreturn, header: FsH,
  importcpp: "throw File_system::Invalid_name()".}
proc raiseLookupFailed() {.noreturn, header: FsH,
  importcpp: "throw File_system::Lookup_failed()".}
proc raisePermissionDenied() {.noreturn, header: FsH,
  importcpp: "throw File_system::Permission_denied()".}

template permissionsAssert(cond: bool) =
  if not cond: raisePermissionDenied()

template lookupAssert(cond: bool) =
  if not cond: raiseLookupFailed()

template validPathAssert(name: string) =
  if name[name.low] != '/' or name[name.high] == '/': raiseLookupFailed()

template validNameAssert(name: string) =
  if name.contains '/': raiseInvalidName()

type
  FsCapability {.
    importcpp: "File_system::Session_capability",
    header: "<file_system_session/capability.h>".} = object

  FsSessionComponentBase {.
    importcpp: "File_system::SessionComponentBase", header: fsComponentH.} = object

  FsSessionComponent = Constructible[FsSessionComponentBase]

  Handle = culong

  NodeKind = enum
    nodeNode,
    dirNode,
    fileNode,
    cidNode

  Node = object
    ufs: FsNode
    kind: NodeKind

  SessionPtr = ptr SessionObj
  SessionRef = ref SessionObj
  SessionObj = object
    sig: SignalHandler
    cpp: FsSessionComponent
    store: DagfsFrontend
    label: string
    rootDir: FsNode
    next: Handle
    nodes: Table[Handle, Node]
    cache: string
      ## Read files from the store into this buffer
    cacheCid: Cid
      ## CID of the cache contents

  Session = ptr SessionObj | ref SessionObj | SessionObj
  
proc deliverSession*(parent: Parent; id: ServerId; cap: FsCapability) {.
  importcpp: "#->deliver_session_cap(Genode::Parent::Server::Id{#}, #)".}

proc packetAvail(cpp: FsSessionComponent): bool {.
  importcpp: "#->tx_sink()->packet_avail()".}

proc readyToAck(cpp: FsSessionComponent): bool {.
  importcpp: "#->tx_sink()->ready_to_ack()".}

proc popRequest(cpp: FsSessionComponent): FsPacket {.
  importcpp: "#->tx_sink()->get_packet()".}

proc packet_content(cpp: FsSessionComponent; pkt: FsPacket): pointer {.
  importcpp: "#->tx_sink()->packet_content(@)".}

proc acknowledge(cpp: FsSessionComponent; pkt: FsPacket) {.
  importcpp: "#->tx_sink()->acknowledge_packet(@)".}

proc manage(ep: Entrypoint; s: Session): FsCapability =
  proc manage(ep: Entrypoint; cpp: FsSessionComponent): FsCapability {.
    importcpp: "#.manage(*#)".}
  result = ep.manage(s.cpp)
  GC_ref(s)

proc dissolve(ep: Entrypoint; s: Session) =
  proc dissolve(ep: Entrypoint; cpp: FsSessionComponent) {.
    importcpp: "#.dissolve(*#)".}
  dissolve s.sig
  ep.dissolve(s.cpp)
  destruct s.cpp
  GC_unref(s)

proc nextId(s: Session): Handle =
  result = s.next
  inc s.next

proc inode(cid: Cid): culong = hash(cid).culong
  ## Convert a CID to a inode with the same hash
  ## algorithm used to store CIDs in tables.

template fsRpc(session: SessionPtr; body: untyped) =
  try: body
  except MissingChunk:
    let e = (MissingChunk)getCurrentException()
    echo "Synchronous RPC failure, missing object ", e.cid
    raiseLookupFailed()
  except:
    echo "failed, ", getCurrentExceptionMsg()
    raisePermissionDenied()

proc nodeProc(session: pointer; path: cstring): Handle {.exportc.} =
  let session = cast[SessionPtr](session)
  fsRpc session:
    var n: Node
    if path == "/":
      n = Node(ufs: session.rootDir, kind: nodeNode)
    else:
      var path = $path
      validPathAssert path
      if path.endsWith("/.cid"):
        path.setLen(path.len - "/.cid".len)
        let ufs = session.store.walk(session.rootDir, path)
        if ufs.isNil:
          raiseLookupFailed()
        n = Node(ufs: ufs, kind: cidNode)
      else:
        let ufs = session.store.walk(session.rootDir, path)
        if ufs.isNil:
          raiseLookupFailed()
        n = Node(ufs: ufs, kind: nodeNode)
    result = session.nextId
    session.nodes[result] = n

type Status {.importcpp: "File_system::Status", pure.} = object
  size {.importcpp.}: culonglong
  mode {.importcpp.}: cuint
  inode {.importcpp.}: culong

proc statusProc(state: pointer; handle: Handle): Status {.exportc.} =
  const
    DirMode = 1 shl 14
    FileMode = 1 shl 15
  let session = cast[ptr SessionObj](state)
  fsRpc session:
    let node = session.nodes[handle]
    result.inode = node.ufs.cid.inode
    if node.ufs.isDir:
      if node.kind == cidNode:
        result.size = 0
        result.mode = FileMode
      else:
        result.size = (culonglong)node.ufs.size * fsDirentSize().BiggestInt
        result.mode = DirMode
    else:
      result.size = node.ufs.size.culonglong
      result.mode = FileMode

proc dirProc(state: pointer; path: cstring; create: cint): Handle {.exportc.} =
  permissionsAssert(create == 0)
  let session = cast[ptr SessionObj](state)
  fsRpc session:
    let path = $path
    var n: Node
    if path == "/":
      n = Node(ufs: session.rootDir, kind: dirNode)
    else:
      validPathAssert path
      let ufs = session.store.walk(session.rootDir, path)
      if ufs.isNil:
        raiseLookupFailed()
      if not ufs.isDir:
        raiseLookupFailed()
      n = Node(ufs: ufs, kind: dirNode)
    result = session.nextId
    session.nodes[result] = n

proc fileProc(state: pointer; dirH: Handle; name: cstring; mode: cuint; create: cint): Handle {.exportc.} =
  permissionsAssert(create == 0)
  let session = cast[ptr SessionObj](state)
  fsRpc session:
    let name = $name
    validNameAssert name
    var n: Node
    let dir = session.nodes[dirH]
    if name == ".cid":
      n = Node(
        ufs: dir.ufs,
        kind: cidNode)
    else:
      let ufs = dir.ufs[name]
      lookupAssert(not ufs.isNil and ufs.isFile)
      n = Node(
        ufs: ufs,
        kind: fileNode)
    result = session.nextId
    session.nodes[result] = n

proc closeProc(state: pointer; h: Handle) {.exportc.} =
  let session = cast[ptr SessionObj](state)
  fsRpc session:
    session.nodes.del h

proc unlinkProc(state: pointer; dirH: Handle; name: cstring) {.exportc.} =
  raisePermissionDenied()

proc truncateProc(state: pointer; file: Handle, size: cuint) {.exportc.} =
  raisePermissionDenied()

proc moveProc(state: pointer;
              from_dir: Handle; from_name: cstring;
              to_dir: Handle; to_name: cstring) {.exportc.} =
  raisePermissionDenied()

proc processPacket(session: SessionRef; pkt: var FsPacket) =
  ## Process a File_system packet from the client.
  if not session.nodes.hasKey(pkt.handle):
    echo session.label, " sent packet with invalid handle"
  else:
    if pkt.operation == READ:
      let
        node = session.nodes[pkt.handle]
        pktBuf = cast[ptr array[maxChunkSize, char]](session.cpp.packetContent pkt)
          # cast the pointer to an array pointer for indexing
      case node.kind
      of fileNode:
        if node.ufs.isRaw:
          if session.cacheCid != node.ufs.cid:
            session.store.get(node.ufs.cid, session.cache)
            session.cacheCid = node.ufs.cid
          if pkt.position < session.cache.len:
            let
              pos = pkt.position.int
              n = min(pkt.len, session.cache.len - pos)
            copyMem(pktBuf, session.cache[pos].addr, n)
            pkt.setLen n
            pkt.succeeded true
        else:
          var
            pktPos = pkt.position
            remain = pkt.len
            filePos: int64
            count: int
          for i in 0..node.ufs.links.high:
            let linkSize = node.ufs.links[i].size
            if (pktPos >= filePos) and (pktPos < filePos+linkSize):
              if session.cacheCid != node.ufs.links[i].cid:
                session.store.get(node.ufs.links[i].cid, session.cache)
                session.cacheCid = node.ufs.links[i].cid
              let
                off = (int)pktPos - filePos
                n = min(remain, session.cache.len - off)
              copyMem(pktBuf[count].addr, session.cache[off].addr, n)
              pktPos.inc n
              count.inc n
              remain.dec n
              if remain == 0:
                break
            filePos.inc linkSize
          pkt.setLen count
          pkt.succeeded true
      of dirNode:
        if pkt.len >= fsDirentSize():
          let i = pkt.position().int div fsDirentSize().int
          var (name, u) = node.ufs[i]
          if not u.isNil and name != "":
            let dirent = cast[ptr FsDirent](pktBuf)
            zeroMem(dirent, fsDirentSize())
            dirent.inode = u.cid.inode
            dirent.kind = if u.isFile: TYPE_FILE else: TYPE_DIRECTORY
            copyMem(dirent.name, name[0].addr, min(name.len, MAX_NAME_LEN-1))
            pkt.setLen fsDirentSize()
            pkt.succeeded true
          else:
            pkt.setLen 0
      of cidNode:
        var s = node.ufs.cid.toHex()
        let pos = pkt.position.int
        if pos < s.len:
          let n = min(s.len - pos, pkt.len)
          copyMem(pktBuf, s[pos].addr, n)
          pkt.setLen n
          pkt.succeeded true
        else:
          pkt.setLen 0
      else:
        echo "ignoring ", pkt.operation, " packet from ", session.label

proc newSession(env: GenodeEnv; store: DagfsFrontend; label: string; root: FsNode; txBufSize: int): SessionRef =
  proc construct(cpp: FsSessionComponent; env: GenodeEnv; txBufSize: int; state: SessionPtr; cap: SignalContextCapability) {.
    importcpp.}
  let session = new SessionRef
  session.store = store
  session.label = label
  session.rootDir = root
  session.nodes = initTable[Handle, Node]()
  session.cache = ""
    # Buffer for reading file data.
  session.cacheCid = initCid()
    # Last block that was read into the cache buffer.
  session.sig = env.ep.newSignalHandler do ():
    while session.cpp.packetAvail and session.cpp.readyToAck:
      var pkt = session.cpp.popRequest
      pkt.succeeded false # processPacket must affirm success
      try: session.processPacket(pkt)
      except: discard
      session.cpp.acknowledge(pkt)
  session.cpp.construct(env, txBufSize, session[].addr, session.sig.cap)
  result = session

componentConstructHook = proc(env: GenodeEnv) =
  var
    policies = newSeq[XmlNode](8)
    sessions = initTable[ServerId, SessionRef]()
  let store = env.newDagfsFrontend()
    ## The Dagfs session client backing File_system sessions.

  proc createSession(env: GenodeEnv; store: DagfsFrontend; id: ServerId; label, rootPath: string; rootCid: Cid; txBufSize: int) =
    var ufsRoot: FsNode
    try: ufsRoot = store.openDir(rootCid)
    except: ufsRoot = nil
    if not ufsRoot.isNil and not(rootPath == "/" or rootPath == ""):
      try: ufsRoot = store.walk(ufsRoot, rootPath)
      except: ufsRoot = nil
    # Can't use 'if' in 'try' here.
    if not ufsRoot.isNil:
      let session = env.newSession(store, label, ufsRoot, txBufSize)
      sessions[id] = session
      let cap = env.ep.manage session
      echo rootCid, " served to ", label
      env.parent.deliverSession(id, cap)
    else:
      echo "failed to create session for '", label, "', ",
        getCurrentExceptionMsg()
      env.parent.sessionResponseDeny(id)

  proc processSessions(rom: RomClient) =
    update rom
    var requests = initSessionRequestsParser(rom)
  
    for id in requests.close:
      if sessions.contains id:
        let s = sessions[id]
        env.ep.dissolve s
        sessions.del id
        env.parent.sessionResponseClose(id)
  
    for id, label, args in requests.create "File_system":
      let policy = policies.lookupPolicy label
      doAssert(not sessions.contains(id), "session already exists for id")
      doAssert(label != "")
      if policy.isNil:
        echo "no policy matched '", label, "'"
        env.parent.sessionResponseDeny(id)
      else:
        var rootCid = initCid()
        let pAttrs = policy.attrs
        if not pAttrs.isNil and pAttrs.contains "root":
          try: rootCid = parseCid(pAttrs["root"])
          except ValueError: discard
        else:
          for e in label.elements:
            try:
              rootCid = parseCid e
              break
            except ValueError: continue
        if rootCid.isValid:
          try:
            let
              rootPath = args.argString "root"
              txBufSize = args.argInt "tx_buf_size"
            env.createSession(store, id, label, rootPath, rootCid, txBufSize.int)
          except:
            echo "failed to create session for '", label, "', ", getCurrentExceptionMsg()
            env.parent.sessionResponseDeny(id)
        else:
            echo "no valid root policy for '", label, "'"
            env.parent.sessionResponseDeny(id)
  
  proc processConfig(rom: RomClient) {.gcsafe.} =
    update rom
    policies.setLen 0
    let configXml = rom.xml
    configXml.findAll("default-policy", policies)
    if policies.len > 1:
      echo "more than one '<default-policy/>' found, ignoring all"
      policies.setLen 0
    configXml.findAll("policy", policies)
  
    for session in sessions.values:
      # update root policies for active sessions
      let policy = policies.lookupPolicy session.label
      if not policy.isNil:
        let pAttrs = policy.attrs
        if not pAttrs.isNil and pAttrs.contains "root":
          try:
            let
              policyCidStr = pAttrs["root"]
              policyCid = parseCid policyCidStr
            if session.rootDir.cid != policyCid:
              session.rootDir = store.openDir policyCid
              echo policyCid, " is new root of ", session.label
          except:
            echo "failed to update policy for '",
              session.label, "', ", getCurrentExceptionMsg()

  let
    sessionsRom = env.newRomHandler("session_requests", processSessions)
    configRom = env.newRomHandler("config", processConfig)
  process configRom
  process sessionsRom

  env.parent.announce "File_system"
