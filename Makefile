.PHONY: build release run install restart restart-app clean lint format bundle

# Directories
APP_SUPPORT_DIR := $(HOME)/Library/Application Support/AgentSprites
CHARACTERS_DIR := $(APP_SUPPORT_DIR)/Characters

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

# Bundle creates the .app with embedded CLI
bundle: build
	@bash Resources/bundle-app.sh debug

release:
	swift build -c release
	@bash Resources/bundle-app.sh release

run: bundle
	open .build/debug/AgentSprites.app

# Full installation (builds release, installs app bundle to /Applications)
install: release install-characters
	@echo "Installing AgentSprites.app to /Applications..."
	@rm -rf "/Applications/AgentSprites.app"
	@cp -r .build/release/AgentSprites.app "/Applications/"
	@echo ""
	@echo "=== Installation Complete ==="
	@echo "App installed to: /Applications/AgentSprites.app"
	@echo "Character packs: $(CHARACTERS_DIR)"
	@echo ""
	@echo "To start: open /Applications/AgentSprites.app"
	@echo "The app will prompt to install Claude Code hooks on first run."

# Quick restart for development: rebuild, bundle, restart app
restart: bundle install-characters
	@echo "Restarting app..."
	@-pkill -x AgentSprites 2>/dev/null || true
	@sleep 0.3
	@open .build/debug/AgentSprites.app
	@echo "Done!"

restart-app: bundle
	@-pkill -x AgentSprites 2>/dev/null || true
	@sleep 0.3
	@open .build/debug/AgentSprites.app
	@echo "App restarted"

clean:
	swift package clean
	rm -rf .build/debug/AgentSprites.app
	rm -rf .build/release/AgentSprites.app

# Linting and formatting
lint:
	swift package --allow-writing-to-package-directory swiftlint

lint-fix:
	swift package --allow-writing-to-package-directory swiftlint --fix

format:
	swift package --allow-writing-to-package-directory swiftformat

format-check:
	swift package --allow-writing-to-package-directory swiftformat --dryrun
