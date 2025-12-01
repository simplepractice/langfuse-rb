.DEFAULT_GOAL := help

.PHONY: help build check clean env fix install lint setup test

BLUE := \033[34m
WHITE := \033[37m
GRAY := \033[90m
RESET := \033[0m

help:
	@echo ""
	@echo "  $(BLUE)🪢  Langfuse Ruby SDK$(RESET)"
	@echo ""
	@echo "  $(WHITE)make build$(RESET)     $(GRAY)Build the gem$(RESET)"
	@echo "  $(WHITE)make check$(RESET)     $(GRAY)Run tests + lint (CI check)$(RESET)"
	@echo "  $(WHITE)make clean$(RESET)     $(GRAY)Remove generated files$(RESET)"
	@echo "  $(WHITE)make env$(RESET)       $(GRAY)Copy .env.example to .env$(RESET)"
	@echo "  $(WHITE)make fix$(RESET)       $(GRAY)Auto-fix RuboCop violations$(RESET)"
	@echo "  $(WHITE)make install$(RESET)   $(GRAY)Install gem locally$(RESET)"
	@echo "  $(WHITE)make lint$(RESET)      $(GRAY)Run RuboCop linter$(RESET)"
	@echo "  $(WHITE)make setup$(RESET)     $(GRAY)Install dependencies$(RESET)"
	@echo "  $(WHITE)make test$(RESET)      $(GRAY)Run RSpec test suite$(RESET)"
	@echo ""

build:
	gem build langfuse.gemspec

check: test lint

clean:
	rm -f langfuse-*.gem
	rm -rf coverage/
	rm -rf pkg/

env:
	cp .env.example .env

fix:
	bundle exec rubocop -A

install: build
	gem install langfuse-*.gem

lint:
	bundle exec rubocop

setup:
	bundle install

test:
	bundle exec rspec
