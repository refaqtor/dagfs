import nre, os, strutils, tables, parseopt, streams, cbor

import ipld, ipldstore, unixfs, multiformats

type
  EvalError = object of SystemError

type
  Env = ref EnvObj

  AtomKind = enum
    atomPath
    atomCid
    atomString
    atomSymbol
    atomError

  Atom = object
    case kind: AtomKind
    of atomPath:
      path: string
    of atomCid:
      cid: Cid
    of atomString:
      str: string
    of atomSymbol:
      sym: string
    of atomError:
      err: string

  Func = proc(env: Env; arg: NodeObj): NodeRef

  NodeKind = enum
    nodeError
    nodeList
    nodeAtom
    nodeFunc

  NodeRef = ref NodeObj
    ## NodeRef is used to chain nodes into lists.
  NodeObj = object
    ## NodeObj is used to mutate nodes without side-effects.
    case kind: NodeKind
    of nodeList:
      headRef, tailRef: NodeRef
    of nodeAtom:
      atom: Atom
    of nodeFunc:
      fun: Func
      name: string
    of nodeError:
      errMsg: string
      errNode: NodeRef
    nextRef: NodeRef

  EnvObj = object
    store: IpldStore
    bindings: Table[string, NodeObj]
    paths: Table[string, UnixfsNode]
    cids: Table[Cid, UnixfsNode]

proc print(a: Atom; s: Stream)
proc print(ast: NodeRef; s: Stream)

proc newAtom(c: Cid): Atom =
  Atom(kind: atomCid, cid: c)

proc newAtomError(msg: string): Atom =
  Atom(kind: atomError, err: msg)

proc newAtomPath(s: string): Atom =
  try:
    let path = expandFilename s
    Atom(kind: atomPath, path: path)
  except OSError:
    newAtomError("invalid path '$1'" % s)

proc newAtomString(s: string): Atom =
  Atom(kind: atomString, str: s)

proc newNodeError(msg: string; n: NodeObj): NodeRef =
  var p = new NodeRef
  p[] = n
  NodeRef(kind: nodeError, errMsg: msg, errNode: p)

proc newNode(a: Atom): NodeRef =
  NodeRef(kind: nodeAtom, atom: a)

proc newNodeList(): NodeRef =
  NodeRef(kind: nodeList)

proc next(n: NodeObj | NodeRef): NodeObj =
  ## Return a copy of list element that follows Node n.
  assert(not n.nextRef.isNil, "next element is nil")
  result = n.nextRef[]

proc head(list: NodeObj | NodeRef): NodeObj =
  ## Return the start element of a list Node.
  list.headRef[]

proc `next=`(n, p: NodeRef) =
  ## Return a copy of list element that follows Node n.
  assert(n.nextRef.isNil, "append to node that is not at the end of a list")
  n.nextRef = p

iterator list(n: NodeObj): NodeObj =
  ## Iterate over members of a list node.
  var n = n.headRef
  while not n.isNil:
    yield n[]
    n = n.nextRef

iterator walk(n: NodeObj): NodeObj =
  ## Walk down the singly linked list starting from a member node.
  var n = n
  while not n.nextRef.isNil:
    yield n
    n = n.nextRef[]
  yield n

proc append(list, n: NodeRef) =
  ## Append a node to the end of a list node.
  if list.headRef.isNil:
    list.headRef = n
    list.tailRef = n
  else:
    list.tailRef.next = n
    while not list.tailRef.nextRef.isNil:
      assert(list.tailRef != list.tailRef.nextRef)
      list.tailRef = list.tailRef.nextRef

proc append(list: NodeRef; n: NodeObj) =
  let p = new NodeRef
  p[] = n
  list.append p

proc getFile(env: Env; path: string): UnixFsNode =
  result = env.paths.getOrDefault path
  if result.isNil:
    result = env.store.addFile(path)
    assert(not result.isNil)
    env.paths[path] = result

proc getDir(env: Env; path: string): UnixFsNode =
  result = env.paths.getOrDefault path
  if result.isNil:
    result = env.store.addDir(path)
    assert(not result.isNil)
    env.paths[path] = result

proc getUnixfs(env: Env; cid: Cid): UnixFsNode =
  assert cid.isValid
  result = env.cids.getOrDefault cid
  if result.isNil:
    var raw = ""
    env.store.get(cid, raw)
    result = parseUnixfs(raw, cid)
    env.cids[cid] = result

