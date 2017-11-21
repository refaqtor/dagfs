import rdstdin, nre, os, strutils, tables, asyncdispatch, asyncstreams, parseopt, streams

import ipld, ipldstore, unixfs, multiformats

type
  EvalError = object of SystemError

template raiseArgError(msg = "invalid argument") =
    raise newException(EvalError, msg)

type
  Env = ref EnvObj

  AtomKind = enum
    atomPath
    atomCid
    atomFile
    atomDir
    atomString
    atomSymbol
    atomError

  Atom = object
    case kind: AtomKind
    of atomPath:
      path: string
    of atomCid:
      cid: Cid
    of atomFile:
      fName: string
      file: UnixfsNode
    of atomDir:
      dName:string
      dir: UnixfsNode
    of atomString:
      str: string
    of atomSymbol:
      sym: string
    of atomError:
      err: string

  Func = proc(env: Env; arg: NodeObj): Node

  NodeKind = enum
    nodeError
    nodeList
    nodeAtom
    nodeFunc

  Node = ref NodeObj
  NodeRef = ref NodeObj
  NodeObj = object
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
    store: FileStore
    bindings: Table[string, NodeObj]
    paths: Table[string, UnixfsNode]
    cids: Table[Cid, UnixfsNode]
    pathCacheHit: int
    pathCacheMiss: int
    cidCacheHit: int
    cidCacheMiss: int

proc print(a: Atom; s: Stream)
proc print(ast: Node; s: Stream)

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

#[
template evalAssert(cond, n: Node, msg = "") =
  if not cond:
    let err = newException(EvalError, msg)
    err.node = n
    raise err
]#

proc newNodeError(msg: string; n: NodeObj): NodeRef =
  var p = new Node
  p[] = n
  Node(kind: nodeError, errMsg: msg, errNode: p)

proc newNode(a: Atom): Node =
  Node(kind: nodeAtom, atom: a)

proc newNodeList(): Node =
  Node(kind: nodeList)

proc next(n: NodeObj | NodeRef): NodeObj =
  ## Return a copy of list element that follows Node n.
  assert(not n.nextRef.isNil)
  result = n.nextRef[]

proc head(list: NodeObj | NodeRef): NodeObj =
  ## Return the start element of a list Node.
  list.headRef[]

proc `next=`(n, p: NodeRef) =
  ## Return a copy of list element that follows Node n.
  assert(n.nextRef.isNil)
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

proc isAtom(n: Node): bool = n.kind == nodeAtom
proc isFunc(n: Node): bool = n.kind == nodeFunc
proc isList(n: Node): bool = n.kind == nodeList

proc getFile(env: Env; path: string): UnixFsNode =
  result = env.paths.getOrDefault path
  if result.isNil:
    result = waitFor env.store.addFile(path)
    assert(not result.isNil)
    env.paths[path] = result
    inc env.pathCacheMiss
  else:
    inc env.pathCacheHit

proc getDir(env: Env; path: string): UnixFsNode =
  result = env.paths.getOrDefault path
  if result.isNil:
    result = waitFor env.store.addDir(path)
    assert(not result.isNil)
    env.paths[path] = result
    inc env.pathCacheMiss
  else:
    inc env.pathCacheHit

proc getUnixfs(env: Env; cid: Cid): UnixFsNode =
  result = env.cids.getOrDefault cid
  if result.isNil:
    let dag = waitFor env.store.getDag(cid)
    assert(not dag.isNil)
    result = parseUnixfs dag
    env.cids[cid] = result
    inc env.cidCacheMiss
  else:
    inc env.cidCacheHit

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
  of atomFile:
    s.write $a.file.fCid
    s.write ':'
    s.write a.fName
    s.write ':'
    s.write $a.file.fSize
  of atomDir:
    s.write "\n"
    s.write $a.dir.dCid
    s.write ':'
    s.write a.dName
  of atomString:
    s.write '"'
    s.write a.str
    s.write '"'
  #[
  of atomData:
    let fut = newFutureStream[string]()
    asyncCheck env.store.fileStream(a.fileCid, fut)
    while true:
      let (valid, chunk) = waitFor fut.read()
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
    s.write "("
    for n in ast.list:
      s.write "\n"
      n.print(s)
    s.write "\n)"
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

#[
proc chainData(end: Atom; a: Atom; env: Env): Atom =
  ## Convert an atom to data and chain it to the end of a data chain,
  ## return the new end of the chain.
  var next: Atom
  case a.kind:
  of atomData:
    next = a
  else: discard
  if end.isNil:
    result = next
  else:
    doAsset(end.nextData.isNil)
    end.nextData = next
]#

proc readForm(r: Reader): Node

proc readList(r: Reader): Node =
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

proc readForm(r: Reader): Node =
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

proc read(r: Reader; line: string): Node =
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

##
# Builtin functions
#

proc applyFunc(env: Env; args: NodeObj): Node =
  let
    fn = args
    ln = fn.next
  fn.fun(env, ln.head)

proc catFunc(env: Env; arg: NodeObj): Node =
#[
  result = Atom(kind: atomData).newNode
  var atom = result.atom
  for n in args:
    assert(n.kind == nodeAtom, "cat called on a non-atomic node")
    #atom = atom.chainData(n.atom, env)
]#
  result = newNodeError("cat not implemented", arg)

