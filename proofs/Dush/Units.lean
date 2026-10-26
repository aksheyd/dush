/-!
# Per-entry rounding and unit conversion

Spec source: Apple `file_cmds/du/du.c` and FreeBSD `lib/libc/gen/getbsize.c`.

* `du` accumulates 512-byte units (`DEV_BSIZE`). Physical: `st_blocks`.
  Apparent (`-A`): `howmany(st_size, 512)`.
* `dush` accumulates bytes: `st_blocks * 512`, or `roundUp512 st_size` with `-A`.
* `du` prints a non-human total `U` as `howmany(U * cblocksize, blocksize)` where,
  without `-A`, both `cblocksize` and `blocksize` were first integer-divided by 512.
* `dush` prints `printResult`'s `(bytes + bs - 1) / bs`.
-/

namespace Dush

/-- `howmany(x, y)` from `<sys/param.h>`. -/
def howmany (x y : Nat) : Nat := (x + (y - 1)) / y

/-- `dush`'s `roundUp512`. -/
def roundUp512 (size : Nat) : Nat := (size + 511) / 512 * 512

/-- `dush`'s per-entry byte charge. -/
def entryBytes (apparent : Bool) (size blocks : Nat) : Nat :=
  if apparent then roundUp512 size else blocks * 512

/-- `du`'s per-entry charge in 512-byte units (`curblocks` with the default `-B`). -/
def duUnits (apparent : Bool) (size blocks : Nat) : Nat :=
  if apparent then howmany size 512 else blocks

/-- `dush`'s `printResult` for `block_size > 0`. -/
def dushBlocks (bs bytes : Nat) : Nat := (bytes + bs - 1) / bs

/-- `du`'s non-human output of a total of `units` 512-byte units, default `-B`. -/
def duBlocks (apparent : Bool) (bs units : Nat) : Nat :=
  if apparent then howmany (units * 512) bs else howmany units (bs / 512)

theorem roundUp512_dvd (n : Nat) : 512 ∣ roundUp512 n :=
  Nat.dvd_mul_left 512 _

theorem le_roundUp512 (n : Nat) : n ≤ roundUp512 n := by
  unfold roundUp512; omega

/-- `roundUp512 n` is the least multiple of 512 that is at least `n` (ceil to 512). -/
theorem roundUp512_least {n m : Nat} (hm : 512 ∣ m) (hn : n ≤ m) : roundUp512 n ≤ m := by
  unfold roundUp512; omega

theorem roundUp512_eq_howmany (n : Nat) : roundUp512 n = howmany n 512 * 512 := rfl

/-- Every `dush` byte charge is exactly 512 times `du`'s unit charge. -/
theorem entryBytes_eq_duUnits (apparent : Bool) (size blocks : Nat) :
    entryBytes apparent size blocks = 512 * duUnits apparent size blocks := by
  cases apparent <;> simp [entryBytes, duUnits, roundUp512, howmany] <;> omega

theorem dushBlocks_eq_howmany {bs : Nat} (h : 0 < bs) (bytes : Nat) :
    dushBlocks bs bytes = howmany bytes bs := by
  unfold dushBlocks howmany; congr 1; omega

/-- With `-A`, `dush`'s conversion agrees with `du` for every block size. -/
theorem dushBlocks_eq_du_apparent {bs : Nat} (h : 0 < bs) (units : Nat) :
    dushBlocks bs (512 * units) = duBlocks true bs units := by
  rw [dushBlocks_eq_howmany h]; simp [duBlocks, Nat.mul_comm]

/-- Without `-A`, they agree whenever the block size is a multiple of 512. -/
theorem dushBlocks_eq_du_physical {bs : Nat} (h0 : 0 < bs) (h : 512 ∣ bs) (units : Nat) :
    dushBlocks bs (512 * units) = duBlocks false bs units := by
  obtain ⟨k, rfl⟩ := h
  have hk : 0 < k := by omega
  simp only [dushBlocks, duBlocks, howmany, Bool.false_eq_true, ite_false]
  rw [Nat.mul_div_cancel_left k (by decide : 0 < 512), ← Nat.div_div_eq_div_mul]
  congr 1; omega

/-- The `-k`, `-m` and `-g` block sizes. -/
def flagBlockSize : Char → Option Nat
  | 'k' => some 1024
  | 'm' => some 1048576
  | 'g' => some 1073741824
  | _ => none

theorem flagBlockSize_dvd {c : Char} {bs : Nat} (h : flagBlockSize c = some bs) :
    0 < bs ∧ 512 ∣ bs := by
  unfold flagBlockSize at h
  split at h <;> simp at h <;> subst h <;> decide

/-- `dush` with `-k`, `-m` or `-g` prints the same number as `du`, with or without `-A`. -/
theorem flag_blocks_agree {c : Char} {bs : Nat} (h : flagBlockSize c = some bs)
    (apparent : Bool) (units : Nat) :
    dushBlocks bs (512 * units) = duBlocks apparent bs units := by
  obtain ⟨h0, hd⟩ := flagBlockSize_dvd h
  cases apparent
  · exact dushBlocks_eq_du_physical h0 hd units
  · exact dushBlocks_eq_du_apparent h0 units

inductive BSUnit where
  | none | K | M | G
  deriving DecidableEq, Repr

/-- `BLOCKSIZE` after `strtol`: unset or empty, negative, malformed suffix, or `n` with a unit. -/
inductive BlockSizeEnv where
  | unset
  | negative
  | malformed
  | num (n : Nat) (u : BSUnit)
  deriving DecidableEq, Repr

/-- `getbsize(3)`'s returned block size. -/
def getbsize : BlockSizeEnv → Nat
  | .unset => 512
  | .negative => 512
  | .malformed => 512
  | .num n u =>
    let n := if n = 0 then 1 else n
    let (mx, mul) : Nat × Nat := match u with
      | .none => (1073741824, 1)
      | .K => (1048576, 1024)
      | .M => (1024, 1048576)
      | .G => (1, 1073741824)
    let n := if n > mx then mx else n
    if n * mul < 512 then 512 else n * mul

theorem getbsize_bounds (e : BlockSizeEnv) : 512 ≤ getbsize e ∧ getbsize e ≤ 1073741824 := by
  cases e with
  | num n u => cases u <;> simp only [getbsize] <;> split <;> split <;> split <;> omega
  | _ => simp [getbsize]

/-- A `K`, `M` or `G` suffix always yields a multiple of 512, so `dush` would agree with `du`. -/
theorem getbsize_suffix_dvd (n : Nat) (u : BSUnit) (hu : u ≠ .none) :
    512 ∣ getbsize (.num n u) := by
  cases u <;> simp only [getbsize] at * <;> (try contradiction) <;> split <;> split <;> split <;> omega

/-- `BLOCKSIZE=1000 du -s` on a 16-block file prints 16 (blocksize truncates to 1 unit),
not `ceil(8192 / 1000) = 9`. Verified on macOS. `dush` does not read `BLOCKSIZE`. -/
theorem blocksize_1000_quirk :
    duBlocks false (getbsize (.num 1000 .none)) 16 = 16 ∧
    dushBlocks (getbsize (.num 1000 .none)) (512 * 16) = 9 := by decide

/-- `BLOCKSIZE=1000 du -A -s` on a 5000-byte file prints 6 = `ceil(10 * 512 / 1000)`. -/
theorem blocksize_1000_apparent :
    duBlocks true (getbsize (.num 1000 .none)) (duUnits true 5000 16) = 6 := by decide

end Dush
