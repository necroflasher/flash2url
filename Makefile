SRCS = src/*.d

flash2url: $(SRCS)
	dmd -g -defaultlib=libphobos2.so $^ -of=$@ -L=-llzma -L=-fuse-ld=lld

watch: $(SRCS)
	ls $^ | entr -cs 'make'
