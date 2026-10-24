/-
Model of `dush`'s size walk.

`spec` is the `du -sh` accounting the Zig tests claim: physical bytes are
`st_blocks * 512`, apparent bytes are `round512 st_size`, `-P` never follows,
`-H` follows only the command-line path, `-L` follows every symlink, and a
file or directory with link count greater than 1 is charged once.

`bulk` is `workerFn`'s `getattrlistbulk` path, including `allocatedSizeAt`.
`posix` is `scanDirPosixFallback`. `scan` is `scanTarget`: the root is always
stat'd, then children are walked. Directory listings do not contain `.` or `..`.
-/

import Dush.Size

namespace Dush

inductive Mode where
  | bulk
  | spec
  | posix
  deriving DecidableEq, Repr, BEq

inductive Follow where
  | P
  | H
  | L
  deriving DecidableEq, Repr, BEq

def VREG : Nat := 1
def VDIR : Nat := 2
def VCHR : Nat := 4
/-- Darwin `vtype`: `VNON=0, VREG=1, VDIR=2, VBLK=3, VCHR=4, VLNK=5`. -/
def VLNK : Nat := 5

structure Inode where
  dev : Nat
  ino : Nat
  deriving DecidableEq, Repr, BEq

structure Stat where
  dev : Nat
  ino : Nat
  nlink : Nat
  logical : Nat
  blocks : Nat
  deriving DecidableEq, Repr

structure Bulk where
  vtype : Nat
  fileId : Nat
  linkCount? : Option Nat
  size? : Option Nat
  nameLen : Nat
  lstatOk : Bool
  deriving DecidableEq, Repr

inductive Tree where
  | file (st : Stat) (bulk : Bulk)
  | dir (st : Stat) (bulk : Bulk) (kids : List Tree)
  | link (own : Stat) (bulk : Bulk) (ok : Bool) (target : Tree)
  deriving Repr

def InodeSet := List Inode

/-- `InodeSet.seen`. Inode 0 is never recorded, so dedup does not fire. -/
def remember (ignoreZero : Bool) (s : InodeSet) (i : Inode) : InodeSet × Bool :=
  if ignoreZero && i.ino == 0 then
    (s, false)
  else if s.elem i then
    (s, true)
  else
    (i :: s, false)

def chargeHardlink (ignoreZero : Bool) (s : InodeSet) (key : Inode) (nlink size : Nat) :
    InodeSet × Nat :=
  if nlink > 1 then
    let (s, seen) := remember ignoreZero s key
    if seen then (s, 0) else (s, size)
  else
    (s, size)

def shouldRecord (always : Bool) (nlink : Nat) : Bool :=
  always || decide (nlink > 1)

/-- Directory charge. `descend` is false when this inode was already counted. -/
def chargeDir (ignoreZero always : Bool) (dirs : InodeSet) (key : Inode) (nlink size : Nat) :
    InodeSet × Nat × Bool :=
  if shouldRecord always nlink then
    let (dirs, seen) := remember ignoreZero dirs key
    if seen then (dirs, 0, false) else (dirs, size, true)
  else
    (dirs, size, true)

def ignoreZero (mode : Mode) : Bool :=
  mode != .spec

def nodeBytes (mode : Mode) (apparent : Bool) (st : Stat) (bulk : Bulk) : Nat :=
  match mode with
  | .bulk => entrySize apparent bulk.size? bulk.lstatOk bulk.nameLen st.logical st.blocks
  | .spec | .posix =>
    if bulk.lstatOk then statBytes apparent st.logical st.blocks else 0

def fileKey (mode : Mode) (parentDev : Nat) (st : Stat) (bulk : Bulk) : Inode :=
  match mode with
  | .bulk => ⟨parentDev, bulk.fileId⟩
  | .spec | .posix => ⟨st.dev, st.ino⟩

def fileNlink (mode : Mode) (st : Stat) (bulk : Bulk) : Nat :=
  match mode with
  | .bulk => bulk.linkCount?.getD 1
  | .spec | .posix => st.nlink

def chargeListed (mode : Mode) (apparent : Bool) (parentDev : Nat) (files : InodeSet)
    (st : Stat) (bulk : Bulk) : InodeSet × Nat :=
  chargeHardlink (ignoreZero mode) files (fileKey mode parentDev st bulk)
    (fileNlink mode st bulk) (nodeBytes mode apparent st bulk)

