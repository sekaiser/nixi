package practice;

import java.util.HashMap;
import java.util.Map;

public final class Solution {
  private Solution() {}

  public static int[] twoSum(int[] nums, int target) {
    Map<Integer, Integer> seen = new HashMap<>();
    for (int i = 0; i < nums.length; i++) {
      int other = target - nums[i];
      if (seen.containsKey(other)) {
        return new int[] {seen.get(other), i};
      }
      seen.put(nums[i], i);
    }
    return new int[0];
  }
}
