.PHONY: install build verify-artifacts test test-base test-example-1 setup-monorepo update-monorepo

install:
	bundle install

build:
	bundle exec rake build

verify-artifacts:
	bundle exec ruby scripts/verify_gems.rb

test:
	bundle exec rspec spec/

test-base:
	BUNDLE_GEMFILE=gemfiles/base.gemfile bundle exec rspec spec/ --exclude-pattern spec/openfeature_provider_spec.rb

test-example-1:
	bundle exec rspec spec/
	bundle exec ruby bin/featurevisor test --projectDirectoryPath=../featurevisor/examples/example-1 --onlyFailures

setup-monorepo:
	mkdir -p monorepo
	if [ ! -d "monorepo/.git" ]; then \
		git clone git@github.com:featurevisor/featurevisor.git monorepo; \
	else \
		(cd monorepo && git fetch origin main && git checkout main && git pull origin main); \
	fi
	(cd monorepo && make install && make build)

update-monorepo:
	(cd monorepo && git pull origin main)
