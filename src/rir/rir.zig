pub const RIROP = union(enum) {
    call: struct { identifier: []const u8, args: *[]RIROP },
};
