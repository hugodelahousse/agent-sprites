.PHONY: build release run install restart restart-daemon restart-app clean setup-characters

# Directories
INSTALL_DIR := $(HOME)/.agentsprites
BIN_DIR := $(INSTALL_DIR)/bin
CHARACTERS_DIR := $(INSTALL_DIR)/characters
LAUNCH_AGENTS_DIR := $(HOME)/Library/LaunchAgents
PLIST_NAME := com.agentsprites.daemon.plist
DAEMON_LABEL := com.agentsprites.daemon

# Install character packs to runtime directory (not bundled with app)
install-characters:
	@mkdir -p "$(CHARACTERS_DIR)"
	@for pack in CharacterPacks/*/; do \
		name=$$(basename "$$pack"); \
		rm -rf "$(CHARACTERS_DIR)/$$name"; \
		cp -r "$$pack" "$(CHARACTERS_DIR)/$$name"; \
	done
	@cp CharacterPacks/sprites-config.json "$(CHARACTERS_DIR)/" 2>/dev/null || true
	@echo "Character packs installed to $(CHARACTERS_DIR)"

build:
	swift build

release: setup-characters
	swift build -c release

run: build
	.build/debug/AgentSprites &

# Full installation (builds release, installs binaries, configures hooks)
install:
	./Resources/install.sh

# Quick restart for development: rebuild, reinstall binaries, restart daemon + app
restart: build install-characters
	@echo "Installing binaries..."
	@mkdir -p "$(BIN_DIR)"
	@cp .build/debug/agentsprites-daemon "$(BIN_DIR)/"
	@cp .build/debug/agentsprites-cli "$(BIN_DIR)/"
	@cp .build/debug/AgentSprites "$(BIN_DIR)/"
	@chmod +x "$(BIN_DIR)/agentsprites-daemon"
	@chmod +x "$(BIN_DIR)/agentsprites-cli"
	@chmod +x "$(BIN_DIR)/AgentSprites"
	@echo "Restarting daemon..."
	@-launchctl kickstart -k "gui/$$(id -u)/$(DAEMON_LABEL)" 2>/dev/null || \
		(echo "Daemon not loaded, loading..." && \
		 launchctl bootstrap "gui/$$(id -u)" "$(LAUNCH_AGENTS_DIR)/$(PLIST_NAME)" 2>/dev/null; \
		 launchctl kickstart "gui/$$(id -u)/$(DAEMON_LABEL)")
	@echo "Restarting app..."
	@-pkill -x AgentSprites 2>/dev/null || true
	@sleep 0.3
	@"$(BIN_DIR)/AgentSprites" &
	@echo "Done!"

restart-daemon: build
	@cp .build/debug/agentsprites-daemon "$(BIN_DIR)/"
	@chmod +x "$(BIN_DIR)/agentsprites-daemon"
	@-launchctl kickstart -k "gui/$$(id -u)/$(DAEMON_LABEL)" 2>/dev/null || true
	@echo "Daemon restarted"

restart-app: build
	@cp .build/debug/AgentSprites "$(BIN_DIR)/"
	@chmod +x "$(BIN_DIR)/AgentSprites"
	@-pkill -x AgentSprites 2>/dev/null || true
	@sleep 0.3
	@"$(BIN_DIR)/AgentSprites" &
	@echo "App restarted"

clean:
	swift package clean
