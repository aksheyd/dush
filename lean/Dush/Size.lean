/-
Size formulas shared by the bulk walker and by macOS `du`.

`du` accumulates 512-byte units (`DEV_BSIZE`). Apparent size is
`howmany(st_size, 512)`. Physical size is `st_blocks` (already in
512-byte units). `dush` stores the same quantities in bytes:
`round512 st_size` and `st_blocks * 512`. With `-k`, both then print
`howmany(totalBytes, 1024)`.
-/

namespace Dush

def howmany (x y : Nat) : Nat :=
  (x + (y - 1)) / y

/-- Least multiple of 512 that is ≥ `n`. This is `du -A`'s file contribution, in bytes. -/
def round512 (n : Nat) : Nat :=
  (n + 511) / 512 * 512

/-- Physical contribution in bytes. `st_blocks` is in 512-byte units. -/
def physical (blocks : Nat) : Nat :=
  blocks * 512

def statBytes (apparent : Bool) (logical blocks : Nat) : Nat :=
  if apparent then round512 logical else physical blocks

/-- `-k` display of a byte total: `ceil(bytes / 1024)`. -/
def kBlocks (bytes : Nat) : Nat :=
  (bytes + 1023) / 1024

theorem round512_dvd (n : Nat) : 512 ∣ round512 n := by
  unfold round512
  exact Nat.dvd_mul_left 512 ((n + 511) / 512)

theorem round512_eq_pad (n : Nat) :
    round512 n = 512 * (n / 512) + if n % 512 = 0 then 0 else 512 := by
  unfold round512
  have hd : 0 < 512 := by decide
  have hr : n % 512 < 512 := Nat.mod_lt n hd
  have hdiv : 512 * (n / 512) + n % 512 = n := Nat.div_add_mod n 512
  have hsum : n + 511 = 512 * (n / 512) + (n % 512 + 511) := by omega
  rw [hsum, Nat.mul_add_div hd]
  by_cases h0 : n % 512 = 0
  · simp [h0, Nat.mul_comm]
  · have hpos : 0 < n % 512 := Nat.pos_of_ne_zero h0
    have hk : n % 512 - 1 < 512 := by omega
    have hsplit : n % 512 + 511 = 512 + (n % 512 - 1) := by omega
    have hquot : (n % 512 + 511) / 512 = 1 := by
      rw [hsplit]
      have : (512 * 1 + (n % 512 - 1)) / 512 = 1 + (n % 512 - 1) / 512 :=
        Nat.mul_add_div hd 1 (n % 512 - 1)
      rw [this, Nat.div_eq_of_lt hk]
    simp [h0, hquot, Nat.mul_add, Nat.mul_comm]

theorem le_round512 (n : Nat) : n ≤ round512 n := by
  rw [round512_eq_pad]
  have hdiv : 512 * (n / 512) + n % 512 = n := Nat.div_add_mod n 512
  by_cases h0 : n % 512 = 0
  · simp [h0] at hdiv ⊢
    omega
  · simp [h0]
    have : n = 512 * (n / 512) + n % 512 := hdiv.symm
    omega

/-- `round512 n` is the least multiple of 512 that is at least `n`. -/
theorem round512_min {n m : Nat} (hm : 512 ∣ m) (hn : n ≤ m) : round512 n ≤ m := by
  rcases hm with ⟨k, hk⟩
  have hdiv : 512 * (n / 512) + n % 512 = n := Nat.div_add_mod n 512
  rw [round512_eq_pad]
  by_cases h0 : n % 512 = 0
  · simp [h0] at hdiv ⊢
    omega
  · simp [h0]
    have hr : 0 < n % 512 := Nat.pos_of_ne_zero h0
    have hkgt : n / 512 < k := by
      by_cases hle : k ≤ n / 512
      · have hmul : 512 * k ≤ 512 * (n / 512) := Nat.mul_le_mul_left 512 hle
        have hm' : m ≤ 512 * (n / 512) := by simpa [hk] using hmul
        omega
      · omega
    have hstep : 512 * (n / 512) + 512 = 512 * (n / 512 + 1) := by omega
    have hmul : 512 * (n / 512 + 1) ≤ 512 * k := Nat.mul_le_mul_left 512 hkgt
    omega

theorem round512_eq_of_dvd {n : Nat} (h : 512 ∣ n) : round512 n = n := by
  have hle := le_round512 n
  have hge := round512_min h (Nat.le_refl n)
  omega

theorem round512_1000 : round512 1000 = 1024 := by native_decide

theorem round512_10MiB : round512 (10 * 1024 * 1024) = 10 * 1024 * 1024 := by
  native_decide

theorem round512_zero : round512 0 = 0 := by native_decide

/-- Odd logical lengths move up to the next 512-byte unit; aligned lengths do not. -/
theorem apparent_odd_rounds_up : round512 1000 = 1024 ∧ round512 1000 ≠ 1000 := by
  native_decide

