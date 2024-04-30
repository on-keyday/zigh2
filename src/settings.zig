
pub const SETTINGS_HEADER_TABLE_SIZE = 0x1;
pub const SETTINGS_ENABLE_PUSH = 0x2;
pub const SETTINGS_MAX_CONCURRENT_STREAMS = 0x3;
pub const SETTINGS_INITIAL_WINDOW_SIZE = 0x4;
pub const SETTINGS_MAX_FRAME_SIZE = 0x5;
pub const SETTINGS_MAX_HEADER_LIST_SIZE = 0x6;

pub const Setting = struct {
    id :u16,
    value :u32,

    pub fn encode(self :Setting) [6]u8 {
        var buf = [_]u8{0, 0, 0, 0, 0, 0};
        buf[0] = @intCast((self.id >> 8) & 0xff);
        buf[1] = @intCast(self.id & 0xff);
        buf[2] = @intCast((self.value >> 24) & 0xff);
        buf[3] = @intCast((self.value >> 16) & 0xff);
        buf[4] = @intCast((self.value >> 8) & 0xff);
        buf[5] = @intCast(self.value & 0xff);
        return buf;
    }
};

pub fn encode(key :u16,value :u32) [6]u8 {
    const s= Setting{.id = key, .value = value};
    return s.encode();
}

const hpack = @import("hpack.zig");

pub const initialWindowSize = 65535;
pub const initialMaxFrameSize = 16384;
pub const DefinedSettings = struct {
    headerTableSize :u32 = hpack.DEFAULT_TABLE_SIZE,
    enablePush :bool = true,
    maxConcurrentStreams :?u32 = null, // default unlimited
    initialWindowSize :u32 = 65535,
    maxFrameSize :u24 = initialMaxFrameSize,

    omit_default :bool = true,
};

const std = @import("std");

pub fn getEncodedDefinedSettingsLen(definedSettings :DefinedSettings) u32 {
    var len :u32 = 0;
    if(definedSettings.headerTableSize != hpack.DEFAULT_TABLE_SIZE or !definedSettings.omit_default) {
        len += 6;
    }
    if(!definedSettings.enablePush or !definedSettings.omit_default) {
        len += 6;
    }
    if(definedSettings.maxConcurrentStreams ) |_| {
        len += 6;
    }
    if(definedSettings.initialWindowSize != initialWindowSize or !definedSettings.omit_default) {
        len += 6;
    }
    if(definedSettings.maxFrameSize != initialMaxFrameSize or !definedSettings.omit_default) {
        len += 6;
    }
    return len;
}

pub fn encodeDefinedSettings(enc :std.io.AnyWriter,definedSettings :DefinedSettings) !void {
    if(definedSettings.headerTableSize != hpack.DEFAULT_TABLE_SIZE or !definedSettings.omit_default) {
        try enc.writeAll(&encode(SETTINGS_HEADER_TABLE_SIZE,definedSettings.headerTableSize));
    }
    if(!definedSettings.enablePush or !definedSettings.omit_default) {
        try enc.writeAll(&encode(SETTINGS_ENABLE_PUSH,if(definedSettings.enablePush) 1 else 0));
    }
    if(definedSettings.maxConcurrentStreams ) |maxConcurrentStreams| {
        try enc.writeAll(&encode(SETTINGS_MAX_CONCURRENT_STREAMS,maxConcurrentStreams));
    }
    if(definedSettings.initialWindowSize != initialWindowSize or !definedSettings.omit_default) {
        try enc.writeAll(&encode(SETTINGS_INITIAL_WINDOW_SIZE,definedSettings.initialWindowSize));
    }
    if(definedSettings.maxFrameSize != initialMaxFrameSize or !definedSettings.omit_default) {
        try enc.writeAll(&encode(SETTINGS_MAX_FRAME_SIZE,definedSettings.maxFrameSize));
    }
}
