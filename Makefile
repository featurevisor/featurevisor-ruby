.PHONY: install build test setup-monorepo update-monorepo

install:
	bundle install

build:
	gem build featurevisor.gemspec

test:
	bundle exec rspec spec/

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
