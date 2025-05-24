// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const Bootsector = @import("Header.zig").Bootsector;
const Filesystem = @import("Filesystem.zig");

const Self = @This();

/// Number of bytes in a logical sector. For performance reasons, this
/// should match the size of a physical sector of the target disk.
logical_sector_size: u16 = 512,

/// Size of the partition in logical sectors.
len_partition: usize,

/// Number of logical sectors that form a clusters
cluster_size: u8 = 4,

/// Number of logical sectors reserved for the
/// header and the extended boot code.
///
/// Must be above or equal to 1.
num_reserved_sectors: u16 = 1,

/// Maximum number of entries in the Root Directory Region; how many
/// folder entries have space at most considering the allocated space.
///
/// Must fill complete logical sectors. A value of zero is erroneous.
/// A folder entry is 32 bytes tall, thus, for a common sector size of
/// 512 bytes, this must be a multiple of 16:
/// (32 bytes per entry * 16 entries per sector = 512).
root_folder_capacity: u16 = 256,

/// Number of File Allocation Tables (FATs)
num_fats: u8 = 2,

/// Size of a single File Allocation Table (FAT) in logical sectors.
///
/// Must be above or equal to 1.
fat_size: u16 = 3,

/// Path to the file containing the content for the reserved sectors.
reserved_sector_content_path: []u8 = "",

allocator: std.mem.Allocator,

fn writeFat(
    self: Self,
    writer: std.io.AnyWriter,
) !void {
    var bytes: [512]u8 = .{0} ** (512);
    bytes[0] = 0xf8;
    bytes[1] = 0xff;
    bytes[2] = 0xff;
    _ = try writer.write(&bytes);

    var fat_sector_index: u32 = 1;
    while (fat_sector_index < self.fat_size) {
        const zeroes: [512]u8 = .{0} ** 512;
        _ = try writer.write(&zeroes);
        fat_sector_index += 1;
    }
}

pub fn write(
    self: Self,
    writer: std.io.AnyWriter,
) !void {
    const bootsector: Bootsector = .{
        .logical_sector_size = self.logical_sector_size,
        .cluster_size = self.cluster_size,
        .num_reserved_sectors = self.num_reserved_sectors,
        .root_folder_capacity = self.root_folder_capacity,
        .num_fats = self.num_fats,
        .fat_size = self.fat_size,
    };

    _ = try writer.write(&bootsector.serialize());

    if (self.num_reserved_sectors > 1) {
        const reserved_sectors_file = try std.fs.cwd().openFile(
            self.reserved_sector_content_path,
            .{},
        );
        defer reserved_sectors_file.close();

        const reserved_region_capacity = (self.num_reserved_sectors - 1) * self.logical_sector_size;
        var reserved_region: []u8 = try self.allocator.alloc(u8, reserved_region_capacity);
        const byte_count = try reserved_sectors_file.read(reserved_region);

        _ = try writer.write(reserved_region[0..byte_count]);
    }

    var fat_index: u8 = 0;
    while (fat_index < self.num_fats) {
        try self.writeFat(writer);
        fat_index += 1;
    }
}

fn fillFile(
    self: Self,
    file: std.fs.File,
) !void {
    const entry_offset: usize = @intCast(try file.getPos());

    const zeroed_sector = try self.allocator.alloc(
        u8,
        self.logical_sector_size,
    );
    defer self.allocator.free(zeroed_sector);
    @memset(zeroed_sector, 0);

    var logical_sector_index: usize = 0;
    while (logical_sector_index < self.len_partition) {
        _ = try file.write(zeroed_sector);
        logical_sector_index += 1;
    }
    try file.seekTo(entry_offset);
}

pub fn writeToFileAtOffset(
    self: Self,
    file: std.fs.File,
    start_byte: usize,
) !void {
    const entry_position = try file.getPos();
    try file.seekTo(start_byte);
    try self.fillFile(file);

    try self.write(
        file.writer().any(),
    );
    try file.seekTo(entry_position);
}

pub fn writeToFile(
    self: Self,
    file: std.fs.File,
) !void {
    try self.writeToFileAtOffset(file, 0);

    try self.write(
        file.writer().any(),
    );
}

pub fn writeToFileAtPathAtOffset(
    self: Self,
    path: []const u8,
    start_byte: usize,
) !void {
    var absolute_path = path;
    if (!std.fs.path.isAbsolute(path)) {
        const work_folder = try std.fs.cwd().realpathAlloc(
            self.allocator,
            ".",
        );
        defer self.allocator.free(work_folder);

        absolute_path = try std.fs.path.resolve(
            self.allocator,
            &[2][]const u8{ work_folder, path },
        );
    }
    defer self.allocator.free(absolute_path);
    var file = try std.fs.createFileAbsolute(
        absolute_path,
        .{ .read = true },
    );
    defer file.close();

    const start_position = try file.getPos();
    try file.seekTo(start_byte);

    try self.writeToFileAtOffset(
        file,
        start_byte,
    );
    try file.seekTo(start_position);
}

pub fn writeToFileAtPath(
    self: Self,
    path: []const u8,
) !void {
    try self.writeToFileAtPathAtOffset(path, 0);
}

pub fn init(
    num_sectors: usize,
    sector_size: usize,
    allocator: std.mem.Allocator,
) Self {
    return .{
        .logical_sector_size = @intCast(sector_size),
        .len_partition = num_sectors,
        .allocator = allocator,
    };
}

test "Write FAT12 Filesystem" {
    const constructor = init(
        2880,
        512,
        std.heap.smp_allocator,
    );
    try constructor.writeToFileAtPath("filesystem.img");
}
