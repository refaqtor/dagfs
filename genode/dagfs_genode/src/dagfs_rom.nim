import xmltree, streams, strtabs, strutils, xmlparser, tables, cbor,
  genode, genode/parents, genode/servers, genode/roms,
  dagfs, dagfs/stores, ./dagfs_client, dagfs/fsnodes

const
  currentPath = currentSourcePath.rsplit("/", 1)[0]
  header = currentPath & "/rom_component.h"
{.passC: "-I" & currentPath.}

type
  RomSessionCapability {.
    importcpp: "Genode::Rom_session_capability",
    header: "<rom_session/capability.h>".} = object

  RomSessionComponentBase {.importcpp, header: header.} = object
    impl {.importcpp.}: pointer
  RomSessionComponent = Constructible[RomSessionComponentBase]

  Session = ref object
    env: GenodeEnv
    cpp: RomSessionComponent
    ds: DataspaceCapability

proc isValid(cap: RomSessionCapability): bool {.importcpp: "#.valid()".}

proc deliverSession*(parent: Parent; id: ServerId; cap: RomSessionCapability) {.
  importcpp: "#->deliver_session_cap(Genode::Parent::Server::Id{#}, #)".}

proc newSession(env: GenodeEnv; ds: DataspaceCapability): Session =
  proc construct(cpp: RomSessionComponent; ds: DataspaceCapability) {.importcpp.}
  new result
  result.env = env
  result.cpp.construct(ds)
  result.ds = ds

proc manage(ep: Entrypoint; s: Session): RomSessionCapability =
  proc manage(ep: Entrypoint; cpp: RomSessionComponent): RomSessionCapability {.
    importcpp: "#.manage(*#)".}
  result = ep.manage(s.cpp)
  GC_ref s

proc dissolve(s: Session) =
  proc dissolve(ep: Entrypoint; cpp: RomSessionComponent) {.
    importcpp: "#.dissolve(*#)".}
  let
    ep = s.env.ep
    pd = s.env.pd
  ep.dissolve(s.cpp)
  destruct s.cpp
  pd.freeDataspace s.ds
  GC_unref s

proc readFile(store: DagfsStore; s: Stream; file: FsNode) =
  var chunk = ""
  if file.isRaw:
    store.get(file.cid, chunk)
    assert(file.cid.verify chunk)
    s.write chunk
  else:
    var n = 0
    for i in 0..file.links.high:
      store.get(file.links[i].cid, chunk)
      assert(file.links[i].cid.verify chunk)
      doAssert(n+chunk.len <= file.size)
      s.write chunk
      n.inc chunk.len
    doAssert(n == file.size)

componentConstructHook = proc(env: GenodeEnv) =
  var
    store = env.newDagfsClient()
    policies = newSeq[XmlNode](8)
    sessions = initTable[ServerId, Session]()

  proc readDataspace(label: string; rootCid: Cid): DataspaceCapability =
    let
      name = label.lastLabelElement
      root = store.openDir(rootCid)
      file = store.walk(root, name)
    if file.isNil:
      echo name, " not in root ", rootCid, " for '", label, "'"
    else:
      let
        pd = env.pd
        romDs = pd.allocDataspace file.size.int
        dsFact = env.rm.newDataspaceStreamFactory(romDs)
        romS = dsFact.newStream()
      try: store.readFile(romS, file)
      except:
        close romS
        pd.freeDataspace romDs
        raise getCurrentException()
      close romS
      close dsFact
      result = romDs

  proc createSessionNoTry(id: ServerId; label: string; rootCid: Cid): RomSessionCapability =
    let romDs = readDataspace(label, rootCid)
    if romDs.isValid:
      let session = env.newSession(romDs)
      sessions[id] = session
      result = env.ep.manage(session)
  
  proc createSession(env: GenodeEnv; id: ServerId; label: string; rootCid: Cid) =
    var cap = RomSessionCapability()
    try: cap = createSessionNoTry(id, label, rootCid)
    except MissingObject:
      let e = (MissingObject)getCurrentException()
      echo "cannot resolve '", label, "', ", e.cid, " is missing"
    except:
      echo "unhandled exception while resolving '", label, "', ",
        getCurrentExceptionMsg()
      discard
    if cap.isValid:
      echo "deliver ROM to ", label
      env.parent.deliverSession id, cap
    else:
      echo "deny ROM to ", label
      let parent = env.parent
      parent.sessionResponseDeny(id)

  proc processConfig(rom: RomClient) =
    update rom
    policies.setLen 0
    let
      configXml = rom.xml
    configXml.findAll("default-policy", policies)
    if policies.len > 1:
      echo "more than one '<default-policy/>' found, ignoring all"
      policies.setLen 0
    configXml.findAll("policy", policies)

  proc processSessions(rom: RomClient) {.gcsafe.} =
    update rom
    var requests = initSessionRequestsParser(rom)
  
    for id in requests.close:
      if sessions.contains id:
        let s = sessions[id]
        dissolve(s)
        sessions.del id
        env.parent.sessionResponseClose(id)
  
    for id, label, args in requests.create "ROM":
      try:
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
            createSession(env, id, label, rootCid)
          else:
            echo "no valid root policy for '", label, "'"
            env.parent.sessionResponseDeny(id)
      except:
        echo "failed to create session for '", label, "', ", getCurrentExceptionMsg()
        env.parent.sessionResponseDeny(id)
    # All sessions have been instantiated and requests fired off,
    # now return to the entrypoint and dispatch packet signals,
    # which will work the chain of futures and callbacks until
    # `createSession` completes and capabilities are delivered

  let
    configRom = env.newRomHandler(
      "config", processConfig)
    sessionsRom = env.newRomHandler(
      "session_requests", processSessions)

  process configRom
  process sessionsRom

  env.parent.announce "ROM"