/--
POSIX records every directory inode.
The bulk walker records it when the reported link count is greater than 1.
`du`'s `dirlinkchk` records it when the link count is not 1.
-/
def dirRecords (mode : Mode) (nlink : Nat) : Bool :=
  match mode with
  | .posix => true
  | .bulk => decide (nlink > 1)
  | .spec => decide (nlink ≠ 1)

def chargeListedDir (mode : Mode) (apparent : Bool) (parentDev : Nat) (dirs : InodeSet)
    (st : Stat) (bulk : Bulk) : InodeSet × Nat × Bool :=
  chargeDir (ignoreZero mode) (dirRecords mode (fileNlink mode st bulk)) dirs
    (fileKey mode parentDev st bulk) (fileNlink mode st bulk) (nodeBytes mode apparent st bulk)

def chargeRootFile (mode : Mode) (apparent : Bool) (files : InodeSet) (st : Stat) :
    InodeSet × Nat :=
  chargeHardlink (ignoreZero mode) files ⟨st.dev, st.ino⟩ st.nlink
    (statBytes apparent st.logical st.blocks)

/-- `-L` file: `fstatat` without `AT_SYMLINK_NOFOLLOW`, then the file hardlink rule. -/
def chargeFollowedFile (mode : Mode) (apparent : Bool) (files : InodeSet) (st : Stat) :
    InodeSet × Nat :=
  chargeHardlink (ignoreZero mode) files ⟨st.dev, st.ino⟩ st.nlink
    (statBytes apparent st.logical st.blocks)

/-- Whether a directory reached by following a symlink is recorded. -/
def followRecords (mode : Mode) (nlink : Nat) : Bool :=
  match mode with
  | .bulk | .posix => true
  | .spec => decide (nlink ≠ 1)

/--
`-L` directory. The bulk walker and the POSIX fallback always call `dirs.seen` here.
`du`'s `dirlinkchk` records the inode only when the link count is not 1.
-/
def chargeFollowedDir (mode : Mode) (apparent : Bool) (dirs : InodeSet) (st : Stat) :
    InodeSet × Nat × Bool :=
  chargeDir (ignoreZero mode) (followRecords mode st.nlink) dirs ⟨st.dev, st.ino⟩ st.nlink
    (statBytes apparent st.logical st.blocks)

def seedDirs (mode : Mode) (st : Stat) : InodeSet :=
  (remember (ignoreZero mode) [] ⟨st.dev, st.ino⟩).1

mutual
def treeSize : Tree → Nat
  | .file _ _ => 1
  | .dir _ _ kids => 1 + listSize kids
  | .link _ _ _ t => 1 + treeSize t

def listSize : List Tree → Nat
  | [] => 0
  | t :: ts => treeSize t + listSize ts
end

def walkList (mode : Mode) (apparent followAll : Bool) (parentDev : Nat)
    (files dirs : InodeSet) : List Tree → InodeSet × InodeSet × Nat
  | [] => (files, dirs, 0)
  | .file st bulk :: ts =>
    let (files, added) := chargeListed mode apparent parentDev files st bulk
    let (files, dirs, rest) := walkList mode apparent followAll parentDev files dirs ts
    (files, dirs, added + rest)
  | .dir st bulk kids :: ts =>
    -- Bulk descent keys off the vnode type. `du` and the POSIX fallback key off `st_mode`.
    let asDir := match mode with
      | .bulk => bulk.vtype == VDIR
      | .spec | .posix => true
    if asDir then
      let (dirs, added, go) := chargeListedDir mode apparent parentDev dirs st bulk
      let (files, dirs, sub) :=
        if go then walkList mode apparent followAll parentDev files dirs kids
        else (files, dirs, 0)
      let (files, dirs, rest) := walkList mode apparent followAll parentDev files dirs ts
      (files, dirs, added + sub + rest)
    else
      let (files, added) := chargeListed mode apparent parentDev files st bulk
      let (files, dirs, rest) := walkList mode apparent followAll parentDev files dirs ts
      (files, dirs, added + rest)
  | .link own bulk ok tgt :: ts =>
    -- Bulk follows only `vtype == VLNK` (5). A failed follow or a too-long name adds 0.
    let symlink := match mode with
      | .bulk => bulk.vtype == VLNK
      | .spec | .posix => true
    let statOk := match mode with
      | .bulk => ok && decide (bulk.nameLen < 1024)
      | .spec | .posix => ok
    if followAll && symlink && statOk then
      match tgt with
      | .file tst _ =>
        let (files, added) := chargeFollowedFile mode apparent files tst
        let (files, dirs, rest) := walkList mode apparent followAll parentDev files dirs ts
        (files, dirs, added + rest)
      | .dir tst _ tkids =>
        let (dirs, added, go) := chargeFollowedDir mode apparent dirs tst
        let (files, dirs, sub) :=
          if go then walkList mode apparent followAll tst.dev files dirs tkids
          else (files, dirs, 0)
        let (files, dirs, rest) := walkList mode apparent followAll parentDev files dirs ts
        (files, dirs, added + sub + rest)
      | .link _ _ _ _ =>
        let (files, dirs, rest) := walkList mode apparent followAll parentDev files dirs ts
        (files, dirs, rest)
    else if followAll && symlink then
      let (files, dirs, rest) := walkList mode apparent followAll parentDev files dirs ts
      (files, dirs, rest)
    else
      let (files, added) := chargeListed mode apparent parentDev files own bulk
      let (files, dirs, rest) := walkList mode apparent followAll parentDev files dirs ts
      (files, dirs, added + rest)

