#
# \brief  Procedures for exporting packages to Dagfs
# \author Emery Hemingway
# \date   2018-01-01
#

#
# Spawn the REPL process
#
set timeout -1
spawn dagfs_repl -s
set repl_id $spawn_id

proc make_a_goddamn_string { stringliststring } {
	return [join $stringliststring " "]
}

proc dagfs_ingest { args } {
	global repl_id

	set paths [make_a_goddamn_string $args]

	# convert quoted paths to the path type, apply ingest to the result
	send -i $repl_id "(ingest $paths)\n"

	expect -i $repl_id "\n"
	expect -i $repl_id "\n"
	set cid [lindex [regexp -inline {[a-f0-9]*} $expect_out(buffer)] 0]
	puts "cid is $cid"
	return $cid
}

proc dagfs_ingest_string { name string } {
	global repl_id

	set path [file normalize $name]
	set fd [open $path "WRONLY CREAT TRUNC"]
	puts $fd $string
	close $fd

	# convert quoted paths to the path type, apply ingest to the result
	send -i $repl_id "(ingest $path)\n"

	expect -i $repl_id "\n"
	expect -i $repl_id "\n"
	set cid [lindex [regexp -inline {[a-f0-9]*} $expect_out(buffer)] 0]
	file delete $path
	return $cid

}

proc dagfs_copy { cid from to } {
	global repl_id

	send -i $repl_id "(copy $cid \"$from\" \"$to\")\n"

	expect -i $repl_id "\n"
	expect -i $repl_id "\n"
	set cid [lindex [regexp -inline {[a-f0-9]*} $expect_out(buffer)] 0]
	return $cid
}

proc dagfs_merge { args } {
	global repl_id

	set cids [make_a_goddamn_string $args]

	send -i $repl_id "(merge $cids)\n"

	expect -i $repl_id "\n"
	expect -i $repl_id "\n"
	set cid [lindex [regexp -inline {[a-f0-9]*} $expect_out(buffer)] 0]
	return $cid
}

proc dagfs_cid_from_depot { args } {
	set cids {}

	set archives [_collect_from_depot [join $args " "]]

	check_for_missing_depot_archives

	set globs ""

	foreach archive $archives {
		# Do not include sources for now
		if {[regexp [_depot_archive_versioned_path_pattern] $archive dummy user type]} {
			if {$type == "src"} continue;
			if {$type == "api"} continue;
			if {$type == "pkg"} continue;
		}

		set globs "$globs \"[depot_dir]/$archive/*\""
	}

	global repl_id

	send -i $repl_id "(apply ingest (glob $globs))\n"

	expect -i $repl_id "\n"
	expect -i $repl_id "\n"

	set cid [lindex [regexp -inline {[a-f0-9]*} $expect_out(buffer)] 0]

	return $cid
}
