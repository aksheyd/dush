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