/-- `scanTarget`. A command-line symlink is followed for `-H` and `-L`, never for `-P`. -/
def scan (mode : Mode) (apparent : Bool) (follow : Follow) (files : InodeSet) :
    Tree → InodeSet × Nat
  | .link own _ ok tgt =>
    if follow == .P then
      chargeRootFile mode apparent files own
    else if ok then
      scan mode apparent follow files tgt
    else
      (files, 0)
  | .file st _ =>
    chargeRootFile mode apparent files st
  | .dir st _ kids =>
    let dirs := seedDirs mode st
    let (files, _, sub) :=
      walkList mode apparent (follow == .L) st.dev files dirs kids
    (files, statBytes apparent st.logical st.blocks + sub)

def total (mode : Mode) (apparent : Bool) (follow : Follow) (t : Tree) : Nat :=
  (scan mode apparent follow [] t).2

def S (dev ino nlink logical blocks : Nat) : Stat :=
  {dev, ino, nlink, logical, blocks}

def Bk (vtype fileId nlink : Nat) (size? : Option Nat) (nameLen : Nat := 4) : Bulk :=
  {vtype, fileId, linkCount? := some nlink, size?, nameLen, lstatOk := true}

inductive Terminal : Tree → Prop where
  | file (st : Stat) (bulk : Bulk) : Terminal (.file st bulk)
  | dir (st : Stat) (bulk : Bulk) (kids : List Tree) : Terminal (.dir st bulk kids)

mutual
def SingleDev (d : Nat) : Tree → Prop
  | .file st _ => st.dev = d
  | .dir st _ kids => st.dev = d ∧ SingleDevList d kids
  | .link own _ _ tgt => own.dev = d ∧ SingleDev d tgt

def SingleDevList (d : Nat) : List Tree → Prop
  | [] => True
  | t :: ts => SingleDev d t ∧ SingleDevList d ts
end

mutual
inductive Faithful : Bool → Tree → Prop where
  | file {apparent : Bool} {st : Stat} {bulk : Bulk} :
      bulk.vtype ≠ VDIR →
      bulk.vtype ≠ VLNK →
      bulk.fileId = st.ino →
      bulk.linkCount? = some st.nlink →
      bulk.nameLen < 1024 →
      bulk.lstatOk = true →
      st.ino ≠ 0 →
      (apparent = true ∨ bulk.size? = none ∨ bulk.size? = some (physical st.blocks)) →
      Faithful apparent (.file st bulk)
  | dir {apparent : Bool} {st : Stat} {bulk : Bulk} {kids : List Tree} :
      bulk.vtype = VDIR →
      bulk.fileId = st.ino →
      bulk.linkCount? = some st.nlink →
      st.nlink > 1 →
      bulk.nameLen < 1024 →
      bulk.lstatOk = true →
      st.ino ≠ 0 →
      (apparent = true ∨ bulk.size? = none ∨ bulk.size? = some (physical st.blocks)) →
      FaithfulList apparent kids →
      Faithful apparent (.dir st bulk kids)
  | link {apparent : Bool} {own : Stat} {bulk : Bulk} {ok : Bool} {tgt : Tree} :
      bulk.vtype = VLNK →
      bulk.fileId = own.ino →
      bulk.linkCount? = some own.nlink →
      bulk.nameLen < 1024 →
      bulk.lstatOk = true →
      own.ino ≠ 0 →
      (apparent = true ∨ bulk.size? = none ∨ bulk.size? = some (physical own.blocks)) →
      ok = true →
      Terminal tgt →
      Faithful apparent tgt →
      Faithful apparent (.link own bulk ok tgt)

