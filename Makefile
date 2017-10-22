%: %.nim
	nim c \
		--path:/home/emery/repo/nim-cbor \
		--path:/home/emery/repo/nim-multiformat \
		--path:/home/emery/repo/nim-ipld/ipld/ \
		$<

all: ipfs_client