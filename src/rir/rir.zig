pub const RIROP = union(enum) {
    add: struct {
        a: *RIROP,
        b: *RIROP,
    },
    divide: struct {
        a: *RIROP,
        b: *RIROP,
    },
    sqrt: struct {
        a: *RIROP,
    },

    call: struct {
        identifier: []const u8,
        args: *[]*RIROP,
    },

    random: struct {
        shape: *RIROP,
    },

    constant: union(enum) {
        int: i64,
        float: i64,
        string: []const u8,
        array_int: []const i64,
        array_float: []const f64,
    },
    ret: struct {
        op: *RIROP,
    },
};