inductive FaithfulList : Bool → List Tree → Prop where
  | nil {apparent : Bool} : FaithfulList apparent []
  | cons {apparent : Bool} {t : Tree} {ts : List Tree} :
      Faithful apparent t → FaithfulList apparent ts → FaithfulList apparent (t :: ts)
end

theorem remember_eq_of_nonzero {i : Inode} (h : i.ino ≠ 0) (ignore : Bool) (s : InodeSet) :
    remember ignore s i = remember false s i := by
  cases ignore <;> simp [remember, h]

theorem chargeHardlink_ignore {key : Inode} (h : key.ino ≠ 0) (files : InodeSet)
    (nlink size : Nat) :
    chargeHardlink true files key nlink size = chargeHardlink false files key nlink size := by
  simp [chargeHardlink, remember_eq_of_nonzero h]

theorem shouldRecord_when_linked {nlink : Nat} (hn : nlink > 1) :
    shouldRecord false nlink = true := by
  simp [shouldRecord, hn]

theorem shouldRecord_always (nlink : Nat) : shouldRecord true nlink = true := by
  simp [shouldRecord]

theorem chargeDir_ignore {key : Inode} (h : key.ino ≠ 0) (dirs : InodeSet) (nlink size : Nat) :
    chargeDir true false dirs key nlink size = chargeDir false false dirs key nlink size := by
  simp [chargeDir, shouldRecord, remember_eq_of_nonzero h]

theorem chargeDir_follow_agrees {key : Inode} (h : key.ino ≠ 0) (hn : nlink > 1)
    (dirs : InodeSet) (size : Nat) :
    chargeDir true true dirs key nlink size = chargeDir false false dirs key nlink size := by
  simp [chargeDir, shouldRecord, hn, remember_eq_of_nonzero h]

theorem chargeDir_ignore_always {key : Inode} (h : key.ino ≠ 0) (dirs : InodeSet)
    (nlink size : Nat) :
    chargeDir true true dirs key nlink size = chargeDir false true dirs key nlink size := by
  simp [chargeDir, shouldRecord, remember_eq_of_nonzero h]

theorem dirRecords_gt_one {nlink : Nat} (hn : nlink > 1) :
    dirRecords .bulk nlink = true ∧ dirRecords .spec nlink = true := by
  have hne : nlink ≠ 1 := by omega
  simp [dirRecords, hn, hne]

theorem followRecords_gt_one {nlink : Nat} (hn : nlink > 1) :
    followRecords .bulk nlink = true ∧ followRecords .spec nlink = true := by
  have hne : nlink ≠ 1 := by omega
  simp [followRecords, hne]

theorem nodeBytes_bulk_spec {apparent : Bool} {st : Stat} {bulk : Bulk}
    (hname : bulk.nameLen < 1024) (hok : bulk.lstatOk = true)
    (hsize : apparent = true ∨ bulk.size? = none ∨ bulk.size? = some (physical st.blocks)) :
    nodeBytes .bulk apparent st bulk = nodeBytes .spec apparent st bulk := by
  simp [nodeBytes, hok]
  exact entrySize_eq_stat hname rfl hsize

theorem nodeBytes_posix_spec {apparent : Bool} {st : Stat} {bulk : Bulk}
    (hok : bulk.lstatOk = true) :
    nodeBytes .posix apparent st bulk = nodeBytes .spec apparent st bulk := by
  simp [nodeBytes, hok]

theorem fileKey_bulk_spec {parentDev : Nat} {st : Stat} {bulk : Bulk}
    (hdev : st.dev = parentDev) (hid : bulk.fileId = st.ino) :
    fileKey .bulk parentDev st bulk = fileKey .spec parentDev st bulk := by
  simp [fileKey, hdev, hid]

theorem fileKey_posix_spec {parentDev : Nat} {st : Stat} {bulk : Bulk} :
    fileKey .posix parentDev st bulk = fileKey .spec parentDev st bulk := by
  simp [fileKey]

theorem fileNlink_bulk_spec {st : Stat} {bulk : Bulk}
    (h : bulk.linkCount? = some st.nlink) :
    fileNlink .bulk st bulk = fileNlink .spec st bulk := by
  simp [fileNlink, h]

theorem fileNlink_posix_spec {st : Stat} {bulk : Bulk} :
    fileNlink .posix st bulk = fileNlink .spec st bulk := by
  simp [fileNlink]

