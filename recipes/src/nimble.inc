content: mk/nimble.mk

mk/nimble.mk: $(GENODE_DIR)/repos/world/mk/nimble.mk
	mkdir -p $(dir $@)
	cp $< $@
