package practice

import "testing"

func TestTwoSum(t *testing.T) {
	got := TwoSum([]int{2, 7, 11, 15}, 9)
	want := []int{0, 1}

	if len(got) != len(want) {
		t.Fatalf("len(TwoSum()) = %d, want %d", len(got), len(want))
	}
	for i := range got {
		if got[i] != want[i] {
			t.Fatalf("TwoSum()[%d] = %d, want %d", i, got[i], want[i])
		}
	}
}