theorem chargeListed_bulk_spec
    (apparent : Bool) (parentDev : Nat) (files : InodeSet) (st : Stat) (bulk : Bulk)
    (hdev : st.dev = parentDev) (hid : bulk.fileId = st.ino)
    (hlink : bulk.linkCount? = some st.nlink)
    (hname : bulk.nameLen < 1024) (hok : bulk.lstatOk = true)
    (hino : st.ino ≠ 0)
    (hsize : apparent = true ∨ bulk.size? = none ∨ bulk.size? = some (physical st.blocks)) :
    chargeListed .bulk apparent parentDev files st bulk =
      chargeListed .spec apparent parentDev files st bulk := by
  simp [chargeListed, ignoreZero, fileKey_bulk_spec hdev hid, fileNlink_bulk_spec hlink,
    nodeBytes_bulk_spec hname hok hsize]
  exact chargeHardlink_ignore (by simp [fileKey]; exact hino) files st.nlink
    (nodeBytes .spec apparent st bulk)

theorem chargeListedDir_bulk_spec
    (apparent : Bool) (parentDev : Nat) (dirs : InodeSet) (st : Stat) (bulk : Bulk)
    (hdev : st.dev = parentDev) (hid : bulk.fileId = st.ino)
    (hlink : bulk.linkCount? = some st.nlink)
    (hname : bulk.nameLen < 1024) (hok : bulk.lstatOk = true)
    (hino : st.ino ≠ 0) (hn : st.nlink > 1)
    (hsize : apparent = true ∨ bulk.size? = none ∨ bulk.size? = some (physical st.blocks)) :
    chargeListedDir .bulk apparent parentDev dirs st bulk =
      chargeListedDir .spec apparent parentDev dirs st bulk := by
  have hnl := fileNlink_bulk_spec hlink
  have hkey := fileKey_bulk_spec hdev hid
  have hby := nodeBytes_bulk_spec hname hok hsize
  have hrec := dirRecords_gt_one hn
  have hizB : ignoreZero .bulk = true := by decide
  have hizS : ignoreZero .spec = false := by decide
  unfold chargeListedDir
  rw [hnl, hkey, hby, hizB, hizS]
  simp only [fileNlink, fileKey]
  rw [hrec.1, hrec.2]
  exact chargeDir_ignore_always hino dirs st.nlink (nodeBytes .spec apparent st bulk)

theorem chargeFollowedFile_eq (mode : Mode) (apparent : Bool) (files : InodeSet) (st : Stat)
    (hino : st.ino ≠ 0) :
    chargeFollowedFile mode apparent files st = chargeFollowedFile .spec apparent files st := by
  cases mode with
  | spec => rfl
  | bulk =>
    simp only [chargeFollowedFile, ignoreZero]
    exact chargeHardlink_ignore hino files st.nlink (statBytes apparent st.logical st.blocks)
  | posix =>
    simp only [chargeFollowedFile, ignoreZero]
    exact chargeHardlink_ignore hino files st.nlink (statBytes apparent st.logical st.blocks)

theorem chargeFollowedDir_bulk_spec (apparent : Bool) (dirs : InodeSet) (st : Stat)
    (hino : st.ino ≠ 0) (hn : st.nlink > 1) :
    chargeFollowedDir .bulk apparent dirs st = chargeFollowedDir .spec apparent dirs st := by
  have hrec := followRecords_gt_one hn
  simp [chargeFollowedDir, ignoreZero, hrec]
  exact chargeDir_ignore_always hino dirs st.nlink (statBytes apparent st.logical st.blocks)

theorem chargeRootFile_eq (mode : Mode) (apparent : Bool) (files : InodeSet) (st : Stat)
    (hino : st.ino ≠ 0) :
    chargeRootFile mode apparent files st = chargeRootFile .spec apparent files st := by
  cases mode with
  | spec => rfl
  | bulk =>
    simp only [chargeRootFile, ignoreZero]
    exact chargeHardlink_ignore hino files st.nlink (statBytes apparent st.logical st.blocks)
  | posix =>
    simp only [chargeRootFile, ignoreZero]
    exact chargeHardlink_ignore hino files st.nlink (statBytes apparent st.logical st.blocks)

theorem seedDirs_eq (mode : Mode) (st : Stat) (hino : st.ino ≠ 0) :
    seedDirs mode st = seedDirs .spec st := by
  cases mode with
  | spec => rfl
  | bulk =>
    simp only [seedDirs, ignoreZero]
    exact congrArg Prod.fst (remember_eq_of_nonzero hino true [])
  | posix =>
    simp only [seedDirs, ignoreZero]
    exact congrArg Prod.fst (remember_eq_of_nonzero hino true [])

end Dush
