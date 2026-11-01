package main

import "testing"

func TestGreeting(t *testing.T) {
	if got := Greeting(); got != "Hello World!" {
		t.Fatalf("Greeting() = %q", got)
	}
}
