build: test_master

test_0_15_2:
	@echo $(ARGS)
	mise exec zig@0.15.2 -- zig build test --summary all -freference-trace=7 $(ARGS)

test_master:
	@echo $(ARGS)
	mise exec zig@master -- zig build test --summary all -freference-trace=7 $(ARGS)
