# Quality gates. Same commands as pre-commit hooks and Gitea jobs.
# Emergency skip: SKIP=tests,sast,audit,gitleaks,style git commit
# Local JRuby (optional): JRUBY_HOME=$HOME/.local/share/jruby-10.0.6.0
# Gitea jobs use docker.io/jruby:10.0, where ruby/bundle are already JRuby.

JRUBY_HOME ?= $(HOME)/.local/share/jruby-10.0.6.0
export PATH := $(HOME)/.local/bin:$(PATH)
ifneq ($(wildcard $(JRUBY_HOME)/bin/jruby),)
export PATH := $(JRUBY_HOME)/bin:$(PATH)
endif

.PHONY: test sast audit gitleaks style check hooks

test:
	bundle exec ruby handler_test.rb

sast:
	semgrep --config p/ruby --error --metrics=off --exclude vendor --exclude .bundle .

audit:
	bundle exec bundle-audit check --update

gitleaks:
	gitleaks detect --source . --verbose --redact

style:
	bundle exec rubocop

check: test sast audit gitleaks style

hooks:
	pre-commit install
	git config core.hooksPath .githooks