type
  Tokens = seq[string]

  Reader = ref object
    buffer: string
    tokens: Tokens
    pos: int

proc newReader(): Reader =
  Reader(buffer: "", tokens: newSeq[string]())

proc next(r: Reader): string =
  assert(r.pos < r.tokens.len, $r.tokens)
  result = r.tokens[r.pos]
  inc r.pos

proc peek(r: Reader): string =
  assert(r.pos < r.tokens.len, $r.tokens)
  r.tokens[r.pos]

proc print(a: Atom; s: Stream) =
  case a.kind
  of atomPath:
    s.write a.path
  of atomCid:
    s.write $a.cid
  of atomString:
    s.write '"'
    s.write a.str
    s.write '"'
  #[
  of atomData:
    let fut = newFutureStream[string]()
    asyncCheck env.store.fileStream(a.fileCid, fut)
    while true:
      let (valid, chunk) = fut.read()
      if not valid: break
      f.write chunk
    ]#
  of atomSymbol:
    s.write a.sym
  of atomError:
    s.write "«"
    s.write a.err
    s.write "»"

proc print(ast: NodeObj; s: Stream) =
  case ast.kind:
  of nodeAtom:
    ast.atom.print(s)
  of nodeList:
    s.write "\n("
    for n in ast.list:
      s.write " "
      n.print(s)
    s.write ")"
  of nodeFunc:
    s.write "#<procedure "
    s.write ast.name
    s.write ">"
  of nodeError:
    s.write "«"
    s.write ast.errMsg
    s.write ": "
    ast.errNode.print s
    s.write "»"

proc print(ast: NodeRef; s: Stream) =
  if ast.isNil:
    s.write "«nil»"
  else:
    ast[].print s

proc readAtom(r: Reader): Atom =
  let token = r.next
  try:
    if token[token.low] == '"':
      if token[token.high] != '"':
        newAtomError("invalid string '$1'" % token)
      else:
        newAtomString(token[1..token.len-2])
    elif token.contains DirSep:
      # TODO: memoize this, store a table of paths to atoms
      newAtomPath token
    elif token.len > 48:
      Atom(kind: atomCid, cid: token.parseCid)
    else:
      Atom(kind: atomSymbol, sym: token.normalize)
  except:
    newAtomError(getCurrentExceptionMsg())

proc readForm(r: Reader): NodeRef

proc readList(r: Reader): NodeRef =
  result = newNodeList()
  while true:
    if (r.pos == r.tokens.len):
      return nil
    let p = r.peek
    case p[p.high]
    of ')':
      discard r.next
      break
    else:
      result.append r.readForm

proc readForm(r: Reader): NodeRef =
  case r.peek[0]
  of '(':
    discard r.next
    r.readList
  else:
    r.readAtom.newNode

proc tokenizer(s: string): Tokens =
  # TODO: this sucks
  let tokens = s.findAll(re"""[\s,]*(~@|[\[\]{}()'`~^@]|"(?:\\.|[^\\"])*"|;.*|[^\s\[\]{}('"`,;)]*)""")
  result = newSeqOfCap[string] tokens.len
  for s in tokens:
    let t = s.strip(leading = true, trailing = false).strip(leading = false, trailing = true)
    if t.len > 0:
      result.add t

proc read(r: Reader; line: string): NodeRef =
  r.pos = 0
  if r.buffer.len > 0:
    r.buffer.add " "
    r.buffer.add line
    r.tokens = r.buffer.tokenizer
  else:
    r.tokens = line.tokenizer
  result = r.readForm
  if result.isNil:
    r.buffer = line
  else:
    r.buffer.setLen 0

proc assertArgCount(args: NodeObj; len: int) =
  var arg = args
  for _ in 2..len:
    doAssert(not arg.nextRef.isNil)
    arg = arg.next
  doAssert(arg.nextRef.isNil)

##
# Builtin functions
#

proc applyFunc(env: Env; args: NodeObj): NodeRef =
  assertArgCount(args, 2)
  let
    fn = args
    ln = fn.next
  fn.fun(env, ln.head)

proc cborFunc(env: Env; arg: NodeObj): NodeRef =
  assertArgCount(arg, 1)
  let a = arg.atom
  if a.cid.isDagCbor:
    let
      ufsNode = env.getUnixfs a.cid
      diag = $ufsNode.toCbor
    diag.newAtomString.newNode
  else:
    "".newAtomString.newNode

