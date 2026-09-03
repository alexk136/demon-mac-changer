.PHONY: install uninstall test lint help

help:
	@echo "make install   - install to system (requires root)"
	@echo "make uninstall - remove from system (preserves /etc/demon-mac.conf and state)"
	@echo "make test      - run smoke tests"
	@echo "make lint      - bash -n on scripts"

install:
	./install.sh

uninstall:
	./uninstall.sh

test:
	./tests/smoke.sh

lint:
	bash -n demon-mac.sh
	bash -n install.sh
	bash -n uninstall.sh
	bash -n tests/smoke.sh
	bash -n networkmanager/99-demon-mac