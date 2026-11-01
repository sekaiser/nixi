package practice

func TwoSum(nums []int, target int) []int {
	seen := map[int]int{}
	for i, value := range nums {
		if j, ok := seen[target-value]; ok {
			return []int{j, i}
		}
		seen[value] = i
	}
	return nil
}
