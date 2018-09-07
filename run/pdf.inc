#
# \brief  Procedures for creating PDF viewing packages in an IPLD store
# \author Emery Hemingway
# \date   2017-11-19
#

source [genode_dir]/repos/ipld/run/ipld.inc

proc pdf_view_closure { pdf_path } {
	set public_cid [ipld_public_cid_from_depot \
		genodelabs/src/nit_fb \
		genodelabs/pkg/pdf_view \
		genodelabs/src/init \
	]

	return $public_cid

	foreach cid $public_cids {
		set paths [exec ipldstore [public_store_dir] dump $cid]
		#file copy $paths [run_store_dir]
	}

	#set pdf_cid [ipld_run_store_add $pdf_path]
	#return $pdf_cid
	
	return $public_cids
}

proc pdf_config {} {
	return {
<config>
	<parent-provides>
		<service name="CPU"/>
		<service name="LOG"/>
		<service name="PD"/>
		<service name="RM"/>
		<service name="ROM"/>
		<service name="File_system"/>
		<service name="Nitpicker"/>
		<service name="Timer"/>
	</parent-provides>
	<default-route>
		<any-service> <parent/> <any-child/> </any-service>
	</default-route>
	<start name="nit_fb" caps="128">
		<resource name="RAM" quantum="4M"/>
		<provides>
			<service name="Framebuffer"/>
			<service name="Input"/>
		</provides>
	</start>
	<start name="pdf_view" caps="256">
		<resource name="RAM" quantum="1G"/>
		<config>
			<vfs>
				<fs writeable="no"/>
				<dir name="dev"> <log/> </dir>
			</vfs>
			<libc stdout="/dev/log" stderr="/dev/log"/>
		</config>
	</start>
</config>
	}
}

proc pdf_config_cid {} {
	set configfile [run_dir]/config
	set fh [open $configfile "WRONLY CREAT TRUNC"]
	puts $fh [pdf_config]
	close $fh
	return [ipld_public_ingest $configfile]
}


proc pdf_content_cid { args } {
	set path [lindex $args 0]
	file copy $path [run_dir]/test.pdf
	return [ipld_public_ingest [run_dir]/test.pdf]
}
