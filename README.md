# WARNING

Contains my own contrived standards and formats that will break often.

## ipldrepl

A Lisp REPL utility for storing files and directories in IPLD.

### Functions

#### `(apply <function> <list>)`

Standard Lisp `apply` function, apply a list as arguments to a function.

#### `(cons <head> <tail>)`

Standard Lisp `cons` function, prepend to a list.

#### `(define <symbol> <value>)`

Bind a value to a symbol. Returns value.

#### `(dump <cid> <...>)`

Return a list of paths as they appear in the builtin file store for a give list of CIDs.

#### `(glob <glob-string> <...>)`

Return a list of paths matching a Unix-style glob string.

#### `(ingest <path> <...>)`

Ingest a list of paths to the store, returning a CID to a directory with
the contents each path under the trailing name of the path.

#### `(map <function> <list>)`

Standard Lisp `map`, apply a function to each member of a list.

#### `(merge <cid> <...>)`

Merge a list of root directories represented by CIDs into a new root.
Members of the root are not merged recursively.

#### `(path <string>)`

Convert a string to a path, if the path is valid and present.

#### `(root <string> <cid>)`

Create a new root contaning the giving CID at the given name.

#### `(walk <cid> <string>)`

Walk a path down one CID to another.
