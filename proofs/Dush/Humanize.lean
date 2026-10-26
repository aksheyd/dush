namespace Dush.Human

def unitChar : Nat → Char
  | 0 => 'B' | 1 => 'K' | 2 => 'M' | 3 => 'G' | 4 => 'T' | 5 => 'P' | _ => 'E'

def maxFor (len baselen : Nat) : Nat :=
  (List.range (len - baselen)).foldl (fun m _ => m * 10) 1

theorem maxFor_5_2 : maxFor 5 2 = 1000 := by decide

def loop : Nat → Nat → Nat → Nat → Nat × Nat × Nat
  | 0, q, r, i => (q, r, i)
  | fuel + 1, q, r, i =>
    if (q ≥ 1000 ∨ (q = 999 ∧ (r ≥ 973 ∨ r ≥ 512))) ∧ i < 6 then
      loop fuel (q / 1024) (q % 1024) (i + 1)
    else (q, r, i)

def render (q r i : Nat) : String :=
  if ((q = 9 ∧ r < 973) ∨ q < 9) ∧ i > 0 then
    let t := (r * 10 + 512) / 1024
    s!"{q + t / 10}.{t % 10}{unitChar i}"
  else
    s!"{q + (r + 512) / 1024}{unitChar i}"

def humanize (n : Nat) : String :=
  let (q, r, i) := loop 7 n 0 0
  render q r i

def go : Nat → Nat → Nat → Nat × Nat
  | 0, m, i => (m, i)
  | fuel + 1, m, i => if m ≥ 1023488 ∧ i < 6 then go fuel (m / 1024) (i + 1) else (m, i)

def mscale (n : Nat) : Nat × Nat := if n < 1000 then (n, 0) else go 6 n 1

def scale (n : Nat) : Nat := (mscale n).2

def closed (n : Nat) : String :=
  let (m, s) := mscale n
  if s = 0 then s!"{m}{unitChar 0}"
  else if m < 10189 then
    let t := (10 * m + 512) / 1024
    s!"{t / 10}.{t % 10}{unitChar s}"
  else s!"{(m + 512) / 1024}{unitChar s}"

theorem loop_go (fuel : Nat) : ∀ (q r i : Nat), r < 1024 →
    loop fuel q r i =
      ((go fuel (q * 1024 + r) i).1 / 1024, (go fuel (q * 1024 + r) i).1 % 1024,
        (go fuel (q * 1024 + r) i).2) := by
  induction fuel with
  | zero =>
    intro q r i hr
    simp only [loop, go]
    refine Prod.ext ?_ (Prod.ext ?_ rfl) <;> simp <;> omega
  | succ f ih =>
    intro q r i hr
    have hcond : ((q ≥ 1000 ∨ (q = 999 ∧ (r ≥ 973 ∨ r ≥ 512))) ∧ i < 6) ↔
        (q * 1024 + r ≥ 1023488 ∧ i < 6) := by omega
    rw [loop]
    by_cases h : (q * 1024 + r ≥ 1023488 ∧ i < 6)
    · rw [ite_eq_left (hcond.mpr h), ih _ _ _ (Nat.mod_lt _ (by decide))]
      have hgo : go (f + 1) (q * 1024 + r) i = go f ((q * 1024 + r) / 1024) (i + 1) := by
        simp only [go, ite_eq_left h]
      have : q / 1024 * 1024 + q % 1024 = (q * 1024 + r) / 1024 := by omega
      rw [hgo, this]
    · rw [ite_eq_right (fun h' => h (hcond.mp h'))]
      have hgo : go (f + 1) (q * 1024 + r) i = (q * 1024 + r, i) := by
        simp only [go, ite_eq_right h]
      rw [hgo]
      refine Prod.ext ?_ (Prod.ext ?_ rfl) <;> simp <;> omega

theorem go_ge (f : Nat) : ∀ m i, i ≤ (go f m i).2 := by
  induction f with
  | zero => intro m i; simp [go]
  | succ f ih =>
    intro m i; simp only [go]; split
    · exact Nat.le_trans (Nat.le_succ i) (ih _ _)
    · exact Nat.le_refl i

theorem render_closed (m i : Nat) (hi : 0 < i) :
    render (m / 1024) (m % 1024) i =
      (if m < 10189 then
        s!"{(10 * m + 512) / 1024 / 10}.{(10 * m + 512) / 1024 % 10}{unitChar i}"
      else s!"{(m + 512) / 1024}{unitChar i}") := by
  unfold render
  by_cases hm : m < 10189
  · rw [ite_eq_left (by omega), ite_eq_left hm]
    have e1 : m / 1024 + (m % 1024 * 10 + 512) / 1024 / 10 = (10 * m + 512) / 1024 / 10 := by
      omega
    have e2 : (m % 1024 * 10 + 512) / 1024 % 10 = (10 * m + 512) / 1024 % 10 := by omega
    simp only [e1, e2]
  · rw [ite_eq_right (by omega), ite_eq_right hm]
    have e : m / 1024 + (m % 1024 + 512) / 1024 = (m + 512) / 1024 := by omega
    simp only [e]

