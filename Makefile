EMACS ?= emacs

# elwidget depends only on json.el + org (both built-in).  -L . is
# enough for the require chain.
LOAD = -L .

SRCS = loophabits.el

all: compile

compile:
	$(EMACS) --batch $(LOAD) --eval '(setq byte-compile-error-on-warn t)' \
	-f batch-byte-compile $(SRCS)

# tests/run.el loads every tests/test-*.el and exits 0/1.  All tests are
# offline: backends are stubbed, no browser and no device are needed.
test:
	$(EMACS) --batch -l tests/run.el

clean:
	rm -f $(SRCS:.el=.elc) tests/*.elc

.PHONY: all compile test clean
