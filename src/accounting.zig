const std = @import("std");

pub const sector: i64 = 512;

pub fn roundUp512(size: i64) i64 {
    return @divTrunc(size + sector - 1, sector) * sector;
}

pub fn statBytes(size: i64, blocks: i64, apparent: bool) i64 {
    if (apparent) return roundUp512(size);
    return blocks * sector;
}

pub fn toBlocks(bytes: i64, block_size: i64) i64 {
    return @divTrunc(bytes + block_size - 1, block_size);
}

pub fn howmany(x: i64, y: i64) i64 {
    return @divTrunc(x + (y - 1), y);
}

pub const Scale = struct {
    apparent: bool,
    cblocksize: i64,
    blocksize: i64,

    pub fn init(apparent: bool, raw_cblocksize: i64, raw_blocksize: i64) Scale {
        var cb = raw_cblocksize;
        var bs = raw_blocksize;
        if (!apparent and @rem(cb, sector) != 0) cb = howmany(cb, sector) * sector;
        if (!apparent) {
            cb = @divTrunc(cb, sector);
            bs = @divTrunc(bs, sector);
        }
        return .{ .apparent = apparent, .cblocksize = cb, .blocksize = bs };
    }

    pub fn entryBlocks(self: Scale, size: i64, blocks: i64) i64 {
        return howmany(if (self.apparent) size else blocks, self.cblocksize);
    }

    pub fn display(self: Scale, n: i64) i64 {
        return howmany(n * self.cblocksize, self.blocksize);
    }

    pub fn humanBytes(self: Scale, n: i64) i64 {
        const b = n * self.cblocksize;
        return if (self.apparent) b else b * sector;
    }

    pub fn threshold(self: Scale, raw: u64) u64 {
        if (raw == 0) return 0;
        const cb: u64 = @bitCast(@as(i64, self.cblocksize));
        const bs: u64 = @bitCast(@as(i64, self.blocksize));
        const m = raw / 512 *% cb;
        return m / bs + @intFromBool(m % bs != 0);
    }

    pub fn passes(self: Scale, adjusted_threshold: u64, n: i64) bool {
        const shown: u64 = @bitCast(self.display(n));
        return adjusted_threshold <= shown;
    }

    pub fn fastPathCompatible(self: Scale) bool {
        return if (self.apparent) self.cblocksize == sector else self.cblocksize == 1;
    }
};