theorem humanize_eq_closed (n : Nat) : humanize n = closed n := by
  unfold humanize closed mscale
  by_cases hn : n < 1000
  · have : loop 7 n 0 0 = (n, 0, 0) := by simp [loop]; omega
    simp [this, hn, render]
  · have h1 : loop 7 n 0 0 = loop 6 (n / 1024) (n % 1024) 1 := by
      rw [loop, ite_eq_left (by omega)]
    rw [h1, loop_go 6 _ _ _ (Nat.mod_lt _ (by decide))]
    have hm : n / 1024 * 1024 + n % 1024 = n := by omega
    rw [hm, ite_eq_right hn]
    have hpos : 0 < (go 6 n 1).2 := Nat.lt_of_lt_of_le (by decide) (go_ge 6 n 1)
    simp only
    rw [render_closed _ _ hpos, ite_eq_right (Nat.pos_iff_ne_zero.mp hpos)]

def thr : Nat → Nat
  | 0 => 1000
  | s + 1 => 1023488 * 1024 ^ s

theorem mscale_table (n : Nat) : mscale n =
    if n < 1000 then (n, 0)
    else if n < 1023488 then (n, 1)
    else if n < 1023488 * 1024 then (n / 1024, 2)
    else if n < 1023488 * 1024 ^ 2 then (n / 1024 ^ 2, 3)
    else if n < 1023488 * 1024 ^ 3 then (n / 1024 ^ 3, 4)
    else if n < 1023488 * 1024 ^ 4 then (n / 1024 ^ 4, 5)
    else (n / 1024 ^ 5, 6) := by
  simp only [mscale, go, Nat.reducePow, Nat.reduceMul, Nat.reduceLT, Nat.div_div_eq_div_mul,
    Nat.reduceAdd, and_true, Nat.lt_irrefl, and_false, ite_false]
  repeat' split
  all_goals first | rfl | (exfalso; omega) | (simp only [Prod.mk.injEq]; omega)

theorem mscale_cases (n : Nat) :
    (n < 1000 ∧ mscale n = (n, 0)) ∨
    (1000 ≤ n ∧ n < 1023488 ∧ mscale n = (n, 1)) ∨
    (1023488 ≤ n ∧ n < 1023488 * 1024 ∧ mscale n = (n / 1024, 2)) ∨
    (1023488 * 1024 ≤ n ∧ n < 1023488 * 1024 ^ 2 ∧ mscale n = (n / 1024 ^ 2, 3)) ∨
    (1023488 * 1024 ^ 2 ≤ n ∧ n < 1023488 * 1024 ^ 3 ∧ mscale n = (n / 1024 ^ 3, 4)) ∨
    (1023488 * 1024 ^ 3 ≤ n ∧ n < 1023488 * 1024 ^ 4 ∧ mscale n = (n / 1024 ^ 4, 5)) ∨
    (1023488 * 1024 ^ 4 ≤ n ∧ mscale n = (n / 1024 ^ 5, 6)) := by
  rw [mscale_table]
  repeat' split
  all_goals simp only [Prod.mk.injEq, Nat.reducePow, Nat.reduceMul, and_true, Nat.reduceEqDiff,
    and_false, or_false, false_or] at * <;> omega

theorem scale_eq_iff (n s : Nat) (hs : s ≤ 6) :
    scale n = s ↔ (s = 0 ∨ thr (s - 1) ≤ n) ∧ (s = 6 ∨ n < thr s) := by
  unfold scale
  rw [mscale_table]
  have : s = 0 ∨ s = 1 ∨ s = 2 ∨ s = 3 ∨ s = 4 ∨ s = 5 ∨ s = 6 := by omega
  rcases this with h | h | h | h | h | h | h <;> subst h <;>
    simp only [thr, Nat.reducePow, Nat.reduceMul, Nat.reduceSub, Nat.pow_zero, Nat.mul_one] <;>
    repeat' split
  all_goals first | omega | (simp only at *; omega) | (simp <;> omega)

theorem mantissa_eq (n : Nat) : (mscale n).1 = n / 1024 ^ (scale n - 1) := by
  unfold scale
  rw [mscale_table]
  repeat' split
  all_goals simp_all [Nat.reducePow] <;> omega

theorem scale_mono {n n' : Nat} (h : n ≤ n') : scale n ≤ scale n' := by
  unfold scale
  rw [mscale_table, mscale_table]
  simp only [Nat.reducePow, Nat.reduceMul]
  repeat' split
  all_goals simp only <;> omega

def tenths (m : Nat) : Nat := if m < 10189 then (10 * m + 512) / 1024 else 10 * ((m + 512) / 1024)

def value10 (n : Nat) : Nat :=
  let (m, s) := mscale n
  if s = 0 then 10 * m else tenths m * 1024 ^ s

theorem tenths_mono {m m' : Nat} (h : m ≤ m') : tenths m ≤ tenths m' := by
  unfold tenths; split <;> split <;> omega

