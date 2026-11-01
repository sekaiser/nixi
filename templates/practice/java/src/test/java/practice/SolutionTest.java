package practice;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;

import org.junit.jupiter.api.Test;

final class SolutionTest {
  @Test
  void twoSumReturnsIndices() {
    assertArrayEquals(new int[] {0, 1}, Solution.twoSum(new int[] {2, 7, 11, 15}, 9));
  }
}