proc consFunc(env: Env; args: NodeObj): Node =
  result = newNodeList()
  let
    car = args
    cdr = args.next
  result.append car
  result.append cdr.head

proc defineFunc(env: Env; args: NodeObj): Node =
  let
    symN = args
    val = args.next
  env.bindings[symN.atom.sym] = val
  new result
  result[] = val

proc dumpFunc(env: Env; args: NodeObj): Node =
  result = newNodeList()
  for n in args.walk:
    let a = n.atom
    for p in env.store.dumpPaths(a.cid):
      result.append p.newAtomString.newNode

proc globFunc(env: Env; args: NodeObj): Node =
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

proc ingestFunc(env: Env; args: NodeObj): Node =
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
    cid = waitFor env.store.putDag(root.toCbor)
  cid.newAtom.newNode

proc listFunc(env: Env; args: NodeObj): Node =
  ## Standard Lisp 'list' function.
  result = newNodeList()
  new result.headRef
  result.headRef[] = args
  result.tailRef = result.headRef
  while not result.tailRef.nextRef.isNil:
    result.tailRef = result.tailRef.nextRef

proc lsFunc(env: Env; args: NodeObj): Node =
  result = newNodeList()
  for n in args.walk:
    assert(n.kind == nodeAtom, "ls called on a non-atomic node")
    let a = n.atom
    if a.cid.isDagCbor:
        let ufsNode = env.getUnixfs a.cid
        if ufsNode.kind == rootNode:
          for name, u in ufsNode.walk:
            assert(not name.isNil)
            assert(not u.isNil, name & " is nil")
            case u.kind:
            of fileNode:
              result.append Atom(kind: atomFile, fName: name, file: u).newNode
            of dirNode:
              result.append Atom(kind: atomDir, dName: name, dir: u).newNode
            else:
              raiseAssert("unhandled file type")
    else:
      raiseAssert("ls over a raw IPLD block")

proc mapFunc(env: Env; args: NodeObj): Node =
  result = newNodeList()
  let f = args.fun
  for v in args.next.list:
    result.append f(env, v)

proc mergeFunc(env: Env; args: NodeObj): Node =
  var root = newUnixFsRoot()
  for n in args.walk:
    let a = n.atom
    doAssert(a.cid.codec == MulticodecTag.Dag_cbor, "not a CBOR encoded IPLD block")
    let dir = env.getUnixfs a.cid
    for name, node in dir.walk:
      root.add(name, node)
  let cid = waitFor env.store.putDag(root.toCbor)
  cid.newAtom.newNode

proc pathFunc(env: Env; arg: NodeObj): Node =
  #if arg.kind != nodeAtom or arg.atom.kind != atomString:
  #  raiseArgError "invalid type for path conversion"
  result = arg.atom.str.newAtomPath.newNode

proc rootFunc(env: Env; args: NodeObj): Node =
  doAssert(false, "need a string type to pass path elements")

##
# Environment
#

proc bindEnv(env: Env; name: string; fun: Func) =
  assert(not env.bindings.contains name)
  env.bindings[name] = NodeObj(kind: nodeFunc, fun: fun, name: name)

proc newEnv(storePath: string): Env =
  result = Env(
    store: newFileStore(storePath),
    bindings: initTable[string, NodeObj](),
    paths: initTable[string, UnixfsNode](),
    cids: initTable[Cid, UnixfsNode]())
  result.bindEnv "apply", applyFunc
  result.bindEnv "cat", catFunc
  result.bindEnv "cons", consFunc
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

proc eval(ast: Node; env: Env): Node

proc eval_ast(ast: Node; env: Env): Node =
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
        result = new Node
        result[] = env.bindings[ast.atom.sym]
  else: discard

proc eval(ast: Node; env: Env): Node =
  try:
    if ast.kind == nodeList:
      if ast.headRef == nil:
        newNodeList()
      else:
        let
          ast = eval_ast(ast, env)
          head = ast.headRef
        if head.kind == nodeFunc:
          head.fun(env, head.next)
        else:
          newNodeError("not a function", head[])
    else:
      eval_ast(ast, env)
  except EvalError:
    newNodeError(getCurrentExceptionMsg(), ast[])
  except FieldError:
    newNodeError("invalid argument", ast[])

proc main() =
  var
    env: Env
    interactive: bool
  block:
    for kind, key, value in getopt():
      case kind
      of cmdArgument:
        if not env.isNil:
          quit "only a single store path argument is accepted"
        env = newEnv(key)
      of cmdLongOption:
        if key == "interactive":
          interactive = true
      of cmdShortOption:
        if key == "i":
          interactive = true
      of cmdEnd:
        discard
    if env.isNil:
      quit "store path must be passed as an argument"

  let outStream = stdout.newFileStream
  var
    reader = newReader()
    line = newStringOfCap 128
  while true:
    if not stdin.readLine line:
      stderr.writeLine "Path cache miss/hit ", env.pathCacheMiss, "/", env.pathCacheHit
      stderr.writeLine " CID cache miss/hit ", env.cidCacheMiss, "/", env.cidCacheHit
      quit()
    if line.len > 0:
      let ast = reader.read(line)
      if not ast.isNil:
        ast.eval(env).print(outStream)
        outStream.write "\n"
        flush outStream

main()