theorem scale_le_six (n : Nat) : scale n ≤ 6 := by
  unfold scale; rw [mscale_table]; repeat' split
  all_goals simp

theorem value10_eq (n : Nat) : value10 n =
    if scale n = 0 then 10 * n else tenths (n / 1024 ^ (scale n - 1)) * 1024 ^ scale n := by
  unfold value10 scale
  rcases mscale_cases n with ⟨h1, h⟩ | ⟨h1, h2, h⟩ | ⟨h1, h2, h⟩ | ⟨h1, h2, h⟩ | ⟨h1, h2, h⟩ |
    ⟨h1, h2, h⟩ | ⟨h1, h⟩ <;> rw [h] <;> simp

theorem value10_upper (n : Nat) (h : scale n < 6) : value10 n ≤ 9990 * 1024 ^ scale n := by
  have hu : ∀ m, m < 1023488 → tenths m ≤ 9990 := by intro m hm; unfold tenths; split <;> omega
  revert h; rw [value10_eq]; unfold scale
  rcases mscale_cases n with ⟨h1, h⟩ | ⟨h1, h2, h⟩ | ⟨h1, h2, h⟩ | ⟨h1, h2, h⟩ | ⟨h1, h2, h⟩ |
    ⟨h1, h2, h⟩ | ⟨h1, h⟩ <;> rw [h] <;> simp only [Nat.reduceEqDiff, ite_true, ite_false,
      Nat.reduceSub, Nat.pow_zero, Nat.pow_one, Nat.div_one, Nat.reducePow] at * <;> intro hs
  all_goals first | exact Nat.mul_le_mul_right _ (hu _ (by omega)) | omega

theorem value10_lower (n : Nat) (h : 0 < scale n) : 10 * 1024 ^ scale n ≤ value10 n := by
  have hl : ∀ m, 999 ≤ m → 10 ≤ tenths m := by intro m hm; unfold tenths; split <;> omega
  revert h; rw [value10_eq]; unfold scale
  rcases mscale_cases n with ⟨h1, h⟩ | ⟨h1, h2, h⟩ | ⟨h1, h2, h⟩ | ⟨h1, h2, h⟩ | ⟨h1, h2, h⟩ |
    ⟨h1, h2, h⟩ | ⟨h1, h⟩ <;> rw [h] <;> simp only [Nat.reduceEqDiff, ite_true, ite_false,
      Nat.reduceSub, Nat.pow_zero, Nat.pow_one, Nat.div_one, Nat.reducePow] at * <;> intro hs
  all_goals first | omega | exact Nat.mul_le_mul_right _ (hl _ (by omega))

theorem value10_mono {n n' : Nat} (h : n ≤ n') : value10 n ≤ value10 n' := by
  have hs := scale_mono h
  rcases Nat.lt_or_eq_of_le hs with hlt | heq
  · have h6 : scale n < 6 := Nat.lt_of_lt_of_le hlt (scale_le_six n')
    have hp : 1024 ^ (scale n + 1) ≤ 1024 ^ scale n' := Nat.pow_le_pow_right (by decide) hlt
    have := value10_upper n h6
    have := value10_lower n' (by omega)
    rw [Nat.pow_succ] at hp
    omega
  · rw [value10_eq, value10_eq, ← heq]
    split
    · omega
    · exact Nat.mul_le_mul_right _ (tenths_mono (Nat.div_le_div_right h))

theorem mantissa_bounds (n : Nat) (_h : n < 2 ^ 63) :
    ((mscale n).2 = 0 → (mscale n).1 ≤ 999) ∧
    ((mscale n).2 ≠ 0 → (mscale n).1 < 10189 → (10 * (mscale n).1 + 512) / 1024 ≤ 99) ∧
    ((mscale n).2 ≠ 0 → ¬ (mscale n).1 < 10189 →
      10 ≤ ((mscale n).1 + 512) / 1024 ∧ ((mscale n).1 + 512) / 1024 ≤ 999) := by
  rcases mscale_cases n with ⟨h1, h⟩ | ⟨h1, h2, h⟩ | ⟨h1, h2, h⟩ | ⟨h1, h2, h⟩ | ⟨h1, h2, h⟩ |
    ⟨h1, h2, h⟩ | ⟨h1, h⟩ <;> rw [h] <;>
    simp only [Nat.reducePow, Nat.reduceMul] at * <;> omega

example : humanize 0 = "0B" := by decide
example : humanize 999 = "999B" := by decide
example : humanize 1000 = "1.0K" := by decide
example : humanize 1024 = "1.0K" := by decide
example : humanize 1536 = "1.5K" := by decide
example : humanize 8192 = "8.0K" := by decide
example : humanize 10188 = "9.9K" := by decide
example : humanize 10189 = "10K" := by decide
example : humanize 16384 = "16K" := by decide
example : humanize 50000 = "49K" := by decide
example : humanize 1023487 = "999K" := by decide
example : humanize 1023488 = "1.0M" := by decide
example : humanize 1048576 = "1.0M" := by decide
example : humanize 1073741824 = "1.0G" := by decide

end Dush.Human