/--
`du -k` on a physical total of `b` blocks prints `(b + 1) / 2`.
`dush -k` prints `ceil((b * 512) / 1024)`. Those are the same number.
-/
theorem physical_kBlocks (b : Nat) : kBlocks (physical b) = (b + 1) / 2 := by
  unfold kBlocks physical
  have hmod : b % 2 = 0 ∨ b % 2 = 1 := by
    have := Nat.mod_lt b (by decide : 0 < 2)
    omega
  cases hmod with
  | inl h0 =>
    let q := b / 2
    have hq : q = b / 2 := rfl
    have hb : b = 2 * q := by
      have hdiv := Nat.div_add_mod b 2
      simp [h0] at hdiv
      omega
    rw [hb]
    have hL : (2 * q * 512 + 1023) / 1024 = q := by
      have hmul : 2 * q * 512 = 1024 * q := by omega
      rw [hmul]
      have hd : 1024 > 0 := by decide
      have := Nat.mul_add_div hd q 1023
      have h1023 : 1023 / 1024 = 0 := Nat.div_eq_of_lt (by decide)
      omega
    have hR : (2 * q + 1) / 2 = q := by
      have hd : 2 > 0 := by decide
      have := Nat.mul_add_div hd q 1
      have h1 : 1 / 2 = 0 := Nat.div_eq_of_lt (by decide)
      omega
    omega
  | inr h1 =>
    let q := b / 2
    have hq : q = b / 2 := rfl
    have hb : b = 2 * q + 1 := by
      have hdiv := Nat.div_add_mod b 2
      simp [h1] at hdiv
      omega
    rw [hb]
    have hmul : (2 * q + 1) * 512 = 1024 * q + 512 := by omega
    have hL : ((2 * q + 1) * 512 + 1023) / 1024 = q + 1 := by
      rw [hmul]
      have hd : 1024 > 0 := by decide
      have hassoc : 1024 * q + 512 + 1023 = 1024 * q + (1024 + 511) := by omega
      rw [hassoc]
      have := Nat.mul_add_div hd q (1024 + 511)
      have hrest : (1024 + 511) / 1024 = 1 := by
        have := Nat.mul_add_div hd 1 511
        have h511 : 511 / 1024 = 0 := Nat.div_eq_of_lt (by decide)
        omega
      omega
    have hR : (2 * q + 1 + 1) / 2 = q + 1 := by
      have h2 : 2 * q + 2 = 2 * (q + 1) := by omega
      have hd : 2 > 0 := by decide
      have := Nat.mul_add_div hd (q + 1) 0
      omega
    omega

/-- Apparent `-k` is the same conversion applied to `round512`. -/
theorem apparent_kBlocks (logical : Nat) :
    kBlocks (round512 logical) = howmany (howmany logical 512 * 512) 1024 := by
  simp [kBlocks, round512, howmany]

theorem kBlocks_congr {a b : Nat} (h : a = b) : kBlocks a = kBlocks b := by
  simp [kBlocks, h]

/-
`allocatedSizeAt` and the bulk size choice in `workerFn`.

A missing bulk size, and every apparent-size entry, uses `fstatat`
(`AT_SYMLINK_NOFOLLOW`). Apparent size is rounded. A present physical
size is trusted as-is. A name that does not fit in the 1024-byte buffer,
or a failed stat, contributes 0 on the stat path.
-/

def entrySize (apparent : Bool) (size? : Option Nat) (statOk : Bool)
    (nameLen logical blocks : Nat) : Nat :=
  if apparent || size?.isNone then
    if nameLen ≥ 1024 || !statOk then 0
    else statBytes apparent logical blocks
  else
    size?.getD 0

/-- Pre-fix reading: the raw bulk field, or 0 when the field was absent. No rounding. -/
def legacyBulk (size? : Option Nat) : Nat :=
  size?.getD 0

theorem entrySize_eq_stat
    {apparent : Bool} {size? : Option Nat} {statOk : Bool}
    {nameLen logical blocks : Nat}
    (hname : nameLen < 1024) (hok : statOk = true)
    (hsize : apparent = true ∨ size? = none ∨ size? = some (physical blocks)) :
    entrySize apparent size? statOk nameLen logical blocks =
      statBytes apparent logical blocks := by
  have hge : ¬ nameLen ≥ 1024 := by omega
  cases apparent with
  | true =>
    cases size? with
    | none =>
      simp [entrySize, statBytes, hok, hge]
    | some _ =>
      simp [entrySize, statBytes, hok, hge]
  | false =>
    cases size? with
    | none =>
      simp [entrySize, statBytes, hok, hge, physical]
    | some v =>
      rcases hsize with h | h | h
      · cases h
      · cases h
      · simp [entrySize, statBytes, h, physical]

theorem entrySize_apparent_ignores_bulk (v logical blocks : Nat) :
    entrySize true (some v) true 1 logical blocks = round512 logical := by
  simp [entrySize, statBytes]

theorem entrySize_physical_trusts_bulk (v logical blocks : Nat) :
    entrySize false (some v) true 1 logical blocks = v := by
  simp [entrySize]

theorem entrySize_omitted_uses_stat (logical blocks : Nat) :
    entrySize false none true 1 logical blocks = physical blocks := by
  simp [entrySize, statBytes]

theorem entrySize_omitted_apparent (logical blocks : Nat) :
    entrySize true none true 1 logical blocks = round512 logical := by
  simp [entrySize, statBytes]

theorem entrySize_long_name (logical blocks : Nat) :
    entrySize false none true 1024 logical blocks = 0 := by
  simp [entrySize]

theorem entrySize_stat_fail (logical blocks : Nat) :
    entrySize false none false 1 logical blocks = 0 := by
  simp [entrySize]

theorem omitted_not_legacy {blocks : Nat} (h : blocks ≠ 0) :
    entrySize false none true 1 0 blocks ≠ legacyBulk none := by
  simp [entrySize, statBytes, legacyBulk, physical]
  omega

theorem apparent_not_raw_bulk :
    entrySize true (some 1000) true 1 1000 0 = 1024 ∧ legacyBulk (some 1000) = 1000 := by
  native_decide

end Dush
