namespace Dush

def howmany (x y : Nat) : Nat := (x + (y - 1)) / y

def roundUp512 (size : Nat) : Nat := (size + 511) / 512 * 512

def entryBytes (apparent : Bool) (size blocks : Nat) : Nat :=
  if apparent then roundUp512 size else blocks * 512

def duUnits (apparent : Bool) (size blocks : Nat) : Nat :=
  if apparent then howmany size 512 else blocks

def dushBlocks (bs bytes : Nat) : Nat := (bytes + bs - 1) / bs

def duBlocks (apparent : Bool) (bs units : Nat) : Nat :=
  if apparent then howmany (units * 512) bs else howmany units (bs / 512)

theorem roundUp512_dvd (n : Nat) : 512 ∣ roundUp512 n :=
  Nat.dvd_mul_left 512 _

theorem le_roundUp512 (n : Nat) : n ≤ roundUp512 n := by
  unfold roundUp512; omega

theorem roundUp512_least {n m : Nat} (hm : 512 ∣ m) (hn : n ≤ m) : roundUp512 n ≤ m := by
  unfold roundUp512; omega

theorem roundUp512_eq_howmany (n : Nat) : roundUp512 n = howmany n 512 * 512 := rfl

theorem entryBytes_eq_duUnits (apparent : Bool) (size blocks : Nat) :
    entryBytes apparent size blocks = 512 * duUnits apparent size blocks := by
  cases apparent <;> simp [entryBytes, duUnits, roundUp512, howmany] <;> omega

theorem dushBlocks_eq_howmany {bs : Nat} (h : 0 < bs) (bytes : Nat) :
    dushBlocks bs bytes = howmany bytes bs := by
  unfold dushBlocks howmany; congr 1; omega

theorem dushBlocks_eq_du_apparent {bs : Nat} (h : 0 < bs) (units : Nat) :
    dushBlocks bs (512 * units) = duBlocks true bs units := by
  rw [dushBlocks_eq_howmany h]; simp [duBlocks, Nat.mul_comm]

theorem dushBlocks_eq_du_physical {bs : Nat} (h0 : 0 < bs) (h : 512 ∣ bs) (units : Nat) :
    dushBlocks bs (512 * units) = duBlocks false bs units := by
  obtain ⟨k, rfl⟩ := h
  have hk : 0 < k := by omega
  simp only [dushBlocks, duBlocks, howmany, Bool.false_eq_true, ite_false]
  rw [Nat.mul_div_cancel_left k (by decide : 0 < 512), ← Nat.div_div_eq_div_mul]
  congr 1; omega

def flagBlockSize : Char → Option Nat
  | 'k' => some 1024
  | 'm' => some 1048576
  | 'g' => some 1073741824
  | _ => none

theorem flagBlockSize_dvd {c : Char} {bs : Nat} (h : flagBlockSize c = some bs) :
    0 < bs ∧ 512 ∣ bs := by
  unfold flagBlockSize at h
  split at h <;> simp at h <;> subst h <;> decide

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

inductive BlockSizeEnv where
  | unset
  | negative
  | malformed
  | num (n : Nat) (u : BSUnit)
  deriving DecidableEq, Repr

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

theorem getbsize_suffix_dvd (n : Nat) (u : BSUnit) (hu : u ≠ .none) :
    512 ∣ getbsize (.num n u) := by
  cases u <;> simp only [getbsize] at * <;> (try contradiction) <;> split <;> split <;> split <;> omega

structure Scale where
  apparent : Bool
  cblocksize : Nat
  blocksize : Nat
deriving DecidableEq, Repr

def Scale.init (apparent : Bool) (rawCb rawBs : Nat) : Scale :=
  let cb := if !apparent && rawCb % 512 != 0 then howmany rawCb 512 * 512 else rawCb
  if apparent then ⟨apparent, cb, rawBs⟩ else ⟨apparent, cb / 512, rawBs / 512⟩

def Scale.entryBlocks (sc : Scale) (size blocks : Nat) : Nat :=
  howmany (if sc.apparent then size else blocks) sc.cblocksize

def Scale.display (sc : Scale) (n : Nat) : Nat := howmany (n * sc.cblocksize) sc.blocksize

def Scale.humanBytes (sc : Scale) (n : Nat) : Nat :=
  if sc.apparent then n * sc.cblocksize else n * sc.cblocksize * 512

theorem scale_default_entry (apparent : Bool) (bs size blocks : Nat) :
    (Scale.init apparent 512 bs).entryBlocks size blocks = duUnits apparent size blocks := by
  cases apparent <;> simp [Scale.init, Scale.entryBlocks, duUnits, howmany]

theorem scale_default_display (apparent : Bool) (bs n : Nat) :
    (Scale.init apparent 512 bs).display n = duBlocks apparent bs n := by
  cases apparent <;> simp [Scale.init, Scale.display, duBlocks]

theorem scale_default_human (apparent : Bool) (bs n : Nat) :
    (Scale.init apparent 512 bs).humanBytes n = 512 * n := by
  cases apparent <;> simp [Scale.init, Scale.humanBytes, Nat.mul_comm]

theorem scale_default_bytes (apparent : Bool) (bs size blocks : Nat) :
    512 * (Scale.init apparent 512 bs).entryBlocks size blocks = entryBytes apparent size blocks := by
  rw [scale_default_entry, entryBytes_eq_duUnits]

theorem scale_physical_cb (rawCb bs : Nat) :
    (Scale.init false rawCb bs).cblocksize = howmany rawCb 512 := by
  unfold Scale.init howmany
  by_cases h : rawCb % 512 = 0 <;> simp [h] <;> omega

theorem blocksize_1000_quirk :
    duBlocks false (getbsize (.num 1000 .none)) 16 = 16 ∧
    (Scale.init false 512 (getbsize (.num 1000 .none))).display 16 = 16 ∧
    dushBlocks (getbsize (.num 1000 .none)) (512 * 16) = 9 := by decide

theorem blocksize_1000_apparent :
    duBlocks true (getbsize (.num 1000 .none)) (duUnits true 5000 16) = 6 := by decide

end Dush
