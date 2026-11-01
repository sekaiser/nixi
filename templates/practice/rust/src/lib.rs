pub struct Solution;

impl Solution {
    pub fn two_sum(nums: Vec<i32>, target: i32) -> Vec<i32> {
        use std::collections::HashMap;

        let mut seen = HashMap::new();
        for (idx, value) in nums.into_iter().enumerate() {
            if let Some(other) = seen.get(&(target - value)) {
                return vec![*other as i32, idx as i32];
            }
            seen.insert(value, idx);
        }
        Vec::new()
    }
}

#[cfg(test)]
mod tests {
    use super::Solution;

    #[test]
    fn two_sum_returns_indices() {
        assert_eq!(Solution::two_sum(vec![2, 7, 11, 15], 9), vec![0, 1]);
    }
}
