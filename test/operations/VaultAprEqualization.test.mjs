import assert from "node:assert/strict";
import test from "node:test";

import { calculateEqualizingWeights } from "../../scripts/operations/plan-vault-apr-equalization.mjs";

function bucket(id, tvlUsd, rewardPerSecondUsd, periodFinish = 1_000, calculatedAt = 0) {
  return {
    id,
    tvlUsd: String(tvlUsd),
    rewardPerSecondUsd: String(rewardPerSecondUsd),
    periodFinish: String(periodFinish),
    calculatedAt,
  };
}

test("sends all fees to the single losing bucket until it reaches the next level", () => {
  const plan = calculateEqualizingWeights(
    [bucket("compound", 100, 0), bucket("usdg", 100, 1), bucket("weth", 100, 1), bucket("spy", 100, 1)],
    100,
  );
  assert.equal(plan.firstPriorityBucket, "compound");
  assert.deepEqual(plan.weightsBps, [9_997, 1, 1, 1]);
});

test("water-fills multiple losing buckets before funding a winner", () => {
  const plan = calculateEqualizingWeights(
    [bucket("compound", 100, 0), bucket("usdg", 100, 0.25), bucket("weth", 100, 1), bucket("spy", 100, 1)],
    1_000,
  );
  assert.deepEqual(plan.weightsBps, [6_248, 3_750, 1, 1]);
});

test("equal four buckets split new revenue in proportion to TVL", () => {
  const plan = calculateEqualizingWeights(
    [bucket("compound", 400, 4), bucket("usdg", 300, 3), bucket("weth", 200, 2), bucket("spy", 100, 1)],
    1_000,
  );
  assert.deepEqual(plan.weightsBps, [4_000, 3_000, 2_000, 1_000]);
});

test("largest-remainder rounding is deterministic and totals 10000", () => {
  const plan = calculateEqualizingWeights(
    [bucket("a", 1, 0), bucket("b", 1, 0), bucket("c", 1, 0)],
    1,
  );
  assert.deepEqual(plan.weightsBps, [3_334, 3_333, 3_333]);
  assert.equal(plan.weightsBps.reduce((sum, weight) => sum + weight, 0), 10_000);
});

test("zero modeled fees reports only the lowest live APR bucket", () => {
  const plan = calculateEqualizingWeights(
    [bucket("compound", 100, 0), bucket("usdg", 100, 1), bucket("weth", 100, 2), bucket("spy", 100, 3)],
    0,
  );
  assert.deepEqual(plan.weightsBps, [10_000, 0, 0, 0]);
});

test("rejects buckets without positive TVL", () => {
  assert.throws(
    () => calculateEqualizingWeights([bucket("a", 0, 0), bucket("b", 100, 1)], 10),
    /invalid bucket values/,
  );
});