proc copyFunc(env: Env; args: NodeObj): NodeRef =
  assertArgCount(args, 3)
  let
    x = args
    y = x.next
    z = y.next
  var root = newUnixFsRoot()
  let dir = env.getUnixfs x.atom.cid
  for name, node in dir.items:
    root.add(name, node)
  root.add(z.atom.str, dir[y.atom.str])
  let cid = env.store.putDag(root.toCbor)
  cid.newAtom.newNode

proc consFunc(env: Env; args: NodeObj): NodeRef =
  assertArgCount(args, 2)
  result = newNodeList()
  let
    car = args
    cdr = args.next
  result.append car
  result.append cdr.head

proc defineFunc(env: Env; args: NodeObj): NodeRef =
  assertArgCount(args, 2)
  let
    symN = args
    val = args.next
  env.bindings[symN.atom.sym] = val
  new result
  result[] = val

proc dumpFunc(env: Env; args: NodeObj): NodeRef =
  result = newNodeList()
  for n in args.walk:
    let a = n.atom
    for p in env.store.dumpPaths(a.cid):
      result.append p.newAtomString.newNode

proc globFunc(env: Env; args: NodeObj): NodeRef =
  result = newNodeList()
  for n in args.walk:
    let a = n.atom
    case a.kind
    of atomPath:
      result.append n
    of atomString:
      for match in walkPattern a.str:
        result.append match.newAtomPath.newNode
    else:
      result = newNodeError("invalid glob argument", n)

proc ingestFunc(env: Env; args: NodeObj): NodeRef =
  var root = newUnixFsRoot()
  for n in args.walk:
    let
      a = n.atom
      name = a.path.extractFilename
      info = a.path.getFileInfo
    case info.kind
    of pcFile, pcLinkToFile:
      let file = env.getFile a.path
      root.add(name, file)
    of pcDir, pcLinkToDir:
      let dir = env.getDir a.path
      root.add(name, dir)
  let
    cid = env.store.putDag(root.toCbor)
  cid.newAtom.newNode

proc listFunc(env: Env; args: NodeObj): NodeRef =
  ## Standard Lisp 'list' function.
  result = newNodeList()
  new result.headRef
  result.headRef[] = args
  result.tailRef = result.headRef
  while not result.tailRef.nextRef.isNil:
    result.tailRef = result.tailRef.nextRef

proc lsFunc(env: Env; args: NodeObj): NodeRef =
  result = newNodeList()
  for n in args.walk:
    let a = n.atom
    if a.cid.isDagCbor:
        let ufsNode = env.getUnixfs a.cid
        if ufsNode.isDir:
          for name, u in ufsNode.items:
            assert(not name.isNil)
            assert(not u.isNil, name & " is nil")
            let e = newNodeList()
            e.append u.cid.newAtom.newNode
            e.append name.newAtomString.newNode
            result.append e
    else:
      raiseAssert("ls over a raw IPLD block")

proc mapFunc(env: Env; args: NodeObj): NodeRef =
  assertArgCount(args, 2)
  result = newNodeList()
  let f = args.fun
  for v in args.next.list:
    result.append f(env, v)

proc mergeFunc(env: Env; args: NodeObj): NodeRef =
  var root = newUnixFsRoot()
  for n in args.walk:
    let a = n.atom
    doAssert(a.cid.codec == MulticodecTag.Dag_cbor, "not a CBOR encoded IPLD block")
    let dir = env.getUnixfs a.cid
    for name, node in dir.items:
      root.add(name, node)
  let cid = env.store.putDag(root.toCbor)
  cid.newAtom.newNode

proc pathFunc(env: Env; arg: NodeObj): NodeRef =
  result = arg.atom.str.newAtomPath.newNode

proc rootFunc(env: Env; args: NodeObj): NodeRef =
  var root = newUnixFsRoot()
  let
    name = args.atom.str
    cid = args.next.atom.cid
    ufs = env.getUnixfs cid
  root.add(name, ufs)
  let rootCid = env.store.putDag(root.toCbor)
  rootCid.newAtom.newNode

proc walkFunc(env: Env; args: NodeObj): NodeRef =
  assert args.atom.cid.isValid
  let
    rootCid = args.atom.cid
    walkPath = args.next.atom.str
    root = env.getUnixfs rootCid
    final = env.store.walk(root, walkPath)
  if final.isNil:
    result = newNodeError("no walk to '$1'" % walkPath, args)
  else:
     result = final.cid.newAtom.newNode

