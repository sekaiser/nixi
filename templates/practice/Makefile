.PHONY: test test-rust test-go test-java fmt fmt-rust fmt-go fmt-java

test: test-rust test-go test-java

test-rust:
	cd rust && cargo test

test-go:
	cd go && go test ./...

test-java:
	cd java && mvn test

fmt: fmt-rust fmt-go fmt-java

fmt-rust:
	cd rust && cargo fmt

fmt-go:
	cd go && gofmt -w .

fmt-java:
	find java/src -name '*.java' -print0 | xargs -0 google-java-format -i
