SRCS = src/*.d

flash2url: $(SRCS)
	#dmd -g -defaultlib=libphobos2.so $^ -of=$@ -L=-llzma -L=-fuse-ld=lld
	ldc2 -O0 -g $^ --of=$@ --L=-llzma

watch: $(SRCS)
	ls $^ | entr -cs 'make'

install:
	ln -s "$$PWD/flash2url" ~/.local/bin/