##
# Environment
#

proc bindEnv(env: Env; name: string; fun: Func) =
  assert(not env.bindings.contains name)
  env.bindings[name] = NodeObj(kind: nodeFunc, fun: fun, name: name)

proc newEnv(store: IpldStore): Env =
  result = Env(
    store: store,
    bindings: initTable[string, NodeObj](),
    paths: initTable[string, UnixfsNode](),
    cids: initTable[Cid, UnixfsNode]())
  result.bindEnv "apply", applyFunc
  result.bindEnv "cbor", cborFunc
  result.bindEnv "cons", consFunc
  result.bindEnv "copy", copyFunc
  result.bindEnv "define", defineFunc
  result.bindEnv "dump", dumpFunc
  result.bindEnv "glob", globFunc
  result.bindEnv "ingest", ingestFunc
  result.bindEnv "list", listFunc
  result.bindEnv "ls", lsFunc
  result.bindEnv "map", mapFunc
  result.bindEnv "merge", mergeFunc
  result.bindEnv "path", pathFunc
  result.bindEnv "root", rootFunc
  result.bindEnv "walk", walkFunc

proc eval(ast: NodeRef; env: Env): NodeRef

proc eval_ast(ast: NodeRef; env: Env): NodeRef =
  result = ast
  case ast.kind
  of nodeList:
    result = newNodeList()
    while not ast.headRef.isNil:
      # cut out the head of the list and evaluate
      let n = ast.headRef
      ast.headRef = n.nextRef
      n.nextRef = nil
      let x = n.eval(env)
      result.append x
  of nodeAtom:
    if ast.atom.kind == atomSymbol:
      if env.bindings.contains ast.atom.sym:
        result = new NodeRef
        result[] = env.bindings[ast.atom.sym]
  else: discard

proc eval(ast: NodeRef; env: Env): NodeRef =
  var input = ast[]
  try:
    if ast.kind == nodeList:
      if ast.headRef == nil:
        newNodeList()
      else:
        let
          ast = eval_ast(ast, env)
          head = ast.headRef
        if head.kind == nodeFunc:
          if not head.nextRef.isNil:
            input = head.next
            head.fun(env, input)
          else:
            input = NodeObj(kind: nodeList)
            head.fun(env, input)
        else:
          input = head[]
          newNodeError("not a function", input)
    else:
      eval_ast(ast, env)
  except EvalError:
    newNodeError(getCurrentExceptionMsg(), input)
  except FieldError:
    newNodeError("invalid argument", input)
  except MissingObject:
    newNodeError("object not in store", input)
  except OSError:
    newNodeError(getCurrentExceptionMsg(), input)

var scripted = false

when defined(genode):
  import ipldclient
  proc openStore(): IpldStore =
    result = newIpldClient("repl")
    scripted = true # do not use linenoise for the moment
    #[
    for kind, key, value in getopt():
      if kind == cmdShortOption and key == "s":
        scripted = true
      else:
        quit "unhandled argument " & key
    ]#
else:
  import ipfsdaemon
  proc openStore(): IpldStore =
    for kind, key, value in getopt():
      case kind
      of cmdShortOption:
        if key == "s":
          scripted = true
        else:
          quit "unhandled argument " & key
      of cmdArgument:
        if not result.isNil:
          quit "only a single store path argument is accepted"
        try:
          result = if key.startsWith "http://":
            newIpfsStore(key) else: newFileStore(key)
        except:
          quit("failed to open store at $1 ($2)" % [key, getCurrentExceptionMsg()])
      else:
        quit "unhandled argument " & key
    if result.isNil:
      quit "IPFS daemon URL must be specified"

import rdstdin

proc readLineSimple(prompt: string; line: var TaintedString): bool =
  stdin.readLine(line)

proc main() =
  let
    store = openStore()
    env = newEnv(store)
    outStream = stdout.newFileStream
    readLine = if scripted: readLineSimple else: readLineFromStdin

  var
    reader = newReader()
    line = newStringOfCap 128
  while readLine("> ", line):
    if line.len > 0:
      let ast = reader.read(line)
      if not ast.isNil:
        ast.eval(env).print(outStream)
        outStream.write "\n"
        flush outStream

main()
quit 0 # Genode doesn't implicitly quit
