SRCS = $(shell find src/ -name '*.d')

flash2url: $(SRCS)
	ldc2 -O2 -g $^ --of=$@ --L=-llzma
	rm -f $@.o
flash2url_unittest: $(SRCS)
	ldc2 -O0 -g $^ --of=$@ --L=-llzma --unittest
	rm -f $@.o

.PHONY: test
test: flash2url_unittest
	./flash2url_unittest

watch: $(SRCS)
	ls $^ | entr -cs 'make'

install:
	ln -s "$$PWD/flash2url" ~/.local/bin/
