TAG="reachsh/stdlib:v0.1.1"
NAME="stdlib"

.PHONY: build
build:
	docker build --tag=$(TAG) .

.PHONY: push
push:
	docker push $(TAG)

.PHONY: publish
publish:
	npm publish --access public

.PHONY: run
run:
	docker-compose run $(NAME)

.PHONY: test
test: run
