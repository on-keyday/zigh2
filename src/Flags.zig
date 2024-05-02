value :u8,
pub const NONE = 0x0;
pub const ACK = 0x1;
pub const END_STREAM = 0x1;
pub const PADDED = 0x8;
pub const END_HEADERS = 0x4;
pub const PRIORITY = 0x20;
const Self = @This();

pub fn is_none(f:Self)  bool {
    return f.value == NONE;
}

pub fn is_ack(f:Self)  bool {
    return f.value & ACK != 0;
}

pub fn is_end_stream(f:Self)  bool {
    return f.value & END_STREAM != 0;
}

pub fn is_padded(f:Self)  bool {
    return f.value & PADDED != 0;
}

pub fn is_end_headers(f:Self)  bool {
    return f.value & END_HEADERS != 0;
}

pub fn is_priority(f:Self)  bool {
    return f.value & PRIORITY != 0;
}

pub fn set_none(f:*Self)  void {
    f.value = NONE;
    return f;
}

pub fn set_ack(f:*Self) void {
    f.value |= ACK;
}

pub fn set_end_stream(f:*Self)  void {
    f.value |= END_STREAM;
}

pub fn set_padded(f:*Self)  void {
    f.value |= PADDED;
}

pub fn set_end_headers(f:*Self)  void {
    f.value |= END_HEADERS;
}

pub fn set_priority(f:*Self)  void {
    f.value |= PRIORITY;
}

pub fn init()  Self {
    return Self { .value = NONE };
}
pub fn initValue(value:u8)  Self {
    return Self { .value = value };
}

const std = @import("std");

pub fn format(self :Self, comptime f :[]const u8, _ :std.fmt.FormatOptions, w :anytype) !void {
    var need_partiacal_bar = false;
    if(f.len >= 1 and f[0] == 'a') {
        if(self.is_ack()) {
            try w.writeAll("ACK");
            need_partiacal_bar = true;
        }
    } else {
        if(self.is_end_stream()) {
            try w.writeAll("END_STREAM");
            need_partiacal_bar = true;
        }
    }
    if(self.is_padded()) {
        if(need_partiacal_bar) {
            try w.writeAll("|");
        }
        try w.writeAll("PADDED");
        need_partiacal_bar = true;
    }
    if(self.is_end_headers()) {
        if(need_partiacal_bar) {
            try w.writeAll("|");
        }
        try w.writeAll("END_HEADERS");
        need_partiacal_bar = true;
    }
    if(self.is_priority()) {
        if(need_partiacal_bar) {
            try w.writeAll("|");
        }
        try w.writeAll("PRIORITY");
        need_partiacal_bar = true;
    }
    if(!need_partiacal_bar) {
        try w.writeAll("NONE");
    }
}